# Mojolt

![Mojolt logo](mojolt_logo.png)

Mojolt is a WebSocket library based on [mojo-websockets](https://github.com/msaelices/mojo-websockets), adapted for **Mojo 1.2.0 on Linux**.

It provides a synchronous client, a server built around nonblocking sockets and `epoll`, and a separate protocol implementation that can be tested without a network connection. The server delivers complete messages to your handler and supports both a direct single-threaded reactor and independent worker reactors.

Both the project and the public Mojo package are named `mojolt`. The WebSocket source code lives in `src/websockets` and is imported as `mojolt.websockets`.

## Build and run

Requirements: Linux, Mojo 1.2.0, a C compiler with system headers and POSIX threads, Python 3.14 or later, and `uv`. No additional third-party dependencies are required for workers, synchronization, or notifications.

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

The native bridge combines `native/transport.c`, `native/threading.c`, and `native/control.c` into the existing `build/transport.o` link target. These files wrap Linux socket, epoll, eventfd, and opaque POSIX thread/mutex APIs. Worker management, task queues, and WebSocket processing remain in Mojo. Applications using the network transport must link the generated `build/transport.o` object file, as shown above.

## Worker architecture

The default `worker_count=1` runs the existing level-triggered epoll reactor on
its calling thread. It creates no worker threads or task mailbox unless
`server.handle()` is requested. Existing server constructors, handlers, imports,
and link commands continue working.

With multiple workers, the managing thread starts one independent reactor per
worker. Each owns its listener, epoll instance, connection table, protocol state,
buffers, deadlines, and bounded task queue. `SO_REUSEPORT` distributes new TCP
connections among listeners configured before bind. IPv4, IPv6, nonblocking I/O,
and the existing backlog behavior are retained. Distribution is not guaranteed
to be perfectly balanced. An accepted connection stays on its original worker
for its complete lifetime; normal socket processing uses no global connection
lock.

`server.bind()` is an initialization barrier in multi-worker mode: it returns
after all workers have bound their listeners and registered their wake-up
channels. Port zero selects one shared port. If startup fails, all started
workers are notified and joined before their contexts are released.
`serve_forever()` then supervises the group and reports worker failures. A worker
failure stops the other workers instead of silently reducing server capacity.

### Configuration

```mojo
var server = Server[echo](
    "127.0.0.1", 8765,
    worker_count=0,
    cpu_affinity=False,
    affinity_strict=True,
    task_queue_capacity=1024,
    shutdown_timeout_ms=5000,
    startup_timeout_ms=10000,
    backlog=128,
)
server.bind()
server.serve_forever()
```

- `worker_count=1`: direct execution on the calling thread. A positive larger
  value starts that many native workers; zero selects the number of CPUs in the
  managing thread's available affinity mask. After binding, `worker_count`
  contains the resolved count.
- `cpu_affinity=False`: workers inherit the managing thread's allowed CPUs.
  When enabled for native workers, workers are assigned available logical CPU
  IDs in round-robin order. IDs may be sparse; explicit counts may oversubscribe
  them. The CPU list is read before workers apply their own masks. Direct mode
  does not change the calling thread's affinity.
- `affinity_strict=True`: an affinity error fails startup and joins the group.
  With `False`, a warning is logged and the worker retains its inherited mask.
- `task_queue_capacity`: maximum pending commands per worker. Each payload is
  limited by `max_request_body_size`; one additional bounded consumer batch may
  be in progress. Queue capacity does not reserve payload memory in advance.
- `shutdown_timeout_ms`: absolute deadline for closing active connections after
  the reactor observes stopping. `close_timeout_ms` still bounds each individual
  close handshake.
- `startup_timeout_ms`: deadline for waiting at the initialization barrier.
  Cleanup still joins workers already inside a blocking system resolver or
  callback; the deadline cannot preempt that operation.
- `backlog=128`: listening backlog for every worker.

Existing connection, handshake, idle, message, and outgoing-buffer limits apply
**per worker**. Logical CPU availability reflects affinity, not cgroup CPU
bandwidth quotas. Automatic worker selection can therefore exceed a container's
CPU quota; use an explicit count when appropriate. Multi-worker startup reports
an error if reuseport is unavailable; direct mode remains available.

### Connection ownership and cross-thread commands

Callbacks for one connection always execute sequentially on its owning worker.
Callbacks on different workers may execute simultaneously. Protect application
state shared by callbacks. A blocking callback blocks its worker and delays that
worker's shutdown until the callback returns. Internal queue locks are released
before protocol operations or callbacks run.

`WSConnection` and borrowed `Span` values belong to their callback/reactor and
must not be retained or passed to another thread. Instead, copy
`connection.identifier()` and `connection.server_handle()`. The identifier
contains a worker index, an increasing local connection ID, and a server-run
epoch; it is independent of reusable file descriptors. The handle uses atomic
reference counting to retain synchronized mailbox storage.

```mojo
var id = connection.identifier()
var handle = connection.server_handle()
var accepted = handle.send_text(id, "queued reply")
if not accepted:
    connection.close(1013, "Worker queue is unavailable")
```

The same handle may be copied to other application threads. `send_text`,
`send_binary`, and `close` return `False` when the queue is full, stopping, closed,
or given a token from another run. Binary payload ownership is transferred;
no borrowed data crosses threads. A successful return means **enqueued**, not
confirmed delivery. Commands for already-closed connections are discarded.
Commands preserve order within a worker's queue; concurrent producers are
ordered by mutex acquisition, with no earlier ordering implied between threads.
Commands enqueued by a callback execute after it returns.

Direct-mode applications call `server.handle()` before serving to enable the
same queue API. Multi-worker callbacks always have a handle. Handles may outlive
the server: stopped mailboxes remain valid objects and reject new commands.

### Graceful shutdown and runtime safety

Call `handle.shutdown()` from any thread or `connection.request_shutdown()` from
a callback. Requests are idempotent and do not join the calling worker. Stop
flags have reserved storage independent of ordinary queue capacity, and eventfd
wakes blocked workers without sleep-based polling. Each reactor stops accepting,
discards pending commands, sends WebSocket close code 1001, and closes remaining
connections at its deadline. The managing thread joins every created worker
before releasing stable contexts, sockets, epoll descriptors, and mailboxes.
The owning thread may also call `server.shutdown()` to stop and join a group.
In direct mode this method retains its immediate resource-cleanup behavior;
callback/handle requests initiate the graceful sequence.

The native threading and control APIs return zero on success or positive POSIX
status codes; count queries return nonnegative values or negative POSIX errors.
Join/detach clear an opaque handle only after success, so failures retain
ownership. Platform-specific pthread and CPU-mask layouts stay in native code.

Native entry points contain all exceptions and use the supported, process-wide
[`initialize_runtime()`](https://mojolang.org/docs/std/runtime/initialize_runtime/)
API. The Mojo Thread API requires an explicit, non-null, stable context pointer.
Thread destruction joins owned handles; server workers are never silently
detached. Context addresses remain stable until join. Interoperability tests
exercise concurrent native threads, Mojo allocations/destruction, context
passing, repeated joins, and initialization failures on Mojo 1.2.0. Python
interpreter access from worker callbacks is outside this verified contract.

## Examples and validation

- [Echo server](src/main.mojo) and [client](examples/client.mojo).
- [Multithreaded echo server](examples/multithreaded_server.mojo): automatic
  worker count, optional affinity, and shutdown from a callback. Build with
  `uv run python scripts/build.py example-multithreaded`, then run
  `./build/example-multithreaded`. Sending the text `shutdown` stops the server.
- `uv run python scripts/test.py` builds all examples and runs native, Mojo,
  single-reactor, multi-reactor, and independent wire-protocol regressions.
- `uv run python scripts/benchmark_workers.py --workers 1,2 --clients 16
  --messages 200 --size 128` compares loopback echo workloads using only the
  Python standard library. It prints hardware/configuration, throughput, RTT
  percentiles, connection rate, server CPU usage, and memory. Python client
  overhead can limit the measured rate; these results do not establish linear
  scaling or production throughput.

## Current limitations

The native transport supports IPv4 and IPv6 on Linux. TLS is not implemented in the library: the client rejects `wss://` URLs, and the server can be deployed behind a proxy that terminates TLS. Compression and subprotocol negotiation are not implemented.

The message handler runs on its owning reactor thread. Long computations, database calls, or other blocking operations delay that worker's other connections. The shutdown deadline bounds network draining after callbacks return; it cannot preempt a blocked callback. Queue commands discarded during stopping are not acknowledged individually. Linux is the supported platform; other operating systems and Python interpreter interop on workers are not validated.

## License

Distributed under the [MIT License](LICENSE).
