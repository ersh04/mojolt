"""Run an echo server with one independent reactor per available logical CPU."""
from std.collections import Span
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection


def echo(mut connection: WSConnection, data: Span[Byte, _]) raises:
    """Echo complete messages on the connection's owning worker thread."""
    if connection.is_text():
        var text = String(from_utf8=data)
        if text == "shutdown":
            connection.request_shutdown()
        else:
            connection.send_text(text)
    else:
        connection.send_binary(Bytes(data))


def main() raises:
    var server = Server[echo](
        "127.0.0.1",
        8765,
        worker_count=0,
        cpu_affinity=False,
        task_queue_capacity=1024,
        shutdown_timeout_ms=5000,
    )
    server.bind()
    print(
        "Listening on",
        server.address(),
        "with",
        server.worker_count,
        "workers",
        flush=True,
    )
    server.serve_forever()
