"""Exercise socket bindings, binary transfers, and thread-local errno."""

from std.collections import Array
from std.ffi import external_call
from std.memory import Pointer
from std.sys import argv, size_of
from std.testing import assert_equal, assert_false, assert_true
from mojolt.websockets.libc import (
    AF_INET,
    AF_UNIX,
    SOCK_STREAM,
    SOCK_DGRAM,
    SOCK_CLOEXEC,
    SOCK_NONBLOCK,
    SOL_SOCKET,
    SO_TYPE,
    SO_REUSEADDR,
    SO_RCVLOWAT,
    SHUT_WR,
    EBADF,
    EAGAIN,
    EINVAL,
    EPIPE,
    c_int,
    c_char,
    c_size_t,
    sockaddr,
    sockaddr_in,
    sockaddr_in6,
    addrinfo,
    socklen_t,
    socket,
    setsockopt,
    getsockopt,
    bind,
    listen,
    connect,
    accept,
    getsockname,
    getpeername,
    recv,
    send,
    recvfrom,
    sendto,
    shutdown,
    close,
    inet_pton,
    inet_ntop,
    INET_ADDRSTRLEN,
    ntohs,
    get_errno,
    _close,
    _socket,
)
from mojolt.websockets.treading.thread import Thread, ThreadContext


def test_integer_options() raises:
    var fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
    try:
        assert_equal(getsockopt(fd, SOL_SOCKET, SO_TYPE), SOCK_STREAM)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        assert_equal(getsockopt(fd, SOL_SOCKET, SO_REUSEADDR), 1)
        setsockopt(fd, SOL_SOCKET, SO_RCVLOWAT, 4096)
        assert_equal(getsockopt(fd, SOL_SOCKET, SO_RCVLOWAT), 4096)
    finally:
        close(fd)


def test_ipv4_conversion() raises:
    var address = inet_pton[AF_INET]("127.0.0.1")
    var octets = Pointer(to=address).unsafe_bitcast[UInt8]()
    assert_equal(octets[unsafe_offset=0], 127)
    assert_equal(octets[unsafe_offset=1], 0)
    assert_equal(octets[unsafe_offset=2], 0)
    assert_equal(octets[unsafe_offset=3], 1)
    assert_equal(inet_ntop[AF_INET, INET_ADDRSTRLEN](address), "127.0.0.1")
    for invalid in ["127.0.0.1\x00extra", "300.1.2.3", "::1"]:
        var failed = False
        try:
            _ = inet_pton[AF_INET](invalid)
        except:
            failed = True
        assert_true(failed)
    var failed = False
    try:
        _ = inet_ntop[AF_INET, 1](address)
    except error:
        assert_true(String(error).find("errno=") != -1)
        failed = True
    assert_true(failed)


def test_binary_transfer_and_eof() raises:
    var pair = Array[c_int, 2](fill=-1)
    assert_equal(
        external_call["socketpair", c_int](
            c_int(AF_UNIX),
            c_int(SOCK_STREAM | SOCK_CLOEXEC),
            c_int(0),
            Pointer(to=pair).unsafe_bitcast[c_int](),
        ),
        0,
    )
    try:
        var payload = List[UInt8](length=4, fill=0)
        payload[0] = 255
        payload[2] = 42
        var buffer = List[UInt8](length=4, fill=17)
        assert_equal(send(pair[0], payload.unsafe_ptr(), c_size_t(4), 0), 4)
        assert_equal(recv(pair[1], buffer.unsafe_ptr(), c_size_t(4), 0), 4)
        assert_equal(buffer, payload)
        shutdown(pair[0], SHUT_WR)
        assert_equal(recv(pair[1], buffer.unsafe_ptr(), c_size_t(4), 0), 0)
        var failed = False
        try:
            _ = send(pair[0], payload.unsafe_ptr(), c_size_t(4), 0)
        except error:
            assert_equal(String(error), String("send: errno=", EPIPE))
            failed = True
        assert_true(failed)
    finally:
        close(pair[0])
        close(pair[1])


def test_nonblocking_error() raises:
    var fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
    try:
        var buffer = List[UInt8](length=1, fill=0)
        var failed = False
        try:
            _ = recv(fd, buffer.unsafe_ptr(), c_size_t(1), 0)
        except error:
            assert_equal(String(error), String("recv: errno=", EAGAIN))
            failed = True
        assert_true(failed)
    finally:
        close(fd)


def local_address(fd: c_int) raises -> sockaddr_in:
    var address = sockaddr_in(AF_INET, 0, 0)
    var length = socklen_t(size_of[sockaddr_in]())
    getsockname(
        fd,
        Pointer(to=address).unsafe_bitcast[sockaddr](),
        Pointer(to=length),
    )
    assert_equal(length, socklen_t(size_of[sockaddr_in]()))
    return address^


def test_tcp_addresses() raises:
    var server = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
    try:
        var address = sockaddr_in(AF_INET, 0, inet_pton[AF_INET]("127.0.0.1"))
        bind(server, address)
        listen(server, 1)
        var bound = local_address(server)
        assert_true(ntohs(bound.sin_port) > 0)
        var client = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
        try:
            connect(client, bound)
            var accepted = accept(server)
            try:
                var client_address = local_address(client)
                var peer = getpeername(accepted)
                assert_equal(peer.sin_family, AF_INET)
                assert_equal(peer.sin_port, client_address.sin_port)
                assert_equal(
                    peer.sin_addr.s_addr, client_address.sin_addr.s_addr
                )
            finally:
                close(accepted)
        finally:
            close(client)
    finally:
        close(server)


def test_datagrams() raises:
    var receiver = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)
    try:
        var address = sockaddr_in(AF_INET, 0, inet_pton[AF_INET]("127.0.0.1"))
        bind(receiver, address)
        var bound = local_address(receiver)
        var sender = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)
        try:
            var destination = Pointer(to=bound).unsafe_bitcast[sockaddr]()
            var payload = List[UInt8](length=4, fill=0)
            payload[1] = 255
            payload[2] = 42
            var buffer = List[UInt8](length=4, fill=17)
            var source = sockaddr()
            var source_ptr = Pointer(to=source)
            assert_equal(
                sendto(
                    sender, payload.unsafe_ptr(), c_size_t(4), 0, destination
                ),
                4,
            )
            assert_equal(
                recvfrom(
                    receiver, buffer.unsafe_ptr(), c_size_t(4), 0, source_ptr
                ),
                4,
            )
            assert_equal(buffer, payload)
            assert_equal(source.sa_family, AF_INET)
            assert_equal(
                sendto(
                    sender, payload.unsafe_ptr(), c_size_t(0), 0, destination
                ),
                0,
            )
            assert_equal(
                recvfrom(
                    receiver, buffer.unsafe_ptr(), c_size_t(4), 0, source_ptr
                ),
                0,
            )
        finally:
            close(sender)
    finally:
        close(receiver)


def worker_errno(context: ThreadContext) abi("C") -> ThreadContext:
    _ = _socket(AF_INET, -1, 0)
    context.value()[] = UInt8(get_errno() == EINVAL)
    return context


def test_thread_local_errno() raises:
    assert_equal(_close(-1), -1)
    assert_equal(get_errno(), EBADF)
    var result = UInt8(0)
    var thread = Thread(
        worker_errno,
        Pointer(to=result).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    _ = thread.join()
    assert_equal(result, 1)
    assert_equal(get_errno(), EBADF)
    assert_false(thread.joinable())


def test_layouts_and_invalid_descriptor() raises:
    assert_equal(size_of[sockaddr](), 16)
    assert_equal(size_of[sockaddr_in](), 16)
    assert_equal(size_of[sockaddr_in6](), 28)
    assert_equal(size_of[addrinfo](), 48)
    var failed = False
    try:
        _ = getsockopt(-1, SOL_SOCKET, SO_TYPE)
    except error:
        assert_equal(String(error), String("getsockopt: errno=", EBADF))
        failed = True
    assert_true(failed)


def main() raises:
    var tests: List[Tuple[String, def() raises thin -> None]] = [
        ("test_integer_options", test_integer_options),
        ("test_ipv4_conversion", test_ipv4_conversion),
        ("test_binary_transfer_and_eof", test_binary_transfer_and_eof),
        ("test_nonblocking_error", test_nonblocking_error),
        ("test_tcp_addresses", test_tcp_addresses),
        ("test_datagrams", test_datagrams),
        ("test_thread_local_errno", test_thread_local_errno),
        (
            "test_layouts_and_invalid_descriptor",
            test_layouts_and_invalid_descriptor,
        ),
    ]
    var arguments = argv()
    var selected = arguments[1] if len(arguments) > 1 else String("all")
    var matched = False
    for test in tests:
        if selected == "all" or selected == test[0]:
            test[1]()
            print("ok", test[0])
            matched = True
    if not matched:
        raise Error("Unknown libc test: ", selected)
