"""Opaque POSIX mutex ownership for short inter-thread critical sections."""
from std.ffi import external_call
from std.memory import Pointer
from mojolt.websockets.treading.thread import ThreadContext, check_status


struct Mutex(Movable):
    """Own a nonrecursive mutex; destruction requires no remaining users.

    acquire/release may be called concurrently through stable borrowed storage.
    The acquiring thread must release it before destruction. Owning objects
    must not move while another thread can access their mutex.
    """

    var _handle: ThreadContext

    def __init__(out self) raises:
        self._handle = None
        check_status["mutex create"](
            external_call["mojolt_mutex_create", Int32](
                Pointer(to=self._handle)
            )
        )

    def __deinit__(deinit self):
        if self._handle:
            if (
                external_call["mojolt_mutex_destroy", Int32](
                    Pointer(to=self._handle)
                )
                != 0
            ):
                external_call["abort", NoneType]()

    def acquire(self) raises:
        """Block until the calling thread exclusively owns the mutex."""
        check_status["mutex lock"](
            external_call["mojolt_mutex_lock", Int32](self._handle)
        )

    def release(self):
        """Unlock on the acquiring thread; ownership violations are fatal."""
        if external_call["mojolt_mutex_unlock", Int32](self._handle) != 0:
            external_call["abort", NoneType]()

    def try_acquire(self) raises -> Bool:
        """Acquire without blocking; return False when already locked."""
        var status = external_call["mojolt_mutex_try_lock", Int32](self._handle)
        if status == 16:
            return False
        check_status["mutex try lock"](status)
        return True
