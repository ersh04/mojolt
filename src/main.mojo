from std.collections import Span
from std.sys import argv
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection
from std.logger import Logger, Level


def on_message(mut connection: WSConnection, message: Span[Byte, _]) raises:
    var logger = Logger[Level.DEBUG]()
    # WebSocket preserves the message type; a text echo must also be text.
    if connection.is_text():
        var text = String(from_utf8=message)
        logger.debug("Echoing: ", text)
        connection.send_text(text)
    else:
        logger.debug("Echoing binary bytes: ", len(message))
        connection.send_binary(Bytes(message))


def main() raises:
    var args = argv()
    var host = String(args[1]) if len(args) > 1 else "127.0.0.1"
    var port = Int(args[2]) if len(args) > 2 else 8765
    var server = Server[on_message](host, port)
    server.bind()
    print("Listening on ws://", server.address(), sep="", flush=True)
    server.serve_forever()
