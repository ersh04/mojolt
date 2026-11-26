"""Start, supervise, stop, and join independently owned Mojo reactors."""
from std.ffi import external_call
from std.memory import ArcPointer, OwnedPointer, Pointer
from std.runtime import initialize_runtime
from mojolt.websockets.transport import now_ms
from mojolt.websockets.treading.thread import (
    Thread,
    ThreadContext,
    ThreadFunction,
)
from mojolt.websockets.treading.task_queue import GroupControl, ServerHandle


trait WorkerReactor(Deinitable, Movable):
    """A reactor whose mutable state is accessed only by its native worker."""

    def run_worker(
        mut self, group: ArcPointer[GroupControl], worker: Int, cpu: Int
    ) raises:
        ...

    def shutdown(mut self):
        ...


@fieldwise_init
struct WorkerContext[R: WorkerReactor](Movable):
    """Heap-stable worker state retained by its manager until after join."""

    var reactor: Self.R
    var group: ArcPointer[GroupControl]
    var index: Int
    var cpu: Int


comptime ContextRelease = def(ThreadContext) thin abi("C") -> None


def _release_context[R: WorkerReactor](raw: ThreadContext) abi("C"):
    """Reclaim the exact OwnedPointer allocation after the thread has joined."""
    _ = OwnedPointer[WorkerContext[R]](
        unsafe_from_raw_pointer=raw.value().unsafe_bitcast[WorkerContext[R]]()
    )


@fieldwise_init
struct WorkerRecord(Movable):
    """Own a type-erased context and release it only after joining its thread.

    The release callback restores the concrete OwnedPointer type. Erasing that
    type keeps server configuration independent of a nested reactor layout.
    """

    var context: ThreadContext
    var release: ContextRelease
    var thread: Thread

    def __deinit__(deinit self):
        if self.thread.joinable():
            try:
                _ = self.thread.join()
            except:
                external_call["abort", NoneType]()
        self.release(self.context)


def _worker_entry[
    R: WorkerReactor
](raw: ThreadContext) abi("C") -> ThreadContext:
    """Contain all exceptions and publish completion before returning to C."""
    initialize_runtime()
    var context = raw.value().unsafe_bitcast[WorkerContext[R]]()
    var error_message = String()
    try:
        context[].reactor.run_worker(
            context[].group, context[].index, context[].cpu
        )
    except error:
        error_message = String(error)
        try:
            context[].group.ptr()[].request_stop()
        except stop_error:
            error_message += String("; stopping workers: ", stop_error)
    context[].reactor.shutdown()
    try:
        var control = context[].group.ptr()[].worker_handle(context[].index)
        control.finish(error_message)
        context[].group.ptr()[].changed.signal()
    except:
        # A broken lifecycle channel cannot safely leave the manager waiting.
        external_call["abort", NoneType]()
    return None


struct WorkerManager(Movable):
    """Manage native threads while every reactor keeps exclusive local state.

    The manager is used by one owning thread. Only ServerHandle copies may be
    shared. Stable contexts are allocated before thread creation and destroyed
    after joining. Destruction requests stopping and joins all created threads.
    """

    var group: ArcPointer[GroupControl]
    var records: List[WorkerRecord]
    var startup_timeout_ms: Int
    var _started: Bool

    def __init__(
        out self,
        workers: Int,
        capacity: Int,
        max_payload_bytes: Int,
        startup_timeout_ms: Int = 10000,
    ) raises:
        if (
            workers < 1
            or capacity < 1
            or max_payload_bytes < 1
            or startup_timeout_ms < 1
        ):
            raise Error("Invalid worker manager limits")
        self.group = ArcPointer(
            GroupControl(workers, capacity, max_payload_bytes)
        )
        self.records = List[WorkerRecord](capacity=workers)
        self.startup_timeout_ms = startup_timeout_ms
        self._started = False

    def __deinit__(deinit self):
        try:
            if self.on_worker_thread():
                external_call["abort", NoneType]()
            self.shutdown()
        except:
            external_call["abort", NoneType]()

    def handle(self) -> ServerHandle:
        """Return a shareable command handle without exposing reactor objects.
        """
        return ServerHandle(self.group)

    def start[
        R: WorkerReactor
    ](mut self, var reactors: List[R], cpus: List[Int]) raises:
        """Start all workers and wait for their resource initialization barrier.

        A negative CPU means no pinning. On any failure, every successfully
        started thread is notified and joined before its context is released.
        """
        if (
            self._started
            or len(reactors) != len(cpus)
            or len(reactors) != len(self.group.ptr()[].workers)
        ):
            raise Error("Invalid worker startup state")
        self._started = True
        try:
            var entry: ThreadFunction = _worker_entry[R]
            for i in range(len(cpus)):
                var context = OwnedPointer(
                    WorkerContext[R](
                        reactors.pop(), self.group.copy(), i, cpus[i]
                    )
                )
                var raw = (
                    (context^)
                    .unsafe_take_allocation()
                    .unsafe_leak()
                    .unsafe_bitcast[UInt8]()
                )
                var release: ContextRelease = _release_context[R]
                self.records.append(WorkerRecord(raw, release, Thread()))
                self.records[i].thread.start(entry, raw)
            self._await_ready()
        except error:
            self.shutdown()
            raise error

    def _await_ready(self) raises:
        var deadline = now_ms() + self.startup_timeout_ms
        while True:
            var ready = True
            for i in range(len(self.records)):
                var state = self.group.ptr()[].worker_handle(i).snapshot()
                if state[0] == 3:
                    raise Error("Worker initialization failed: ", state[2])
                if state[0] == 2:
                    raise Error("Worker stopped during initialization")
                ready = ready and state[0] == 1
            if ready:
                return
            var remaining = deadline - now_ms()
            if remaining <= 0:
                raise Error("Worker startup timeout")
            self.group.ptr()[].changed.wait(remaining)

    def wait(self) raises:
        """Wait on lifecycle notifications and report worker execution errors.
        """
        while True:
            var finished = True
            var failure = String()
            for i in range(len(self.records)):
                var state = self.group.ptr()[].worker_handle(i).snapshot()
                finished = finished and state[0] >= 2
                if state[0] == 3:
                    failure = state[2]
            if failure:
                self.group.ptr()[].request_stop()
            if finished:
                if failure:
                    raise Error("Worker failed: ", failure)
                return
            self.group.ptr()[].changed.wait()

    def on_worker_thread(self) -> Bool:
        """Return whether the caller belongs to this manager's native workers.
        """
        for i in range(len(self.records)):
            if self.records[i].thread.is_current():
                return True
        return False

    def shutdown(mut self) raises:
        """Request stopping and join every created worker on the manager thread.

        A request made on a worker only signals stopping; the managing thread
        performs the joins. External applications should use ServerHandle.
        """
        self.group.ptr()[].request_stop()
        if self.on_worker_thread():
            return
        for i in range(len(self.records)):
            if self.records[i].thread.joinable():
                _ = self.records[i].thread.join()
        self.records.clear()
        for i in range(len(self.group.ptr()[].workers)):
            var control = self.group.ptr()[].worker_handle(i)
            if control.snapshot()[0] < 2:
                control.finish()
        var group = self.group.ptr().unsafe_mut_cast[True]()
        group[].changed.owner.close()
