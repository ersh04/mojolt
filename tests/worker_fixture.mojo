"""Expose worker routing and shutdown through an independent wire test peer."""
from std.collections import Span
from std.sys import argv
from std.ffi import external_call
from std.memory import OwnedPointer
from mojolt.websockets.treading.thread import Thread, ThreadContext
from mojolt.websockets.treading.task_queue import ServerHandle, ConnectionId
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection


@fieldwise_init
struct SendContext(Movable):
    var handle: ServerHandle
    var id: ConnectionId
    var succeeded: Bool


def external_sender(raw: ThreadContext) abi("C") -> ThreadContext:
    var context = raw.value().unsafe_bitcast[SendContext]()
    try:
        var payload: Bytes = [0, 255, 0, 42]
        var text = context[].handle.send_text(context[].id, "external")
        var binary = context[].handle.send_binary(context[].id, payload^)
        var close = context[].handle.close(context[].id, 1000, "external close")
        context[].succeeded = text and binary and close
    except:
        context[].succeeded = False
    return None


def echo(mut connection: WSConnection, data: Span[Byte, _]) raises:
    if connection.is_text():
        var text = String(from_utf8=data)
        if text == "__worker__":
            connection.send_text(String(connection.identifier().worker))
        elif text == "__cpu__":
            connection.send_text(
                String(
                    connection.identifier().worker,
                    ":",
                    external_call["sched_getcpu", Int32](),
                )
            )
        elif text == "__external__":
            var context = OwnedPointer(
                SendContext(
                    connection.server_handle(), connection.identifier(), False
                )
            )
            var raw = (
                context.ptr()
                .unsafe_bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
            var thread = Thread(external_sender, raw)
            _ = thread.join()
            if not context.ptr()[].succeeded:
                raise Error("External producer could not queue commands")
        elif text == "__stop_queued__":
            var handle = connection.server_handle()
            for _ in range(100):
                if not handle.send_text(connection.identifier(), "pending"):
                    raise Error("Could not fill pending task batch")
            connection.request_shutdown()
            connection.request_shutdown()
        elif text == "__stop__":
            connection.request_shutdown()
            connection.request_shutdown()
        elif text == "__queued__":
            var handle = connection.server_handle()
            if not handle.send_text(connection.identifier(), "queued"):
                raise Error("Queue rejected command")
        elif text == "__queued_close__":
            var handle = connection.server_handle()
            if not handle.close(connection.identifier(), 1000, "queued close"):
                raise Error("Queue rejected close")
        elif text == "__close__":
            connection.close(1000, "done")
        elif text == "__fail__":
            raise Error("Intentional callback failure")
        else:
            connection.send_text(text)
    else:
        connection.send_binary(Bytes(data))


def main() raises:
    var args = argv()
    var host = String(args[1]) if len(args) > 1 else "127.0.0.1"
    var count = 2
    if len(args) > 2:
        count = Int(String(args[2]))
    var server = Server[echo](
        host,
        0,
        worker_count=count,
        cpu_affinity=len(args) > 3,
        close_timeout_ms=300,
        shutdown_timeout_ms=500,
        handshake_timeout_ms=500,
        idle_timeout_ms=3000,
        max_request_body_size=1048576,
        max_pending_bytes=2097152,
        max_connections=64,
    )
    server.bind()
    print("READY ", server.port, flush=True)
    server.serve_forever()
    print("STOPPED", flush=True)
