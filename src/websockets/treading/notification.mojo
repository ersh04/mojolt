"""Coalescing eventfd notifications registered in the owning worker's epoll."""
from std.ffi import external_call
from mojolt.websockets.transport import Transport, transport_error, now_ms
from mojolt.websockets.treading.thread import check_status


struct Notification(Movable):
    """Own a nonblocking eventfd. Owners synchronize close against producers.

    signal is safe for concurrent producers while the descriptor remains open.
    drain has one consumer. Saturation means a wake-up is already pending.
    """

    var owner: Transport

    def __init__(out self) raises:
        var fd = external_call["mojolt_event_create", Int32]()
        if fd < 0:
            raise Error("eventfd: errno=", -fd)
        self.owner = Transport(fd)

    def signal(self) raises:
        """Make a pending wake-up observable without blocking."""
        check_status["eventfd signal"](
            external_call["mojolt_event_signal", Int32](self.owner.fd)
        )

    def drain(self) raises:
        """Consume all notifications present at a single atomic read."""
        check_status["eventfd drain"](
            external_call["mojolt_event_drain", Int32](self.owner.fd)
        )

    def wait(self, timeout_ms: Int = -1) raises:
        """Wait for a notification; -1 blocks indefinitely, EINTR retries."""
        if self.owner.is_closed():
            raise Error("Notification is closed")
        var deadline = now_ms() + timeout_ms
        while True:
            var remaining = -1 if timeout_ms < 0 else max(
                0, deadline - now_ms()
            )
            var ready = external_call["ws_poll", Int32](
                self.owner.fd, Int32(0), Int32(min(remaining, 2147483647))
            )
            if ready == -2:
                continue
            if ready < 0:
                raise transport_error("notification poll")
            if ready == 0:
                raise Error("Notification timeout")
            self.drain()
            return
