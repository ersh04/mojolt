"""Bounded worker mailboxes and thread-safe server control handles.

Only mailbox state is shared. Protocols, sockets, and connection buffers remain
on their reactor thread. Producers transfer owned payloads and receive False
when the mailbox is full, stopping, or closed. A successful submission means
queued, not delivered: stale connection IDs are discarded by the reactor.
"""
from std.ffi import external_call
from std.memory import ArcPointer, Pointer
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.treading.mutex import Mutex
from mojolt.websockets.treading.notification import Notification
from mojolt.websockets.utils.bytes import str_to_bytes

comptime TASK_TEXT = 1
comptime TASK_BINARY = 2
comptime TASK_CLOSE = 3
comptime WAKE_ID: UInt64 = 18446744073709551615


@fieldwise_init
struct ConnectionId(ImplicitlyCopyable):
    """Identify a connection within a server run, independently of its fd.

    A random run epoch rejects tokens from other server instances or previous
    runs. Each worker issues increasing local IDs and never reuses a live ID.
    """

    var worker: Int
    var value: UInt64
    var epoch: UInt64


@fieldwise_init
struct Task(Movable):
    """Own one command and its payload until execution or queue rejection."""

    var connection: ConnectionId
    var kind: Int
    var payload: Bytes
    var code: Int
    var reason: String


struct MailboxState(Movable):
    """Mutex-protected mutable storage; references exist only inside the lock.
    """

    var wake: Notification
    var tasks: List[Task]
    var capacity: Int
    var max_payload_bytes: Int
    var stopping: Bool
    var status: Int
    var error: String

    def __init__(out self, capacity: Int, max_payload_bytes: Int) raises:
        self.wake = Notification()
        self.tasks = List[Task](capacity=capacity)
        self.capacity = capacity
        self.max_payload_bytes = max_payload_bytes
        self.stopping = False
        self.status = 0
        self.error = ""


struct WorkerControl(Movable):
    """Share a bounded MPSC mailbox through an immutable synchronization shell.

    Methods borrow self immutably and acquire the mutex before obtaining any
    mutable state reference. No mutable Mojo borrow spans lock acquisition.
    Producers signal under the same lock used to close the descriptor. Stop
    uses an independent flag, so it succeeds even when the command queue is full.
    """

    var mutex: Mutex
    var state: ArcPointer[MailboxState]

    def __init__(out self, capacity: Int, max_payload_bytes: Int) raises:
        if capacity < 1 or max_payload_bytes < 1:
            raise Error("Invalid mailbox limits")
        self.mutex = Mutex()
        self.state = ArcPointer(MailboxState(capacity, max_payload_bytes))

    def submit(self, var task: Task) raises -> Bool:
        """Transfer a command; FIFO order follows successful mutex acquisition.
        """
        self.mutex.acquire()
        try:
            ref state = self.state[]
            if (
                state.stopping
                or state.status >= 2
                or len(state.tasks) >= state.capacity
            ):
                return False
            if (
                len(task.payload) > state.max_payload_bytes
                or task.reason.byte_length() > 123
            ):
                return False
            state.tasks.append(task^)
            state.wake.signal()
            return True
        finally:
            self.mutex.release()

    def request_stop(self) raises:
        """Idempotently request shutdown independently of queue capacity."""
        self.mutex.acquire()
        try:
            ref state = self.state[]
            if not state.stopping and state.status < 2:
                state.stopping = True
                state.wake.signal()
        finally:
            self.mutex.release()

    def take_batch(self, mut batch: List[Task]) raises -> Bool:
        """Swap preallocated lists, discarding pending commands when stopping.
        """
        batch.clear()
        self.mutex.acquire()
        try:
            ref state = self.state[]
            state.wake.drain()
            if state.stopping:
                state.tasks.clear()
                return True
            swap(state.tasks, batch)
            return False
        finally:
            self.mutex.release()

    def mark_ready(self) raises:
        """Publish resource initialization success under the mutex."""
        self.mutex.acquire()
        self.state[].status = 1
        self.mutex.release()

    def snapshot(self) raises -> Tuple[Int, Bool, String]:
        """Read lifecycle state and an owned error string under the mutex."""
        self.mutex.acquire()
        try:
            ref state = self.state[]
            return (state.status, state.stopping, state.error)
        finally:
            self.mutex.release()

    def finish(self, error: String = "") raises:
        """Reject producers, discard pending payloads, and close eventfd."""
        self.mutex.acquire()
        try:
            ref state = self.state[]
            state.stopping = True
            state.status = 3 if error else 2
            state.error = error
            state.tasks.clear()
            state.wake.owner.close()
        finally:
            self.mutex.release()

    def descriptor(self) -> Int32:
        """Borrow eventfd on the consumer, which serializes it against finish.
        """
        return self.state.ptr()[].wake.owner.fd

    def wait(self, timeout_ms: Int = -1) raises:
        """Wait on the consumer thread; finish cannot run concurrently."""
        self.state.ptr()[].wake.wait(timeout_ms)


@fieldwise_init
struct WorkerMailbox(Copyable, Movable):
    """Keep synchronized mailbox storage alive through every operation."""

    var storage: ArcPointer[WorkerControl]

    def submit(self, var task: Task) raises -> Bool:
        """Transfer a task to the bounded producer queue."""
        return self.storage.ptr()[].submit(task^)

    def request_stop(self) raises:
        """Request stopping independently of task capacity."""
        self.storage.ptr()[].request_stop()

    def take_batch(self, mut batch: List[Task]) raises -> Bool:
        """Borrow the consumer output list for one atomic queue swap."""
        return self.storage.ptr()[].take_batch(batch)

    def mark_ready(self) raises:
        """Publish worker initialization success."""
        self.storage.ptr()[].mark_ready()

    def snapshot(self) raises -> Tuple[Int, Bool, String]:
        """Read lifecycle state under the mailbox mutex."""
        return self.storage.ptr()[].snapshot()

    def finish(self, error: String = "") raises:
        """Close the consumer after its last reactor operation."""
        self.storage.ptr()[].finish(error)

    def descriptor(self) -> Int32:
        """Borrow the eventfd number on the owning consumer thread."""
        return self.storage.ptr()[].descriptor()

    def wait(self, timeout_ms: Int = -1) raises:
        """Wait on the consumer thread; finish must not run concurrently."""
        self.storage.ptr()[].wait(timeout_ms)


struct GroupControl(Movable):
    """Immutable worker routing plus a manager notification descriptor.

    Populate workers before publishing any handle or starting native threads.
    Worker state remains independently synchronized by each mailbox mutex.
    """

    var workers: List[ArcPointer[WorkerControl]]
    var changed: Notification
    var epoch: UInt64

    def __init__(
        out self, count: Int, capacity: Int, max_payload_bytes: Int
    ) raises:
        if count < 1 or capacity < 1 or max_payload_bytes < 1:
            raise Error("Invalid worker group limits")
        self.workers = List[ArcPointer[WorkerControl]](capacity=count)
        self.changed = Notification()
        self.epoch = 0
        var bytes = external_call["getrandom", Int](
            Pointer(to=self.epoch), UInt(8), UInt32(0)
        )
        if bytes != 8:
            raise Error("Could not allocate a server run identifier")
        for _ in range(count):
            self.workers.append(
                ArcPointer(WorkerControl(capacity, max_payload_bytes))
            )

    def worker_handle(self, index: Int) -> WorkerMailbox:
        """Retain mailbox storage independently of the group borrow."""
        return WorkerMailbox(self.workers[index].copy())

    def request_stop(self) raises:
        """Wake every worker, including those whose ordinary queues are full."""
        for i in range(len(self.workers)):
            var worker = self.worker_handle(i)
            worker.request_stop()


struct ServerHandle(Copyable, Movable):
    """A shareable routing handle that never borrows connection state.

    Copies keep mailbox storage alive after the server has joined its workers.
    Such mailboxes are closed and reject commands. Concurrent submissions are
    ordered by each mailbox's mutex; different producers have no prior order.
    shutdown only requests stopping and never joins its calling thread.
    """

    var _group: ArcPointer[GroupControl]

    def __init__(out self, group: ArcPointer[GroupControl]):
        self._group = group.copy()

    def shutdown(self) raises:
        """Request graceful shutdown from any thread, including callbacks."""
        self._group.ptr()[].request_stop()

    def _submit(self, var task: Task) raises -> Bool:
        var group = self._group.ptr()
        var id = task.connection
        if (
            id.epoch != group[].epoch
            or id.worker < 0
            or id.worker >= len(group[].workers)
        ):
            return False
        var worker = group[].worker_handle(id.worker)
        return worker.submit(task^)

    def send_text(
        self, connection: ConnectionId, message: String
    ) raises -> Bool:
        """Queue an owned UTF-8 message; False indicates rejection."""
        return self._submit(
            Task(connection, TASK_TEXT, str_to_bytes(message), 0, "")
        )

    def send_binary(
        self, connection: ConnectionId, var payload: Bytes
    ) raises -> Bool:
        """Transfer a binary payload, consumed even if the queue rejects it."""
        return self._submit(Task(connection, TASK_BINARY, payload^, 0, ""))

    def close(
        self, connection: ConnectionId, code: Int = 1000, reason: String = ""
    ) raises -> Bool:
        """Queue a close handshake for the connection's owning reactor."""
        return self._submit(Task(connection, TASK_CLOSE, Bytes(), code, reason))
