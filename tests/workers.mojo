"""Validate bounded mailboxes, native producers, and startup rollback."""
from std.collections import Array, Span
from std.memory import ArcPointer, OwnedPointer
from std.sys import argv
from std.testing import assert_equal, assert_true, assert_false
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.sync.server import Server, WSConnection
from mojolt.websockets.treading.thread import (
    Thread,
    ThreadContext,
    available_cpus,
)
from mojolt.websockets.treading.notification import Notification
from mojolt.websockets.treading.task_queue import (
    WorkerControl,
    GroupControl,
    ServerHandle,
    Task,
    ConnectionId,
    TASK_BINARY,
)
from mojolt.websockets.treading.worker_manager import (
    WorkerManager,
    WorkerReactor,
)


def command(id: UInt64) -> Task:
    var payload: Bytes = [UInt8(id % 256)]
    return Task(ConnectionId(0, id, 1), TASK_BINARY, payload^, 0, "")


def test_queue_capacity_and_shutdown() raises:
    var control = WorkerControl(2, 32)
    assert_true(control.submit(command(1)))
    assert_true(control.submit(command(2)))
    assert_false(control.submit(command(3)))
    var batch = List[Task](capacity=2)
    assert_false(control.take_batch(batch))
    assert_equal(len(batch), 2)
    assert_equal(batch[0].connection.value, 1)
    assert_equal(batch[1].connection.value, 2)
    assert_equal(batch[0].payload[0], 1)
    assert_true(control.submit(command(3)))
    assert_true(control.submit(command(4)))
    control.request_stop()
    control.request_stop()
    assert_true(control.take_batch(batch))
    assert_equal(len(batch), 0)
    assert_false(control.submit(command(5)))
    control.finish()
    control.request_stop()
    assert_false(control.submit(command(6)))


@fieldwise_init
struct Producer(Movable):
    var group: ArcPointer[GroupControl]
    var index: Int
    var failed: Bool


def produce(raw: ThreadContext) abi("C") -> ThreadContext:
    var context = raw.value().unsafe_bitcast[Producer]()
    try:
        var worker = context[].group.ptr()[].worker_handle(0)
        for i in range(100):
            if not worker.submit(command(UInt64(context[].index * 1000 + i))):
                context[].failed = True
    except:
        context[].failed = True
    return None


def test_multiple_producers_and_ordering() raises:
    var group = ArcPointer(GroupControl(1, 512, 32))
    var contexts = List[OwnedPointer[Producer]](capacity=4)
    var threads = List[Thread](capacity=4)
    for i in range(4):
        contexts.append(OwnedPointer(Producer(group.copy(), i, False)))
        var raw = (
            contexts[i]
            .ptr()
            .unsafe_bitcast[UInt8]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        threads.append(Thread(produce, raw))
    for i in range(4):
        _ = threads[i].join()
        assert_false(contexts[i].ptr()[].failed)
    var batch = List[Task](capacity=512)
    var worker = group.ptr()[].worker_handle(0)
    assert_false(worker.take_batch(batch))
    assert_equal(len(batch), 400)
    var next = Array[Int, 4](fill=0)
    for i in range(len(batch)):
        ref task = batch[i]
        var producer = Int(task.connection.value) // 1000
        assert_equal(Int(task.connection.value) % 1000, next[producer])
        next[producer] += 1
    for i in range(4):
        assert_equal(next[i], 100)
    worker.finish()


@fieldwise_init
struct HandshakeProducer(Movable):
    var group: ArcPointer[GroupControl]
    var ack: Notification
    var failed: Bool


def handshake_producer(raw: ThreadContext) abi("C") -> ThreadContext:
    var context = raw.value().unsafe_bitcast[HandshakeProducer]()
    try:
        var worker = context[].group.ptr()[].worker_handle(0)
        for i in range(100):
            if not worker.submit(command(UInt64(i))):
                raise Error("Mailbox unexpectedly full")
            context[].ack.wait(5000)
    except:
        context[].failed = True
    return None


def test_no_lost_wakeups() raises:
    var group = ArcPointer(GroupControl(1, 1, 32))
    var context = OwnedPointer(
        HandshakeProducer(group.copy(), Notification(), False)
    )
    var raw = (
        context.ptr()
        .unsafe_bitcast[UInt8]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var thread = Thread(handshake_producer, raw)
    var worker = group.ptr()[].worker_handle(0)
    var batch = List[Task](capacity=1)
    for i in range(100):
        worker.wait(5000)
        assert_false(worker.take_batch(batch))
        assert_equal(len(batch), 1)
        assert_equal(batch[0].connection.value, UInt64(i))
        context.ptr()[].ack.signal()
    _ = thread.join()
    assert_false(context.ptr()[].failed)
    worker.finish()


struct TestReactor(Movable, WorkerReactor):
    var reject: Bool
    var closed: Bool
    var fail_after_ready: Bool

    def __init__(
        out self, reject: Bool, closed: Bool, fail_after_ready: Bool = False
    ):
        self.reject = reject
        self.closed = closed
        self.fail_after_ready = fail_after_ready

    def run_worker(
        mut self, group: ArcPointer[GroupControl], worker: Int, cpu: Int
    ) raises:
        if self.reject:
            raise Error("Intentional worker initialization failure")
        var control = group.ptr()[].worker_handle(worker)
        control.mark_ready()
        group.ptr()[].changed.signal()
        var batch = List[Task]()
        while True:
            control.wait(5000)
            if control.take_batch(batch):
                return
            if self.fail_after_ready:
                raise Error("Intentional worker execution failure")

    def shutdown(mut self):
        self.closed = True


def test_worker_startup_and_repeated_shutdown() raises:
    var manager = WorkerManager(2, 2, 32)
    var reactors = List[TestReactor]()
    reactors.append(TestReactor(False, False))
    reactors.append(TestReactor(False, False))
    var cpus: List[Int] = [-1, -1]
    manager.start(reactors^, cpus)
    var handle = manager.handle()
    handle.shutdown()
    handle.shutdown()
    manager.wait()
    manager.shutdown()
    manager.shutdown()
    assert_false(
        handle.send_binary(
            ConnectionId(0, 1, manager.group.ptr()[].epoch), Bytes()
        )
    )


def test_partial_startup_failure() raises:
    var manager = WorkerManager(2, 2, 32)
    var reactors = List[TestReactor]()
    reactors.append(TestReactor(False, False))
    reactors.append(TestReactor(True, False))
    var cpus: List[Int] = [-1, -1]
    var failed = False
    try:
        manager.start(reactors^, cpus)
    except:
        failed = True
    assert_true(failed)
    assert_equal(len(manager.records), 0)
    for i in range(2):
        assert_true(manager.group.ptr()[].worker_handle(i).snapshot()[0] >= 2)


def test_stale_tokens_and_payload_limits() raises:
    var group = ArcPointer(GroupControl(1, 2, 2))
    var handle = ServerHandle(group)
    var id = ConnectionId(0, 1, group.ptr()[].epoch)
    assert_false(handle.send_text(id, "oversized"))
    assert_false(handle.send_text(ConnectionId(1, 1, id.epoch), "a"))
    assert_false(handle.send_text(ConnectionId(0, 1, id.epoch ^ 1), "a"))
    assert_true(handle.send_text(id, "ok"))
    handle.shutdown()
    group.ptr()[].worker_handle(0).finish()
    assert_false(handle.send_text(id, "a"))


def echo_lifetime(mut connection: WSConnection, data: Span[Byte, _]) raises:
    connection.send_binary(Bytes(data))


def abandoned_handle() raises -> ServerHandle:
    var server = Server[echo_lifetime]("127.0.0.1", 0)
    return server.handle()


def test_handle_after_direct_server_destruction() raises:
    var handle = abandoned_handle()
    var epoch = handle._group.ptr()[].epoch
    assert_false(handle.send_text(ConnectionId(0, 1, epoch), "closed"))
    handle.shutdown()


def test_worker_execution_failure_stops_group() raises:
    var manager = WorkerManager(2, 2, 32)
    var reactors = List[TestReactor]()
    reactors.append(TestReactor(False, False, True))
    reactors.append(TestReactor(False, False, True))
    var cpus: List[Int] = [-1, -1]
    manager.start(reactors^, cpus)
    var handle = manager.handle()
    assert_true(
        handle.send_binary(
            ConnectionId(0, 1, manager.group.ptr()[].epoch), Bytes()
        )
    )
    var failed = False
    try:
        manager.wait()
    except:
        failed = True
    manager.shutdown()
    assert_true(failed)


def test_invalid_worker_configuration() raises:
    var failed = False
    try:
        var server = Server[echo_lifetime]("127.0.0.1", 0, worker_count=-1)
        server.shutdown()
    except:
        failed = True
    assert_true(failed)


def test_uninitialized_thread_rejects_lifecycle_operations() raises:
    var thread = Thread()
    var join_failed = False
    var detach_failed = False
    var create_failed = False
    try:
        _ = thread.join()
    except:
        join_failed = True
    try:
        thread.detach()
    except:
        detach_failed = True
    try:
        thread.start(produce, None)
    except:
        create_failed = True
    assert_true(join_failed and detach_failed and create_failed)
    assert_false(thread.joinable())


def test_managing_server_lifecycle_state() raises:
    var server = Server[echo_lifetime]("127.0.0.1", 0, worker_count=2)
    server.bind()
    assert_true(server.running)
    var handle = server.handle()
    handle.shutdown()
    server._workers.value().wait()
    var closed_handle = server.handle()
    var epoch = closed_handle._group.ptr()[].epoch
    assert_false(closed_handle.send_text(ConnectionId(0, 1, epoch), "closed"))
    server.serve_forever()
    assert_false(server.running)


def main() raises:
    var tests: List[Tuple[String, def() raises thin -> None]] = [
        ("test_queue_capacity_and_shutdown", test_queue_capacity_and_shutdown),
        (
            "test_multiple_producers_and_ordering",
            test_multiple_producers_and_ordering,
        ),
        ("test_no_lost_wakeups", test_no_lost_wakeups),
        (
            "test_worker_startup_and_repeated_shutdown",
            test_worker_startup_and_repeated_shutdown,
        ),
        ("test_partial_startup_failure", test_partial_startup_failure),
        (
            "test_stale_tokens_and_payload_limits",
            test_stale_tokens_and_payload_limits,
        ),
        (
            "test_handle_after_direct_server_destruction",
            test_handle_after_direct_server_destruction,
        ),
        (
            "test_worker_execution_failure_stops_group",
            test_worker_execution_failure_stops_group,
        ),
        (
            "test_invalid_worker_configuration",
            test_invalid_worker_configuration,
        ),
    ]
    tests.append(
        (
            "test_uninitialized_thread_rejects_lifecycle_operations",
            test_uninitialized_thread_rejects_lifecycle_operations,
        )
    )
    tests.append(
        (
            "test_managing_server_lifecycle_state",
            test_managing_server_lifecycle_state,
        )
    )
    var arguments = argv()
    var selected = arguments[1] if len(arguments) > 1 else String("all")
    for test in tests:
        if selected == "all" or selected == test[0]:
            test[1]()
            print("ok", test[0])
