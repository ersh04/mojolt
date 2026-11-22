from std.collections import Span
from std.sys import argv
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection


def echo(mut conn: WSConnection, data: Span[Byte, _]) raises:
    if conn.is_text():
        var text = String(from_utf8=data)
        if text == "__fail__":
            raise Error("Intentional handler failure")
        if text == "__close__":
            conn.close(1000, "done")
        else:
            conn.send_text(text)
    else:
        conn.send_binary(Bytes(data))


def main() raises:
    var args = argv()
    var host = String(args[1]) if len(args) > 1 else "127.0.0.1"
    var server = Server[echo](host, 0, max_request_body_size=1048576, max_connections=64, max_pending_bytes=2097152, handshake_timeout_ms=500, idle_timeout_ms=3000, close_timeout_ms=300)
    server.bind()
    print("READY ", server.port, flush=True)
    server.serve_forever()
