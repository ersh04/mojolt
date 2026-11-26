"""Worker-local level-triggered reactors with an optional thread-per-core manager.

Callbacks receive complete messages on their owning reactor. Different workers
may invoke callbacks simultaneously; a blocking callback stalls its worker.
The default one-worker mode executes directly on the calling thread.
"""
from std.collections import Dict, Optional, Span
from std.memory import ArcPointer, Pointer
from std.ffi import external_call
from mojolt.websockets.aliases import Bytes, DEFAULT_BUFFER_SIZE, DEFAULT_MAX_REQUEST_BODY_SIZE
from mojolt.websockets.frames import Frame, OpCode
from mojolt.websockets.http import HTTPRequest
from mojolt.websockets.logger import logger
from mojolt.websockets.protocol import CONNECTING, OPEN, CLOSING, CLOSED
from mojolt.websockets.protocol.base import receive_data, receive_eof, send_text, send_binary, send_ping, send_close, fail
from mojolt.websockets.protocol.server import ServerProtocol
from mojolt.websockets.transport import Transport, Poller, now_ms
from mojolt.websockets.utils.bytes import str_to_bytes
from mojolt.websockets.treading.worker_manager import WorkerManager, WorkerReactor
from mojolt.websockets.treading.task_queue import GroupControl, ServerHandle, WorkerControl, Task, ConnectionId, WAKE_ID, TASK_TEXT, TASK_BINARY, TASK_CLOSE
from mojolt.websockets.treading.thread import available_cpus, set_current_thread_affinity, set_current_thread_name


struct WSConnection(Movable):
    """Own one client's transport, protocol, message assembly and output queue.

    A queue entry survives a short send or EAGAIN. Its offset advances only by
    the number of bytes the kernel actually accepted. The protocol never writes
    to a socket directly, so automatic Pong/Close replies use the same queue.
    """
    var conn: Transport
    var protocol: ServerProtocol
    var message: Bytes
    var message_opcode: Int
    var outgoing: Bytes
    var outgoing_offset: Int
    var max_pending_bytes: Int
    var accepted_at: Int
    var last_activity: Int
    var closing_at: Int
    var close_timeout_ms: Int
    var close_after_write: Bool
    var _identifier: ConnectionId
    var _server: Optional[ServerHandle]
    var _shutdown_requested: Bool
    var _watching_write: Bool

    def __init__(out self, var conn: Transport, var protocol: ServerProtocol, max_pending_bytes: Int = 20971520, close_timeout_ms: Int = 5000):
        self.conn = conn^
        self.protocol = protocol^
        self.message = Bytes()
        self.message_opcode = OpCode.OP_BINARY
        self.outgoing = Bytes()
        self.outgoing_offset = 0
        self.max_pending_bytes = max_pending_bytes
        self.accepted_at = now_ms()
        self.last_activity = self.accepted_at
        self.closing_at = 0
        self.close_timeout_ms = close_timeout_ms
        self.close_after_write = False
        self._identifier = ConnectionId(0, 0, 0)
        self._server = None
        self._shutdown_requested = False
        self._watching_write = False

    def identifier(self) -> ConnectionId:
        """Return a run-scoped ID suitable for cross-thread commands."""
        return self._identifier

    def server_handle(self) raises -> ServerHandle:
        """Copy the thread-safe command handle, without borrowing this client.

        Single-threaded applications enable handles by calling Server.handle
        before serving. Multi-worker servers always expose a handle.
        """
        if not self._server:
            raise Error("Call Server.handle before serving to enable cross-thread operations")
        return self._server.value().copy()

    def request_shutdown(mut self) raises:
        """Request graceful server shutdown from a callback without joining."""
        self._shutdown_requested = True
        if self._server:
            self._server.value().shutdown()

    def pending(self) -> Int:
        return len(self.outgoing) - self.outgoing_offset

    def collect(mut self) raises:
        var data = self.protocol.data_to_send()
        if len(data) > self.max_pending_bytes - self.pending():
            raise Error("Outgoing queue limit exceeded")
        # Compact only when appending; partial writes retain their offset.
        if self.outgoing_offset > 0:
            var remaining = Bytes(self.outgoing[self.outgoing_offset:])
            self.outgoing = remaining^
            self.outgoing_offset = 0
        self.outgoing.extend(data[:])
        if self.protocol.get_state() == CLOSING and self.closing_at == 0:
            self.closing_at = now_ms()
        if self.protocol.get_eof_sent():
            self.close_after_write = True

    def send_text(mut self, message: String) raises:
        send_text(self.protocol, str_to_bytes(message))
        self.collect()

    def send_binary(mut self, message: Bytes) raises:
        send_binary(self.protocol, message)
        self.collect()

    def ping(mut self, data: Bytes = Bytes()) raises:
        send_ping(self.protocol, data)
        self.collect()

    def is_text(self) -> Bool:
        return self.message_opcode == OpCode.OP_TEXT

    def close(mut self, code: Int = 1000, reason: String = "") raises:
        """Start the closing handshake; the reactor enforces its deadline."""
        if self.protocol.get_state() == OPEN:
            send_close(self.protocol, code, reason)
            self.collect()
        elif self.protocol.get_state() == CONNECTING:
            self.abort()

    def abort(mut self):
        """Immediately release the transport after an unrecoverable failure."""
        self.conn.close()
        self.protocol.set_state(CLOSED)

    def flush(mut self) raises:
        # A per-turn budget prevents a fast writer from starving other clients.
        var budget = 262144
        while self.pending() > 0 and budget > 0:
            var end = min(len(self.outgoing), self.outgoing_offset + budget)
            var count = self.conn.try_write(self.outgoing[self.outgoing_offset:end])
            if count == -2:
                return
            if count <= 0:
                raise Error("send made no progress")
            self.outgoing_offset += count
            budget -= count
        if self.pending() == 0:
            self.outgoing.clear()
            self.outgoing_offset = 0
            if self.close_after_write:
                self.conn.close()
                self.protocol.set_state(CLOSED)


comptime ConnHandler = def(mut conn: WSConnection, data: Span[Byte, _]) raises thin -> None


struct Server[handler: ConnHandler](Movable, WorkerReactor):
    """Run one caller-owned reactor or manage independent native workers.

    Existing positional options retain their meanings. worker_count=1 keeps
    the original direct execution path; zero chooses the caller's affinity
    count. Limits on connections, buffers, and queues apply to each worker.
    Mutable connection state never leaves its reactor. Only ServerHandle may
    be used concurrently; Server lifecycle methods belong to its owner.
    """
    var host: String
    var port: Int
    var max_request_body_size: Int
    var max_connections: Int
    var max_pending_bytes: Int
    var handshake_timeout_ms: Int
    var idle_timeout_ms: Int
    var close_timeout_ms: Int
    var origins: Optional[List[String]]
    var ln: Transport
    var clients: Dict[UInt64, WSConnection]
    var client_ids: List[UInt64]
    var next_id: UInt64
    var accept_paused_until: Int
    var running: Bool
    var _workers: Optional[WorkerManager]
    var _control: Optional[ArcPointer[GroupControl]]
    var _worker_id: Int
    var _is_worker: Bool
    var _stopping_deadline: Int
    var worker_count: Int
    var cpu_affinity: Bool
    var affinity_strict: Bool
    var task_queue_capacity: Int
    var shutdown_timeout_ms: Int
    var startup_timeout_ms: Int
    var backlog: Int

    def __init__(out self, host: String, port: Int, max_request_body_size: Int = DEFAULT_MAX_REQUEST_BODY_SIZE, max_connections: Int = 1024, max_pending_bytes: Int = 20971520, handshake_timeout_ms: Int = 10000, idle_timeout_ms: Int = 60000, close_timeout_ms: Int = 5000, origins: Optional[List[String]] = None, *, worker_count: Int = 1, cpu_affinity: Bool = False, affinity_strict: Bool = True, task_queue_capacity: Int = 1024, shutdown_timeout_ms: Int = 5000, startup_timeout_ms: Int = 10000, backlog: Int = 128) raises:
        if worker_count < 0 or task_queue_capacity < 1 or shutdown_timeout_ms < 1 or startup_timeout_ms < 1 or backlog < 1:
            raise Error("Invalid worker configuration")
        if max_request_body_size < 1 or max_connections < 1 or max_pending_bytes < 256 or handshake_timeout_ms < 1 or idle_timeout_ms < 1 or close_timeout_ms < 1:
            raise Error("Invalid server limits")
        self.host = host
        self.port = port
        self.max_request_body_size = max_request_body_size
        self.max_connections = max_connections
        self.max_pending_bytes = max_pending_bytes
        self.handshake_timeout_ms = handshake_timeout_ms
        self.idle_timeout_ms = idle_timeout_ms
        self.close_timeout_ms = close_timeout_ms
        self.origins = origins.copy()
        self.ln = Transport()
        self.clients = Dict[UInt64, WSConnection]()
        self.client_ids = List[UInt64]()
        self.next_id = 1
        self.accept_paused_until = 0
        self.running = False
        self._workers = None
        self._control = None
        self._worker_id = 0
        self._is_worker = False
        self._stopping_deadline = 0
        self.worker_count = worker_count
        self.cpu_affinity = cpu_affinity
        self.affinity_strict = affinity_strict
        self.task_queue_capacity = task_queue_capacity
        self.shutdown_timeout_ms = shutdown_timeout_ms
        self.startup_timeout_ms = startup_timeout_ms
        self.backlog = backlog

    def __deinit__(deinit self):
        self.shutdown()

    def run_worker(mut self, group: ArcPointer[GroupControl], worker: Int, cpu: Int) raises:
        """Initialize and run local resources exclusively on a native worker."""
        self._control = group.copy()
        self._worker_id = worker
        self._is_worker = True
        set_current_thread_name(String("mojolt-", worker))
        if cpu >= 0:
            try:
                set_current_thread_affinity(List[Int](length=1, fill=cpu))
            except error:
                if self.affinity_strict:
                    raise error
                logger.warn("Worker affinity was not applied: ", error)
        self.ln.listen(self.host, self.port, reuse_port=True, backlog=self.backlog)
        self._serve_local()

    def __enter__(mut self) -> ServerSession[Self.handler, origin_of(self)]:
        return ServerSession[Self.handler, origin_of(self)](Pointer(to=self))

    def __exit__(mut self):
        self.shutdown()

    def handle(mut self) raises -> ServerHandle:
        """Enable and return a shareable command handle before serving.

        The default direct mode allocates no mailbox unless requested. Multi-
        worker bind creates its group before returning a handle. Handles from
        a terminated run reject subsequent submissions.
        """
        if self.worker_count != 1 and not self._workers:
            self.bind()
        if self.worker_count == 1 and self._control:
            if self._control.value().ptr()[].worker_handle(0).snapshot()[0] >= 2:
                self._control = None
        if not self._control:
            self._control = ArcPointer(GroupControl(1, self.task_queue_capacity, self.max_request_body_size))
        return ServerHandle(self._control.value())

    def bind(mut self) raises:
        """Bind a direct listener or start all independent reuseport workers.

        Multi-worker initialization is a barrier: successful return means all
        event loops are ready. Port zero is resolved once for the whole group.
        Failure stops and joins partial startup before releasing resources.
        """
        if self._workers:
            raise Error("Workers are already started")
        self._stopping_deadline = 0
        if self.worker_count == 1:
            if self._control:
                if self._control.value().ptr()[].worker_handle(0).snapshot()[0] >= 2:
                    self._control = ArcPointer(GroupControl(1, self.task_queue_capacity, self.max_request_body_size))
            self.ln.listen(self.host, self.port, backlog=self.backlog)
            self.port = self.ln.port()
            return
        var available = available_cpus()
        var count = len(available) if self.worker_count == 0 else self.worker_count
        self.worker_count = count
        if count == 1:
            self.bind()
            return
        self.ln.listen(self.host, self.port, reuse_port=True, backlog=self.backlog)
        self.port = self.ln.port()
        try:
            var reactors = List[Self](capacity=count)
            var cpus = List[Int](capacity=count)
            for i in range(count):
                reactors.append(Self(
                    self.host, self.port, self.max_request_body_size, self.max_connections,
                    self.max_pending_bytes, self.handshake_timeout_ms, self.idle_timeout_ms,
                    self.close_timeout_ms, self.origins,
                    affinity_strict=self.affinity_strict, task_queue_capacity=self.task_queue_capacity,
                    shutdown_timeout_ms=self.shutdown_timeout_ms, backlog=self.backlog,
                ))
                cpus.append(available[i % len(available)] if self.cpu_affinity else -1)
            var manager = WorkerManager(count, self.task_queue_capacity, self.max_request_body_size, self.startup_timeout_ms)
            manager.start(reactors^, cpus)
            self._control = manager.group.copy()
            self._workers = manager^
            self.running = True
        finally:
            # Only worker listeners participate in distribution after startup.
            self.ln.close()

    def serve_forever(mut self) raises:
        """Serve on this thread or supervise workers until graceful termination."""
        if not self._workers and self.ln.is_closed():
            self.bind()
        if self._workers:
            try:
                self._workers.value().wait()
            finally:
                self.shutdown()
            return
        self._serve_local()

    def _serve_local(mut self) raises:
        """Own one epoll instance and run only this reactor's connection state."""
        var poller = Poller()
        poller.watch(1, self.ln.fd, 0)
        if self._control:
            var control = self._control.value().ptr()[].worker_handle(self._worker_id)
            poller.watch(1, control.descriptor(), WAKE_ID)
            control.mark_ready()
            self._control.value().ptr()[].changed.signal()
        self.running = True
        try:
            self._loop(poller)
        finally:
            self.shutdown()

    def _begin_shutdown(mut self, poller: Poller) raises:
        """Stop accepting and start close handshakes under one absolute deadline."""
        if self._stopping_deadline > 0:
            return
        self._stopping_deadline = now_ms() + self.shutdown_timeout_ms
        self.accept_paused_until = 0
        self.ln.close()
        for id in self.client_ids:
            ref client = self.clients[id]
            try:
                client.close(1001, "Server shutdown")
                client.flush()
                Self._watch(client, poller, id)
            except error:
                logger.debug("Connection close failed: ", error)
                client.abort()

    @staticmethod
    def _watch(mut client: WSConnection, poller: Poller, id: UInt64) raises:
        """Update writable interest only when the output queue changes state."""
        if client.conn.is_closed():
            return
        var writing = client.pending() > 0
        if writing != client._watching_write:
            poller.watch(3, client.conn.fd, id, writing)
            client._watching_write = writing

    def _tasks(mut self, poller: Poller, mut batch: List[Task]) raises:
        """Apply a bounded batch after releasing the producer mutex."""
        var control = self._control.value().ptr()[].worker_handle(self._worker_id)
        if control.take_batch(batch):
            self._begin_shutdown(poller)
            return
        for i in range(len(batch)):
            ref task = batch[i]
            var id = task.connection.value
            if id not in self.clients or self._stopping_deadline > 0:
                continue
            ref client = self.clients[id]
            if client.protocol.get_state() != OPEN:
                continue
            try:
                if task.kind == TASK_TEXT:
                    send_text(client.protocol, task.payload)
                    client.collect()
                elif task.kind == TASK_BINARY:
                    client.send_binary(task.payload)
                elif task.kind == TASK_CLOSE:
                    client.close(task.code, task.reason)
                client.flush()
                Self._watch(client, poller, id)
            except error:
                logger.debug("Worker command failed: ", error)
                client.abort()
        batch.clear()

    def _loop(mut self, mut poller: Poller) raises:
        var batch = List[Task](capacity=self.task_queue_capacity if self._control else 0)
        while self.running:
            if self.accept_paused_until > 0 and now_ms() >= self.accept_paused_until:
                poller.watch(1, self.ln.fd, 0)
                self.accept_paused_until = 0
            # Timeout checks also run when no network events arrive.
            var wait_ms = 100
            if self._stopping_deadline > 0:
                wait_ms = min(wait_ms, max(0, self._stopping_deadline - now_ms()))
            var count = poller.wait(wait_ms)
            for i in range(count):
                var id = poller.ids[i]
                var flags = poller.flags[i]
                if id == WAKE_ID:
                    self._tasks(poller, batch)
                    continue
                if id == 0:
                    if self._stopping_deadline == 0:
                        self._accept(poller)
                    continue
                if id not in self.clients:
                    continue
                ref client = self.clients[id]
                try:
                    if flags & (1 | 8192 | 16) != 0:
                        Self._read(client)
                    if not client.conn.is_closed():
                        client.collect()
                        client.flush()
                    if flags & 8 != 0:
                        client.abort()
                except error:
                    # A queue, network or parser failure belongs to this client.
                    logger.debug("Connection failed: ", error)
                    client.abort()
                var stop_requested = client._shutdown_requested
                Self._watch(client, poller, id)
                if stop_requested:
                    self._begin_shutdown(poller)
            var expired = List[UInt64]()
            var now = now_ms()
            var alive = List[UInt64]()
            for id in self.client_ids:
                ref client = self.clients[id]
                var timeout = client.conn.is_closed()
                if self._stopping_deadline > 0:
                    timeout = timeout or now >= self._stopping_deadline
                if client.protocol.get_state() == CONNECTING:
                    timeout = timeout or now - client.accepted_at >= self.handshake_timeout_ms
                elif client.closing_at > 0:
                    timeout = timeout or now - client.closing_at >= self.close_timeout_ms
                else:
                    timeout = timeout or now - client.last_activity >= self.idle_timeout_ms
                if timeout:
                    expired.append(id)
                else:
                    alive.append(id)
            for id in expired:
                # Closing the sole descriptor automatically removes it from epoll.
                var removed = self.clients.pop(id)
                removed.abort()
            self.client_ids = alive^
            if self._stopping_deadline > 0 and not self.client_ids:
                self.running = False

    def _accept(mut self, poller: Poller) raises:
        # Bound accept work as well as read/write work in each reactor turn.
        for _ in range(64):
            var fd: Int32
            try:
                fd = self.ln.accept()
            except error:
                # Resource exhaustion must not terminate existing connections or
                # spin continuously on a readable listener that cannot accept.
                logger.warn("Temporarily pausing accept: ", error)
                poller.watch(2, self.ln.fd, 0)
                self.accept_paused_until = now_ms() + 100
                return
            if fd == -2:
                return
            var conn = Transport(fd)
            if len(self.clients) >= self.max_connections:
                conn.close()
                continue
            if self.next_id >= WAKE_ID:
                raise Error("Connection ID space exhausted")
            var id = self.next_id
            self.next_id += 1
            poller.watch(1, fd, id)
            self.client_ids.append(id)
            self.clients[id] = WSConnection(conn^, ServerProtocol(self.origins, max_size=self.max_request_body_size), self.max_pending_bytes, self.close_timeout_ms)
            self.clients[id]._identifier = ConnectionId(self._worker_id, id, 0)
            if self._control:
                var group = self._control.value()
                self.clients[id]._identifier = ConnectionId(self._worker_id, id, group.ptr()[].epoch)
                self.clients[id]._server = ServerHandle(group)

    @staticmethod
    def _read(mut client: WSConnection) raises:
        for _ in range(4):
            var buffer = Bytes()
            var count = client.conn.try_read(buffer)
            if count == -2:
                return
            if count == 0:
                receive_eof(client.protocol)
                client.close_after_write = True
                client.collect()
                return
            client.last_activity = now_ms()
            try:
                receive_data(client.protocol, buffer)
            except error:
                if client.protocol.get_state() == CONNECTING:
                    var response = client.protocol.reject(400, "Bad Request", "Invalid WebSocket handshake")
                    client.protocol.send_response(response)
                    client.collect()
                    return
                raise error
            if client.protocol.get_state() == CONNECTING:
                var requests = client.protocol.events_received()
                if len(requests) == 0:
                    continue
                var response = client.protocol.accept(requests[0][HTTPRequest])
                client.protocol.send_response(response)
                client.collect()
                if response.status_code != 101:
                    return
                # TCP may deliver the HTTP request and the first frame together.
                receive_data(client.protocol, Bytes())
            var events = client.protocol.events_received()
            if client.protocol.get_parser_exc():
                client.collect()
                return
            for event in events:
                if not event.isa[Frame]() or not event[Frame].is_data():
                    continue
                if event[Frame].opcode != OpCode.OP_CONT:
                    client.message_opcode = event[Frame].opcode
                client.message.extend(event[Frame].data[:])
                if event[Frame].fin:
                    # Detach the payload before borrowing the connection mutably.
                    var message = client.message^
                    client.message = Bytes()
                    try:
                        Self.handler(client, message[:])
                    except error:
                        logger.debug("Handler failed: ", error)
                        if client.protocol.get_state() == OPEN:
                            fail(client.protocol, 1011, "Handler failed")
                        else:
                            client.close_after_write = True
                    client.message.clear()
                    if client.protocol.get_state() != OPEN or client.conn.is_closed():
                        client.collect()
                        return
            client.collect()
            if client.close_after_write:
                return

    def address(self) -> String:
        var host = "[" + self.host + "]" if ":" in self.host else self.host
        return host + ":" + String(self.port)

    def shutdown(mut self):
        """Join managed workers or release this reactor's local resources.

        The owner calls this method. Concurrent callers use ServerHandle,
        whose shutdown request never joins or touches connection objects.
        """
        if self._workers:
            try:
                if self._workers.value().on_worker_thread():
                    self._workers.value().handle().shutdown()
                    return
                self._workers.value().shutdown()
                self._workers = None
            except error:
                logger.error("Could not join server workers: ", error)
                external_call["abort", NoneType]()
        self.running = False
        self.clients.clear()
        self.client_ids.clear()
        self.ln.close()
        if self._control and not self._is_worker:
            try:
                var control = self._control.value().ptr()[].worker_handle(0)
                if control.snapshot()[0] < 2:
                    control.finish()
                var group = self._control.value().ptr().unsafe_mut_cast[True]()
                group[].changed.owner.close()
            except error:
                logger.error("Could not close server controls: ", error)
                external_call["abort", NoneType]()


def serve[handler: ConnHandler](host: String, port: Int) raises -> Server[handler]:
    return Server[handler](host, port)


@fieldwise_init
struct ServerSession[handler: ConnHandler, origin: MutOrigin](ImplicitlyCopyable):
    # The session is a tracked borrow; it cannot outlive the server owner.
    var pointer: Pointer[mut=True, Server[Self.handler], Self.origin]
    def serve_forever(self) raises:
        self.pointer[].serve_forever()
    def shutdown(self):
        self.pointer[].shutdown()
    def address(self) -> String:
        return self.pointer[].address()
