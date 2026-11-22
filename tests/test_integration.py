"""Exercise the compiled library through independent RFC 6455 wire encoding.

Only the Python standard library is used. The peer below does not reuse the
Mojo serializer, so identical serializer/parser bugs cannot make a test pass.
"""
import base64
from contextlib import contextmanager
from email.utils import parsedate_to_datetime
import hashlib
from pathlib import Path
import select
import socket
import struct
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
KEY = "dGhlIHNhbXBsZSBub25jZQ=="


def frame(payload=b"", opcode=2, fin=True, masked=True, reserved=0):
    first = (128 if fin else 0) | opcode | reserved
    size = len(payload)
    mask_bit = 128 if masked else 0
    if size < 126:
        header = bytes([first, mask_bit | size])
    elif size < 65536:
        header = bytes([first, mask_bit | 126]) + struct.pack("!H", size)
    else:
        header = bytes([first, mask_bit | 127]) + struct.pack("!Q", size)
    if not masked:
        return header + payload
    key = b"\x37\xfa\x21\x3d"
    return header + key + bytes(value ^ key[i % 4] for i, value in enumerate(payload))


def request(extra=b"", method=b"GET", version=b"HTTP/1.1", host=True, connection=b"Upgrade", upgrade=b"websocket"):
    return (method + b" /echo?q=1 " + version + b"\r\n"
            + (b"Host: localhost\r\n" if host else b"")
            + b"Upgrade: " + upgrade + b"\r\nConnection: " + connection
            + b"\r\nSec-WebSocket-Key: " + KEY.encode()
            + b"\r\nSec-WebSocket-Version: 13\r\n" + extra + b"\r\n")


class Peer:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = bytearray()
        self.sock.settimeout(3)

    def exact(self, count):
        while len(self.buffer) < count:
            data = self.sock.recv(max(4096, count - len(self.buffer)))
            if not data:
                raise EOFError("unexpected TCP EOF")
            self.buffer.extend(data)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def headers(self):
        while b"\r\n\r\n" not in self.buffer:
            data = self.sock.recv(4096)
            if not data:
                raise EOFError("EOF before HTTP headers")
            self.buffer.extend(data)
        end = self.buffer.index(b"\r\n\r\n") + 4
        return self.exact(end)

    def recv_frame(self, expect_masked=False):
        first, second = self.exact(2)
        size = second & 127
        if size == 126:
            size = struct.unpack("!H", self.exact(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.exact(8))[0]
        if bool(second & 128) != expect_masked:
            raise AssertionError("incorrect mask bit")
        key = self.exact(4) if second & 128 else None
        payload = self.exact(size)
        if key:
            payload = bytes(v ^ key[i % 4] for i, v in enumerate(payload))
        return first & 15, payload


@contextmanager
def running_server(host="127.0.0.1"):
    process = subprocess.Popen([str(ROOT / "build/server-fixture"), host], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        if not select.select([process.stdout], [], [], 10)[0]:
            raise AssertionError("server did not become ready")
        line = process.stdout.readline().strip()
        if not line.startswith("READY "):
            raise AssertionError(line + process.stderr.read())
        yield process, int(line.split()[1])
    finally:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()


class ServerIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context = running_server()
        cls.process, cls.port = cls.context.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.context.__exit__(None, None, None)

    def tcp(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        self.addCleanup(sock.close)
        return sock

    def ws(self, req=None, tail=b""):
        peer = Peer(self.tcp())
        peer.sock.sendall((req or request()) + tail)
        head = peer.headers()
        self.assertTrue(head.startswith(b"HTTP/1.1 101"), head)
        self.assertIn(b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", head)
        return peer

    def assert_close(self, peer, code):
        opcode, payload = peer.recv_frame()
        self.assertEqual(opcode, 8)
        self.assertEqual(struct.unpack("!H", payload[:2])[0], code)

    def test_echo_binary_lengths(self):
        peer = self.ws()
        for size in (0, 1, 125, 126, 65535, 65536, 200000):
            with self.subTest(size=size):
                data = (b"a\x00\xff" * (size // 3 + 1))[:size]
                peer.sock.sendall(frame(data))
                self.assertEqual(peer.recv_frame(), (2, data))

    def test_unicode_text(self):
        peer = self.ws()
        text = "Привет 🌍".encode()
        peer.sock.sendall(frame(text, 1))
        self.assertEqual(peer.recv_frame(), (1, text))

    def test_idle_tcp_does_not_block_other_clients(self):
        self.tcp()
        peer = self.ws()
        peer.sock.sendall(frame(b"still responsive"))
        self.assertEqual(peer.recv_frame(), (2, b"still responsive"))

    def test_many_active_clients(self):
        peers = [self.ws() for _ in range(12)]
        for i, peer in enumerate(peers):
            peer.sock.sendall(frame(str(i).encode()))
        for i, peer in enumerate(peers):
            self.assertEqual(peer.recv_frame(), (2, str(i).encode()))

    def test_request_and_frames_in_one_tcp_write(self):
        peer = self.ws(tail=frame(b"one") + frame(b"two"))
        self.assertEqual(peer.recv_frame(), (2, b"one"))
        self.assertEqual(peer.recv_frame(), (2, b"two"))

    def test_split_request_and_frame(self):
        peer = Peer(self.tcp())
        for byte in request():
            peer.sock.sendall(bytes([byte]))
        self.assertIn(b"101 Switching Protocols", peer.headers())
        for byte in frame(b"split"):
            peer.sock.sendall(bytes([byte]))
        self.assertEqual(peer.recv_frame(), (2, b"split"))

    def test_fragmented_utf8_with_interleaved_ping(self):
        peer = self.ws()
        data = "🌍".encode()
        peer.sock.sendall(frame(data[:1], 1, False) + frame(b"probe", 9))
        self.assertEqual(peer.recv_frame(), (10, b"probe"))
        peer.sock.sendall(frame(data[1:], 0))
        self.assertEqual(peer.recv_frame(), (1, data))

    def test_empty_first_fragment(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"", 1, False) + frame(b"ok", 0))
        self.assertEqual(peer.recv_frame(), (1, b"ok"))

    def test_invalid_utf8(self):
        for payload in (b"\xff", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xf0\x9f"):
            with self.subTest(payload=payload):
                peer = self.ws()
                peer.sock.sendall(frame(payload, 1))
                self.assert_close(peer, 1007)

    def test_invalid_close_utf8(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"\x03\xe8\xff", 8))
        self.assert_close(peer, 1007)

    def test_invalid_protocol_frames(self):
        cases = [frame(b"", 3), frame(b"x", reserved=64), frame(b"x", masked=False),
                 frame(b"x", 9, False), frame(b"x", 0),
                 b"\x82\xfe\x00\x01", b"\x89\xfe\x00\x7e",
                 b"\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00"]
        for wire in cases:
            with self.subTest(wire=wire):
                peer = self.ws()
                peer.sock.sendall(wire)
                self.assert_close(peer, 1002)

    def test_frame_limit_checked_before_payload(self):
        peer = self.ws()
        peer.sock.sendall(b"\x82\xff" + struct.pack("!Q", 1048577))
        self.assert_close(peer, 1009)

    def test_fragmented_message_limit(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"a" * 1048576, 2, False) + frame(b"x", 0))
        self.assert_close(peer, 1009)

    def test_connection_tokens_and_case(self):
        self.ws(request(connection=b"keep-alive, UpGrAdE", upgrade=b"WebSocket"))
        self.ws(request(extra=b"Connection: keep-alive\r\n"))

    def test_invalid_http_requests(self):
        cases = [request(method=b"POST"), request(version=b"HTTP/1.0"), request(host=False),
                 request(extra=b"Host: other\r\n"), request(extra=b"Sec-WebSocket-Key: x\r\n"),
                 request(extra=b"Content-Length: -1\r\n"), request(extra=b"Transfer-Encoding: chunked\r\n"),
                 request().replace(b"Version: 13", b"Version: 12"),
                 request().replace(KEY.encode(), b"A" * 22 + b"======"),
                 request(extra=b"Bad Name: value\r\n"), request(extra=b"NoColon\r\n"),
                 request(extra=b"X: a\x00b\r\n")]
        for req in cases:
            with self.subTest(req=req):
                peer = Peer(self.tcp())
                peer.sock.sendall(req)
                self.assertTrue(peer.headers().startswith(b"HTTP/1.1 400"))

    def test_complete_header_limit(self):
        peer = Peer(self.tcp())
        peer.sock.sendall(request(extra=b"X-Large: " + b"a" * 65536 + b"\r\n"))
        self.assertTrue(peer.headers().startswith(b"HTTP/1.1 400"))

    def test_handler_failure_isolated(self):
        bad = self.ws()
        bad.sock.sendall(frame(b"__fail__", 1))
        self.assert_close(bad, 1011)
        peer = self.ws()
        peer.sock.sendall(frame(b"healthy"))
        self.assertEqual(peer.recv_frame(), (2, b"healthy"))
        self.assertIsNone(self.process.poll())

    def test_normal_and_empty_close(self):
        for payload in (b"", b"\x03\xe8bye"):
            peer = self.ws()
            peer.sock.sendall(frame(payload, 8))
            self.assertEqual(peer.recv_frame(), (8, payload))
            self.assertEqual(peer.sock.recv(1), b"")

    def test_close_during_fragmented_message(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"half", 1, False) + frame(b"\x03\xe8", 8))
        self.assertEqual(peer.recv_frame(), (8, b"\x03\xe8"))

    def test_server_initiated_close(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"__close__", 1))
        opcode, payload = peer.recv_frame()
        self.assertEqual(opcode, 8)
        self.assertEqual(payload[:2], b"\x03\xe8")
        peer.sock.sendall(frame(payload, 8))
        self.assertEqual(peer.sock.recv(1), b"")

    def test_unanswered_close_has_deadline(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"__close__", 1))
        self.assertEqual(peer.recv_frame()[0], 8)
        self.assertEqual(peer.sock.recv(1), b"")

    def test_handshake_timeout(self):
        sock = self.tcp()
        sock.sendall(b"GET /")
        sock.settimeout(2)
        self.assertEqual(sock.recv(1), b"")

    def test_half_close_preserves_queued_response(self):
        peer = self.ws()
        peer.sock.sendall(frame(b"last"))
        peer.sock.shutdown(socket.SHUT_WR)
        self.assertEqual(peer.recv_frame(), (2, b"last"))
        self.assertEqual(peer.sock.recv(1), b"")

    def test_slow_reader_does_not_block_other_clients(self):
        slow = self.ws()
        slow.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        wire = frame(b"a" * 1048576)
        try:
            for _ in range(8):
                slow.sock.sendall(wire)
        except (BrokenPipeError, ConnectionResetError):
            pass
        peer = self.ws()
        peer.sock.sendall(frame(b"responsive"))
        self.assertEqual(peer.recv_frame(), (2, b"responsive"))

    def test_mojo_client(self):
        result = subprocess.run([str(ROOT / "build/client-fixture"), f"ws://127.0.0.1:{self.port}?token=test"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("client ok", result.stdout)

    def test_repeated_connections_release_descriptors(self):
        time.sleep(.2)
        initial = len(list(Path(f"/proc/{self.process.pid}/fd").iterdir()))
        for _ in range(80):
            peer = self.ws()
            peer.sock.sendall(frame(b"", 8))
            self.assertEqual(peer.recv_frame(), (8, b""))
            peer.sock.close()
        time.sleep(.2)
        final = len(list(Path(f"/proc/{self.process.pid}/fd").iterdir()))
        self.assertLessEqual(final, initial + 2)

    def test_http_date_format(self):
        peer = Peer(self.tcp())
        peer.sock.sendall(request())
        lines = peer.headers().decode().split("\r\n")
        date = next(line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("date:"))
        self.assertIsNotNone(parsedate_to_datetime(date).tzinfo)


class DescriptorPressureIntegration(unittest.TestCase):
    def test_descriptor_exhaustion_preserves_existing_clients(self):
        import resource
        with running_server() as (process, port):
            with socket.create_connection(("127.0.0.1", port), timeout=3) as healthy:
                peer = Peer(healthy)
                healthy.sendall(request())
                self.assertIn(b"101 Switching Protocols", peer.headers())
                resource.prlimit(process.pid, resource.RLIMIT_NOFILE, (24, 24))
                idle = []
                try:
                    for _ in range(30):
                        idle.append(socket.create_connection(("127.0.0.1", port), timeout=2))
                    time.sleep(.15)
                    healthy.sendall(frame(b"still alive"))
                    self.assertEqual(peer.recv_frame(), (2, b"still alive"))
                    self.assertIsNone(process.poll())
                finally:
                    for sock in idle:
                        sock.close()


class IPv6Integration(unittest.TestCase):
    def test_ipv6_server_and_client(self):
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        try:
            probe.bind(("::1", 0))
        except OSError as error:
            self.skipTest(f"IPv6 loopback unavailable: {error}")
        finally:
            probe.close()
        with running_server("::1") as (_, port):
            result = subprocess.run([str(ROOT / "build/client-fixture"), f"ws://[::1]:{port}/"], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class IndependentClientIntegration(unittest.TestCase):
    def test_mojo_client_against_independent_peer(self):
        errors = []
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(5)
        def server():
            try:
                conn, _ = listener.accept()
                with conn:
                    peer = Peer(conn)
                    head = peer.headers().decode()
                    key = next(line.split(":", 1)[1].strip() for line in head.split("\r\n") if line.lower().startswith("sec-websocket-key:"))
                    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
                    response = b"HTTP/1.1 101 Switching Protocols\r\nConnection: keep-alive, Upgrade\r\nUpgrade: WebSocket\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n"
                    for part in (response[:-3], response[-3:-1], response[-1:]):
                        conn.sendall(part)
                    for opcode in (1, 2, 8):
                        actual, payload = peer.recv_frame(expect_masked=True)
                        if actual != opcode:
                            raise AssertionError((actual, opcode))
                        conn.sendall(frame(payload, opcode, masked=False))
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        port = listener.getsockname()[1]
        result = subprocess.run([str(ROOT / "build/client-fixture"), f"ws://127.0.0.1:{port}/"], capture_output=True, text=True, timeout=5)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
