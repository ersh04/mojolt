# Mojolt

![Mojolt logo](mojolt_logo.png)

A WebSocket library for **Mojo 1.2.0 on Linux**. Mojolt provides a synchronous client, a server built around nonblocking sockets and `epoll`, and a separate protocol implementation that can be tested without a network connection. The server handles multiple connections on one thread and delivers complete messages to your handler.

Both the project and the public Mojo package are named `mojolt`. The WebSocket source code lives in `src/websockets` and is imported as `mojolt.websockets`.

## Build and run

Requirements: Linux, a C compiler with system headers, Python 3.14 or later, and `uv`.

```sh
uv sync --locked
uv run python scripts/test.py
./build/echo
```

The test command builds the C bridge, the Mojo package, the client and server test fixtures, and the examples, then runs the unit and integration tests. The echo server listens on `127.0.0.1:8765` by default.

Run the example client in another terminal:

```sh
./build/example-client
```

You can also specify the server's bind address and port:

```sh
./build/echo ::1 8765
```

If you already have Mojo 1.2.0 installed, you can supply its executable directly:

```sh
MOJO=/path/to/mojo python3 scripts/test.py
```

The build script checks the compiler version. It generates `build/mojolt.mojoc` and `build/transport.o`; rebuild these files when changing SDK versions.

## Message handler example

```mojo
from std.collections import Span
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection


def echo(mut connection: WSConnection, message: Span[Byte, _]) raises:
    # Keep the original WebSocket message type in the reply.
    if connection.is_text():
        connection.send_text(String(from_utf8=message))
    else:
        connection.send_binary(Bytes(message))


def main() raises:
    var server = Server[echo]("127.0.0.1", 8765)
    server.serve_forever()
```

The handler receives a complete text or binary message, including messages assembled from multiple WebSocket fragments. Use `connection.is_text()` to distinguish the message type and the connection's send methods to reply to that client.

To build your own application, save it as `your_app.mojo` and run:

```sh
uv run python scripts/build.py
uv run mojo build -I build your_app.mojo -Xlinker build/transport.o -o build/your_app
```

The C bridge in `native/transport.c` wraps Linux socket and event APIs. Applications using the network transport must link the generated `build/transport.o` object file, as shown above.

## Documentation

The detailed guides are currently available in Russian:

- [Echo server](src/main.mojo) and [client](examples/client.mojo): buildable examples.

## Current limitations

The native transport supports IPv4 and IPv6 on Linux. TLS is not implemented in the library: the client rejects `wss://` URLs, and the server can be deployed behind a proxy that terminates TLS. Compression and subprotocol negotiation are not implemented.

The message handler runs on the server's event-loop thread. Long computations, database calls, or other blocking operations inside the handler delay other connections. The guide describes the limits for message sizes, output queues, connection counts, and timeouts.

## License

Code derived from `mojo-websockets` retains its original attribution. See [LICENSE](LICENSE).
