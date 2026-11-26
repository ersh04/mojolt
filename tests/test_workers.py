"""Exercise independent reactors with the existing RFC 6455 wire peer."""
from contextlib import contextmanager
import concurrent.futures
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import unittest
import test_integration as wire

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def worker_server(host="127.0.0.1", count=2, pin=False, affinity=None):
    command = [os.environ.get("MOJOLT_WORKER_FIXTURE", str(ROOT / "build/worker-fixture")), host, str(count)]
    if pin:
        command.append("pin")
    def restrict():
        if affinity is not None:
            os.sched_setaffinity(0, affinity)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, preexec_fn=restrict if affinity else None)
    try:
        if not select.select([process.stdout], [], [], 15)[0]:
            raise AssertionError("workers did not become ready")
        line = process.stdout.readline().strip()
        if not line.startswith("READY "):
            process.wait(timeout=5)
            raise AssertionError(line + process.stderr.read())
        yield process, int(line.split()[1])
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()


def connect(port, host="127.0.0.1"):
    peer = wire.Peer(socket.create_connection((host, port), timeout=3))
    peer.sock.sendall(wire.request())
    if b"101 Switching Protocols" not in peer.headers():
        raise AssertionError("worker rejected handshake")
    return peer


class WorkerServerIntegration(wire.ServerIntegration):
    @classmethod
    def setUpClass(cls):
        cls.context = worker_server()
        cls.process, cls.port = cls.context.__enter__()

    def test_queued_send_and_close(self):
        peer = self.ws()
        peer.sock.sendall(wire.frame(b"__queued__", 1))
        self.assertEqual(peer.recv_frame(), (1, b"queued"))
        peer.sock.sendall(wire.frame(b"__queued_close__", 1))
        self.assert_close(peer, 1000)

    def test_commands_from_another_native_thread(self):
        peer = self.ws()
        peer.sock.sendall(wire.frame(b"__external__", 1))
        self.assertEqual(peer.recv_frame(), (1, b"external"))
        self.assertEqual(peer.recv_frame(), (2, b"\x00\xff\x00*"))
        self.assert_close(peer, 1000)

    def test_connections_reach_multiple_workers(self):
        workers = set()
        for _ in range(64):
            peer = self.ws()
            peer.sock.sendall(wire.frame(b"__worker__", 1))
            opcode, payload = peer.recv_frame()
            self.assertEqual(opcode, 1)
            workers.add(int(payload))
            peer.sock.close()
            if len(workers) == 2:
                break
        self.assertEqual(workers, {0, 1})

    def test_concurrent_clients(self):
        def exchange(index):
            peer = connect(self.port)
            try:
                payload = struct.pack("!I", index) + b"\x00\xff" * 2048
                peer.sock.sendall(wire.frame(payload))
                return peer.recv_frame() == (2, payload)
            finally:
                peer.sock.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            self.assertTrue(all(pool.map(exchange, range(64))))


class WorkerLifecycleIntegration(unittest.TestCase):
    def stop(self, process, peer):
        peer.sock.sendall(wire.frame(b"__stop__", 1))
        opcode, payload = peer.recv_frame()
        self.assertEqual(opcode, 8)
        self.assertEqual(struct.unpack("!H", payload[:2])[0], 1001)
        peer.sock.sendall(wire.frame(payload, 8))
        process.wait(timeout=5)
        self.assertEqual(process.returncode, 0, process.stderr.read())

    def test_shutdown_from_callback_wakes_idle_workers(self):
        with worker_server(count=4) as (process, port):
            peer = connect(port)
            try:
                self.stop(process, peer)
            finally:
                peer.sock.close()

    def test_shutdown_deadline_with_active_connections(self):
        with worker_server() as (process, port):
            peers = [connect(port) for _ in range(12)]
            try:
                peers[0].sock.sendall(wire.frame(b"__stop__", 1))
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read())
            finally:
                for peer in peers:
                    peer.sock.close()

    def test_shutdown_discards_pending_commands(self):
        with worker_server() as (process, port):
            peer = connect(port)
            try:
                peer.sock.sendall(wire.frame(b"__stop_queued__", 1))
                opcode, payload = peer.recv_frame()
                self.assertEqual(opcode, 8)
                self.assertEqual(struct.unpack("!H", payload[:2])[0], 1001)
                peer.sock.sendall(wire.frame(payload, 8))
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read())
            finally:
                peer.sock.close()

    def test_direct_mode_callback_shutdown(self):
        with worker_server(count=1) as (process, port):
            peer = connect(port)
            try:
                self.stop(process, peer)
            finally:
                peer.sock.close()

    def test_automatic_workers_use_sparse_available_cpu_ids(self):
        allowed = sorted(os.sched_getaffinity(0))
        if len(allowed) < 2:
            self.skipTest("Two allowed logical CPUs are required")
        chosen = {allowed[1], allowed[-1]} if len(allowed) > 2 else set(allowed)
        with worker_server(count=0, pin=True, affinity=chosen) as (process, port):
            observed = {}
            peer = None
            try:
                for _ in range(64):
                    if peer is not None:
                        peer.sock.close()
                    peer = connect(port)
                    peer.sock.sendall(wire.frame(b"__cpu__", 1))
                    opcode, payload = peer.recv_frame()
                    self.assertEqual(opcode, 1)
                    worker, cpu = map(int, payload.split(b":"))
                    observed[worker] = cpu
                    if len(observed) == len(chosen):
                        break
                self.assertEqual(observed, dict(enumerate(sorted(chosen))))
                self.stop(process, peer)
            finally:
                if peer is not None:
                    peer.sock.close()

    @unittest.skipUnless(socket.has_ipv6, "IPv6 unavailable")
    def test_ipv6_workers(self):
        with worker_server(host="::1") as (process, port):
            peer = connect(port, "::1")
            try:
                peer.sock.sendall(wire.frame(b"ipv6"))
                self.assertEqual(peer.recv_frame(), (2, b"ipv6"))
                self.stop(process, peer)
            finally:
                peer.sock.close()
