"""Exclusive ownership of opaque native threads on Linux.

The C entry point must contain all exceptions. Its context is borrowed and must
remain at a stable address until termination, including after explicit detach.
Destruction joins an owned thread; it never silently detaches a server worker.
Destroying a thread object from its own entry point is a fatal lifecycle error.
"""
from std.ffi import external_call
from std.memory import OptionalPointer, Pointer
from std.runtime import initialize_runtime

comptime ThreadContext = OptionalPointer[UInt8, MutUntrackedOrigin]
comptime ThreadFunction = def(ThreadContext) thin abi("C") -> ThreadContext


def check_status[operation: StaticString](status: Int32) raises:
    """Check native status codes, which are independent of thread-local errno.
    """
    if status != 0:
        raise Error(operation, ": errno=", status)


def _cpu_ids(cpus: List[Int]) raises -> List[Int32]:
    if not cpus:
        raise Error("CPU affinity must contain at least one CPU")
    var ids = List[Int32](capacity=len(cpus))
    for cpu in cpus:
        if cpu < 0 or cpu >= 2147483647:
            raise Error("CPU index is out of range")
        ids.append(Int32(cpu))
    return ids^


def available_cpus() raises -> List[Int]:
    """Return the calling thread's CPU IDs, which may be sparse.

    Logical CPU affinity does not describe cgroup bandwidth quotas. Enumeration
    retries if the affinity mask grows between the count and the ID query.
    """
    var count = external_call["mojolt_thread_get_available_cpus", Int32]()
    if count <= 0:
        raise Error("CPU enumeration failed: ", count)
    var ids = List[Int32](length=Int(count), fill=0)
    while True:
        count = external_call["mojolt_thread_get_available_cpu_ids", Int32](
            ids.unsafe_ptr(), Int32(len(ids))
        )
        if count == -28:
            ids.resize(len(ids) * 2, fill=0)
            continue
        if count < 0:
            raise Error("CPU enumeration failed: ", count)
        var result = List[Int](capacity=Int(count))
        for i in range(Int(count)):
            result.append(Int(ids[i]))
        return result^


def cpu_count() raises -> Int:
    """Return the size of the calling thread's allowed logical CPU set."""
    var count = external_call["mojolt_thread_get_available_cpus", Int32]()
    if count <= 0:
        raise Error("CPU enumeration failed: ", count)
    return Int(count)


def set_current_thread_affinity(cpus: List[Int]) raises:
    """Restrict the calling thread to the supplied logical CPU IDs."""
    var ids = _cpu_ids(cpus)
    check_status["thread affinity"](
        external_call["mojolt_thread_set_current_cpu_ids", Int32](
            ids.unsafe_ptr(), Int32(len(ids))
        )
    )


def set_current_thread_name(var name: String) raises:
    """Set a Linux thread name containing at most 15 UTF-8 bytes and no NUL."""
    if name.byte_length() > 15 or name.find("\x00") != -1:
        raise Error("Thread name must contain at most 15 bytes and no NUL")
    check_status["thread name"](
        external_call["mojolt_thread_set_current_name", Int32](
            name.as_c_string_span()
        )
    )


struct Thread(Movable):
    """Own a native thread handle, cleared only after successful join/detach.

    Lifecycle methods require exclusive access by the owner. Context storage
    belongs to the caller. Joining blocks; explicit detach transfers the duty
    of keeping the context alive to the application. Join failure leaves the
    handle owned so the caller can resolve the error and retry.
    """

    var _handle: ThreadContext

    def __init__(out self):
        self._handle = None

    def __init__(
        out self, target: ThreadFunction, context: ThreadContext
    ) raises:
        self._handle = None
        self.start(target, context)

    def __init__(out self, *, deinit move: Self):
        self._handle = move._handle

    def __deinit__(deinit self):
        if self._handle:
            var status = external_call["mojolt_thread_join", Int32](
                Pointer(to=self._handle)
            )
            if status != 0:
                # A failed implicit join cannot release a live borrowed context.
                external_call["abort", NoneType]()

    def start(mut self, target: ThreadFunction, context: ThreadContext) raises:
        """Start a C ABI callback with a stable, caller-owned context."""
        if self._handle:
            raise Error("Thread must be joined or detached before restarting")
        if not context:
            raise Error("Thread requires a stable non-null context pointer")
        initialize_runtime()
        check_status["thread create"](
            external_call["mojolt_thread_create", Int32](
                Pointer(to=self._handle), target, context
            )
        )

    def joinable(self) -> Bool:
        """Return whether this object owns a native thread handle."""
        return Bool(self._handle)

    def is_current(self) -> Bool:
        """Return whether this handle identifies the calling thread."""
        if not self._handle:
            return False
        return (
            external_call["mojolt_thread_is_current", Int32](self._handle) == 1
        )

    def join(mut self) raises -> ThreadContext:
        """Block until termination, release ownership, and return the result."""
        if not self._handle:
            raise Error("Thread is not joinable")
        var result = ThreadContext(None)
        check_status["thread join"](
            external_call["mojolt_thread_join_result", Int32](
                Pointer(to=self._handle), Pointer(to=result)
            )
        )
        return result

    def detach(mut self) raises:
        """Release ownership while the caller retains the context until exit."""
        if not self._handle:
            raise Error("Thread is not joinable")
        check_status["thread detach"](
            external_call["mojolt_thread_detach", Int32](
                Pointer(to=self._handle)
            )
        )

    def set_affinity(self, cpus: List[Int]) raises:
        """Set an owned thread's CPU set without exposing native ABI types."""
        if not self._handle:
            raise Error("Thread is not joinable")
        var ids = _cpu_ids(cpus)
        check_status["thread affinity"](
            external_call["mojolt_thread_set_affinity", Int32](
                self._handle, ids.unsafe_ptr(), Int32(len(ids))
            )
        )
