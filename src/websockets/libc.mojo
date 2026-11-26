"""Linux socket ABI bindings for 64-bit x86_64 and AArch64 targets.

Raw integer wrappers return libc results and leave errno available to the
caller. Checked wrappers raise on failure and preserve partial transfers,
zero-length datagrams, and EOF. Callers own pointer lifetimes and buffers.
"""

from std.collections import Array
from std.ffi import (
    c_char,
    c_uchar,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_short,
    c_ushort,
    c_float,
    c_double,
    external_call,
)
from std.memory import OptionalPointer, Pointer
from std.sys import CompilationTarget, size_of
from mojolt.websockets.aliases import CPointer

comptime c_void = UInt8
comptime c_schar = Int8
comptime c_size_t = UInt
comptime c_ssize_t = Int
comptime ptrdiff_t = Int
comptime intptr_t = Int
comptime uintptr_t = UInt
comptime char_UnsafePointer = CPointer[c_char]
comptime sa_family_t = c_ushort
comptime socklen_t = c_uint
comptime in_addr_t = c_uint
comptime in_port_t = c_ushort

# Linux uses the same error number for EWOULDBLOCK and EAGAIN.
comptime SUCCESS = 0
comptime EPERM = 1
comptime ENOENT = 2
comptime ESRCH = 3
comptime EINTR = 4
comptime EIO = 5
comptime ENXIO = 6
comptime E2BIG = 7
comptime ENOEXEC = 8
comptime EBADF = 9
comptime ECHILD = 10
comptime EAGAIN = 11
comptime ENOMEM = 12
comptime EACCES = 13
comptime EFAULT = 14
comptime ENOTBLK = 15
comptime EBUSY = 16
comptime EEXIST = 17
comptime EXDEV = 18
comptime ENODEV = 19
comptime ENOTDIR = 20
comptime EISDIR = 21
comptime EINVAL = 22
comptime ENFILE = 23
comptime EMFILE = 24
comptime ENOTTY = 25
comptime ETXTBSY = 26
comptime EFBIG = 27
comptime ENOSPC = 28
comptime ESPIPE = 29
comptime EROFS = 30
comptime EMLINK = 31
comptime EPIPE = 32
comptime EDOM = 33
comptime ERANGE = 34
comptime EWOULDBLOCK = EAGAIN
comptime ENAMETOOLONG = 36
comptime ENOMSG = 42
comptime ELOOP = 40
comptime EPROTO = 71
comptime ENOTSOCK = 88
comptime EDESTADDRREQ = 89
comptime EMSGSIZE = 90
comptime ENOPROTOOPT = 92
comptime EPROTONOSUPPORT = 93
comptime EOPNOTSUPP = 95
comptime EAFNOSUPPORT = 97
comptime EADDRINUSE = 98
comptime EADDRNOTAVAIL = 99
comptime ENETDOWN = 100
comptime ENETUNREACH = 101
comptime ECONNABORTED = 103
comptime ECONNRESET = 104
comptime ENOBUFS = 105
comptime EISCONN = 106
comptime ENOTCONN = 107
comptime ETIMEDOUT = 110
comptime ECONNREFUSED = 111
comptime EHOSTUNREACH = 113
comptime EALREADY = 114
comptime EINPROGRESS = 115
comptime EDQUOT = 122

# Address families and socket options use Linux ABI values.
comptime AF_UNSPEC = 0
comptime AF_UNIX = 1
comptime AF_LOCAL = AF_UNIX
comptime AF_INET = 2
comptime AF_IPX = 4
comptime AF_APPLETALK = 5
comptime AF_INET6 = 10
comptime AF_DECnet = 12
comptime AF_KEY = 15
comptime AF_NETLINK = 16
comptime AF_ROUTE = AF_NETLINK
comptime AF_PACKET = 17
comptime AF_SNA = 22
comptime AF_MPLS = 28
comptime AF_BLUETOOTH = 31
comptime PF_UNSPEC = AF_UNSPEC
comptime PF_UNIX = AF_UNIX
comptime PF_LOCAL = AF_LOCAL
comptime PF_INET = AF_INET
comptime PF_IPX = AF_IPX
comptime PF_APPLETALK = AF_APPLETALK
comptime PF_INET6 = AF_INET6
comptime PF_DECnet = AF_DECnet
comptime PF_KEY = AF_KEY
comptime PF_NETLINK = AF_NETLINK
comptime PF_ROUTE = AF_ROUTE
comptime PF_PACKET = AF_PACKET
comptime PF_SNA = AF_SNA
comptime PF_MPLS = AF_MPLS
comptime PF_BLUETOOTH = AF_BLUETOOTH

comptime O_ACCMODE = 3
comptime O_NONBLOCK = 2048
comptime O_CLOEXEC = 524288
comptime SOCK_STREAM = 1
comptime SOCK_DGRAM = 2
comptime SOCK_RAW = 3
comptime SOCK_RDM = 4
comptime SOCK_SEQPACKET = 5
comptime SOCK_DCCP = 6
comptime SOCK_PACKET = 10
comptime SOCK_NONBLOCK = O_NONBLOCK
comptime SOCK_CLOEXEC = O_CLOEXEC
comptime SOL_SOCKET = 1
comptime SO_DEBUG = 1
comptime SO_REUSEADDR = 2
comptime SO_TYPE = 3
comptime SO_ERROR = 4
comptime SO_DONTROUTE = 5
comptime SO_BROADCAST = 6
comptime SO_SNDBUF = 7
comptime SO_RCVBUF = 8
comptime SO_KEEPALIVE = 9
comptime SO_OOBINLINE = 10
comptime SO_LINGER = 13
comptime SO_REUSEPORT = 15
comptime SO_PEERCRED = 17
comptime SO_RCVLOWAT = 18
comptime SO_SNDLOWAT = 19
comptime SO_RCVTIMEO = 20
comptime SO_SNDTIMEO = 21
comptime SO_BINDTODEVICE = 25
comptime SO_TIMESTAMP = 29
comptime SO_ACCEPTCONN = 30
comptime SO_PROTOCOL = 38
comptime SO_DOMAIN = 39
comptime SHUT_RD = 0
comptime SHUT_WR = 1
comptime SHUT_RDWR = 2
comptime MSG_PEEK = 2
comptime MSG_DONTWAIT = 64
comptime MSG_WAITALL = 256
comptime MSG_NOSIGNAL = 16384
comptime AI_PASSIVE = 1
comptime AI_CANONNAME = 2
comptime AI_NUMERICHOST = 4
comptime AI_V4MAPPED = 8
comptime AI_ALL = 16
comptime AI_ADDRCONFIG = 32
comptime AI_IDN = 64
comptime INET_ADDRSTRLEN = 16
comptime INET6_ADDRSTRLEN = 46
comptime IPPROTO_IPV6 = 41
comptime IPV6_V6ONLY = 26
comptime GRND_NONBLOCK: c_uint = 1


@fieldwise_init
struct in_addr(Copyable, Movable):
    var s_addr: in_addr_t


@fieldwise_init
struct in6_addr(Copyable, Movable):
    var s6_addr: Array[c_char, 16]


struct sockaddr(Copyable, Movable):
    var sa_family: sa_family_t
    var sa_data: Array[c_char, 14]

    def __init__(
        out self,
        family: sa_family_t = 0,
        data: Array[c_char, 14] = Array[c_char, 14](fill=0),
    ):
        self.sa_family = family
        self.sa_data = data.copy()


struct sockaddr_in(Copyable, Movable):
    var sin_family: sa_family_t
    var sin_port: in_port_t
    var sin_addr: in_addr
    var sin_zero: Array[c_char, 8]

    def __init__(
        out self, address_family: Int, port: UInt16, binary_ip: UInt32
    ):
        self.sin_family = sa_family_t(address_family)
        self.sin_port = htons(port)
        self.sin_addr = in_addr(binary_ip)
        self.sin_zero = Array[c_char, 8](fill=0)


@fieldwise_init
struct sockaddr_in6(Copyable, Movable):
    var sin6_family: sa_family_t
    var sin6_port: in_port_t
    var sin6_flowinfo: c_uint
    var sin6_addr: in6_addr
    var sin6_scope_id: c_uint


@fieldwise_init
struct addrinfo(Copyable, Movable):
    var ai_flags: c_int
    var ai_family: c_int
    var ai_socktype: c_int
    var ai_protocol: c_int
    var ai_addrlen: socklen_t
    var ai_addr: OptionalPointer[sockaddr, MutUntrackedOrigin]
    var ai_canonname: OptionalPointer[c_char, MutUntrackedOrigin]
    var ai_next: OptionalPointer[c_void, MutUntrackedOrigin]

    def __init__(out self):
        self.ai_flags = 0
        self.ai_family = 0
        self.ai_socktype = 0
        self.ai_protocol = 0
        self.ai_addrlen = 0
        self.ai_addr = None
        self.ai_canonname = None
        self.ai_next = None


def get_errno() -> c_int:
    """Return errno for the calling thread, including pthread-created threads.
    """
    comptime assert CompilationTarget.is_linux(), "libc.mojo requires Linux"
    comptime assert size_of[Int]() == 8, "libc.mojo requires a 64-bit target"
    return external_call["__errno_location", CPointer[c_int]]()[]


def _check_error[operation: StaticString](failed: Bool) raises:
    if failed:
        var status = get_errno()
        raise Error(operation, ": errno=", status)


def htonl(hostlong: c_uint) -> c_uint:
    return external_call["htonl", c_uint](hostlong)


def htons(hostshort: c_ushort) -> c_ushort:
    return external_call["htons", c_ushort](hostshort)


def ntohl(netlong: c_uint) -> c_uint:
    return external_call["ntohl", c_uint](netlong)


def ntohs(netshort: c_ushort) -> c_ushort:
    return external_call["ntohs", c_ushort](netshort)


def _inet_ntop(
    af: c_int,
    src: Pointer[mut=False, c_void, ImmUntrackedOrigin],
    dst: CPointer[c_char],
    size: socklen_t,
) raises -> CPointer[c_char]:
    var result = external_call[
        "inet_ntop", OptionalPointer[c_char, MutUntrackedOrigin]
    ](af, src, dst, size)
    _check_error["inet_ntop"](not result)
    return result.value()


def inet_ntop[
    address_family: Int, address_length: Int
](var ip_address: UInt32) raises -> String:
    """Format an IPv4 address stored in network byte order."""
    comptime assert address_length > 0, "Address buffer must not be empty"
    comptime if address_family != AF_INET:
        raise Error("IPv4 wrapper requires AF_INET; use _inet_ntop for IPv6")
    var buffer = List[c_char](length=address_length, fill=0)
    var result = external_call[
        "inet_ntop", OptionalPointer[c_char, origin_of(buffer)]
    ](
        c_int(address_family),
        Pointer(to=ip_address),
        buffer.unsafe_ptr(),
        socklen_t(address_length),
    )
    _check_error["inet_ntop"](not result)
    return String(unsafe_from_utf8_ptr=result.value())


def _inet_pton(
    af: c_int, src: CPointer[c_char], dst: CPointer[c_void]
) -> c_int:
    return external_call["inet_pton", c_int](af, src, dst)


def inet_pton[address_family: Int](var src: String) raises -> c_uint:
    """Parse an IPv4 address, rejecting embedded null bytes."""
    comptime if address_family != AF_INET:
        raise Error("IPv4 wrapper requires AF_INET; use _inet_pton for IPv6")
    if src.find("\x00") != -1:
        raise Error("IPv4 address contains a null byte")
    var address = c_uint(0)
    var result = external_call["inet_pton", c_int](
        c_int(address_family), src.as_c_string_span(), Pointer(to=address)
    )
    _check_error["inet_pton"](result < 0)
    if result == 0:
        raise Error("Invalid IPv4 address: ", src)
    return address


def _socket(domain: c_int, type: c_int, protocol: c_int) -> c_int:
    return external_call["socket", c_int](domain, type, protocol)


def socket(domain: c_int, type: c_int, protocol: c_int) raises -> c_int:
    var fd = _socket(domain, type, protocol)
    _check_error["socket"](fd < 0)
    return fd


def _setsockopt[
    origin: Origin
](
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: Pointer[c_void, origin],
    option_len: socklen_t,
) -> c_int:
    return external_call["setsockopt", c_int](
        socket, level, option_name, option_value, option_len
    )


def setsockopt(
    socket: c_int,
    level: c_int,
    option_name: c_int,
    var option_value: c_int,
) raises:
    """Set an integer socket option using sizeof(int) bytes."""
    _check_error["setsockopt"](
        _setsockopt(
            socket,
            level,
            option_name,
            Pointer(to=option_value).unsafe_bitcast[c_void](),
            socklen_t(size_of[c_int]()),
        )
        != 0
    )


def _getsockopt[
    len_origin: Origin
](
    socket: c_int,
    level: c_int,
    option_name: c_int,
    option_value: CPointer[c_void],
    option_len: Pointer[socklen_t, len_origin],
) -> c_int:
    return external_call["getsockopt", c_int](
        socket, level, option_name, option_value, option_len
    )


def getsockopt(socket: c_int, level: c_int, option_name: c_int) raises -> Int:
    """Read an integer socket option into an initialized buffer."""
    var value = c_int(0)
    var length = socklen_t(size_of[c_int]())
    _check_error["getsockopt"](
        external_call["getsockopt", c_int](
            socket, level, option_name, Pointer(to=value), Pointer(to=length)
        )
        != 0
    )
    if length != socklen_t(size_of[c_int]()):
        raise Error("getsockopt: option does not contain an int")
    return Int(value)


def _getsockname[
    origin: Origin
](
    socket: c_int,
    address: Pointer[sockaddr, _],
    address_len: Pointer[socklen_t, origin],
) -> c_int:
    return external_call["getsockname", c_int](socket, address, address_len)


def getsockname[
    origin: Origin
](
    socket: c_int,
    address: Pointer[sockaddr, _],
    address_len: Pointer[socklen_t, origin],
) raises:
    _check_error["getsockname"](_getsockname(socket, address, address_len) != 0)


def _getpeername[
    origin: Origin
](
    sockfd: c_int,
    addr: Pointer[sockaddr, _],
    address_len: Pointer[socklen_t, origin],
) -> c_int:
    return external_call["getpeername", c_int](sockfd, addr, address_len)


def getpeername(file_descriptor: c_int) raises -> sockaddr_in:
    var address = sockaddr_in(AF_INET, 0, 0)
    var length = socklen_t(size_of[sockaddr_in]())
    _check_error["getpeername"](
        external_call["getpeername", c_int](
            file_descriptor, Pointer(to=address), Pointer(to=length)
        )
        != 0
    )
    if (
        length != socklen_t(size_of[sockaddr_in]())
        or address.sin_family != AF_INET
    ):
        raise Error("getpeername: IPv4 address required")
    return address^


def _bind[
    origin: MutOrigin
](
    socket: c_int,
    address: Pointer[sockaddr_in, origin],
    address_len: socklen_t,
) -> c_int:
    return external_call["bind", c_int](socket, address, address_len)


def bind(socket: c_int, mut address: sockaddr_in) raises:
    _check_error["bind"](
        _bind(socket, Pointer(to=address), socklen_t(size_of[sockaddr_in]()))
        != 0
    )


def _listen(socket: c_int, backlog: c_int) -> c_int:
    return external_call["listen", c_int](socket, backlog)


def listen(socket: c_int, backlog: c_int) raises:
    _check_error["listen"](_listen(socket, backlog) != 0)


def _accept[
    address_origin: MutOrigin, len_origin: Origin
](
    socket: c_int,
    address: Pointer[sockaddr, address_origin],
    address_len: Pointer[socklen_t, len_origin],
) -> c_int:
    return external_call["accept", c_int](socket, address, address_len)


def accept(socket: c_int) raises -> c_int:
    var address = sockaddr()
    var length = socklen_t(size_of[sockaddr]())
    while True:
        var fd = _accept(socket, Pointer(to=address), Pointer(to=length))
        if fd >= 0:
            return fd
        if get_errno() != EINTR:
            _check_error["accept"](True)
        length = socklen_t(size_of[sockaddr]())


def _connect[
    origin: Origin
](
    socket: c_int,
    address: Pointer[sockaddr_in, origin],
    address_len: socklen_t,
) -> c_int:
    return external_call["connect", c_int](socket, address, address_len)


def connect(socket: c_int, address: sockaddr_in) raises:
    _check_error["connect"](
        _connect(socket, Pointer(to=address), socklen_t(size_of[sockaddr_in]()))
        != 0
    )


def _recv(
    socket: c_int,
    buffer: Pointer[UInt8, _],
    length: c_size_t,
    flags: c_int,
) -> c_ssize_t:
    return external_call["recv", c_ssize_t](socket, buffer, length, flags)


def recv(
    socket: c_int,
    buffer: Pointer[UInt8, _],
    length: c_size_t,
    flags: c_int,
) raises -> c_ssize_t:
    while True:
        var received = _recv(socket, buffer, length, flags)
        if received >= 0:
            return received
        if get_errno() != EINTR:
            _check_error["recv"](True)


def _recvfrom[
    origin: Origin
](
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
    address: Pointer[sockaddr, _],
    address_len: Pointer[socklen_t, origin],
) -> c_ssize_t:
    return external_call["recvfrom", c_ssize_t](
        socket, buffer, length, flags, address, address_len
    )


def recvfrom(
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
    address: Pointer[sockaddr, _],
) raises -> c_size_t:
    """Receive a datagram using an IPv4-sized source address buffer."""
    while True:
        var address_length = socklen_t(size_of[sockaddr]())
        var received = _recvfrom(
            socket, buffer, length, flags, address, Pointer(to=address_length)
        )
        if received >= 0:
            return c_size_t(received)
        if get_errno() != EINTR:
            _check_error["recvfrom"](True)


def _send(
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
) -> c_ssize_t:
    return external_call["send", c_ssize_t](socket, buffer, length, flags)


def send(
    socket: c_int,
    buffer: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
) raises -> c_size_t:
    """Send up to length bytes while suppressing SIGPIPE."""
    while True:
        var sent = _send(socket, buffer, length, flags | MSG_NOSIGNAL)
        if sent >= 0:
            return c_size_t(sent)
        if get_errno() != EINTR:
            _check_error["send"](True)


def _sendto(
    socket: c_int,
    message: Pointer[mut=False, c_void, ImmUntrackedOrigin],
    length: c_size_t,
    flags: c_int,
    dest_addr: Pointer[sockaddr, _],
    dest_len: socklen_t,
) -> c_ssize_t:
    return external_call["sendto", c_ssize_t](
        socket, message, length, flags, dest_addr, dest_len
    )


def sendto(
    socket: c_int,
    message: Pointer[c_void, _],
    length: c_size_t,
    flags: c_int,
    dest_addr: Pointer[sockaddr, _],
) raises -> c_size_t:
    """Send an IPv4 datagram; use _sendto for other address layouts."""
    if dest_addr[].sa_family != AF_INET:
        raise Error("sendto: IPv4 address required")
    while True:
        var sent = external_call["sendto", c_ssize_t](
            socket,
            message,
            length,
            flags | MSG_NOSIGNAL,
            dest_addr,
            socklen_t(size_of[sockaddr_in]()),
        )
        if sent >= 0:
            return c_size_t(sent)
        if get_errno() != EINTR:
            _check_error["sendto"](True)


def _shutdown(socket: c_int, how: c_int) -> c_int:
    return external_call["shutdown", c_int](socket, how)


comptime ShutdownInvalidDescriptorError = "shutdown: invalid descriptor (EBADF)"
comptime ShutdownInvalidArgumentError = "shutdown: invalid argument (EINVAL)"
comptime ShutdownNotConnectedError = (
    "shutdown: socket is not connected (ENOTCONN)"
)
comptime ShutdownNotSocketError = (
    "shutdown: descriptor is not a socket (ENOTSOCK)"
)
comptime CloseInvalidDescriptorError = "close: invalid descriptor (EBADF)"
comptime CloseInterruptedError = "close: interrupted (EINTR)"
comptime CloseRWError = "close: I/O failure (EIO)"
comptime CloseOutOfSpaceError = "close: storage exhausted (ENOSPC or EDQUOT)"


def shutdown(socket: c_int, how: c_int) raises:
    if _shutdown(socket, how) != 0:
        var status = get_errno()
        if status == EBADF:
            raise Error(ShutdownInvalidDescriptorError)
        if status == EINVAL:
            raise Error(ShutdownInvalidArgumentError)
        if status == ENOTCONN:
            raise Error(ShutdownNotConnectedError)
        if status == ENOTSOCK:
            raise Error(ShutdownNotSocketError)
        raise Error("shutdown: errno=", status)


def dup(fd: c_int) -> c_int:
    """Return a duplicate descriptor or -1; the caller checks errno."""
    return external_call["dup", c_int](fd)


def gai_strerror(ecode: c_int) -> CPointer[c_char]:
    """Return a libc-owned string that must not be modified or freed."""
    return external_call["gai_strerror", CPointer[c_char]](ecode)


def _close(fildes: c_int) -> c_int:
    return external_call["close", c_int](fildes)


def close(file_descriptor: c_int) raises:
    # Linux releases the descriptor on EINTR, so close must not be retried.
    if _close(file_descriptor) != 0:
        var status = get_errno()
        if status == EBADF:
            raise Error(CloseInvalidDescriptorError)
        if status == EINTR:
            raise Error(CloseInterruptedError)
        if status == EIO:
            raise Error(CloseRWError)
        if status == ENOSPC or status == EDQUOT:
            raise Error(CloseOutOfSpaceError)
        raise Error("close: errno=", status)
