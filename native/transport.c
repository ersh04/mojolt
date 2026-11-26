#define _GNU_SOURCE
#include <sys/epoll.h>
#include <sys/socket.h>
#include <netdb.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

/* Keep platform-specific ABI structures on the C side of the boundary. */
/* All network deadlines use a monotonic clock, unaffected by wall-clock edits. */
int64_t ws_now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return 0;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
int ws_errno(void) { return errno; }
int ws_close(int fd) { return close(fd); }
/* Fixed English names avoid locale-dependent HTTP Date output. Capacity includes NUL. */
int ws_http_date(char *out, int capacity) {
    static const char *days[] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
    static const char *months[] = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
    time_t now = time(NULL);
    struct tm value;
    if (!gmtime_r(&now, &value) || capacity < 30) return 0;
    return snprintf(out, (size_t)capacity, "%s, %02d %s %04d %02d:%02d:%02d GMT",
        days[value.tm_wday], value.tm_mday, months[value.tm_mon], value.tm_year+1900,
        value.tm_hour, value.tm_min, value.tm_sec);
}
/* -2 preserves EINTR as a retryable result; the caller recalculates its deadline. */
int ws_poll(int fd, int writing, int timeout_ms) {
    struct pollfd event = {.fd=fd, .events=writing ? POLLOUT : POLLIN};
    int result = poll(&event, 1, timeout_ms);
    return result < 0 && errno == EINTR ? -2 : result;
}
/* getaddrinfo selects IPv4 or IPv6 without Mojo reproducing either sockaddr ABI.
 * DNS is synchronous; the TCP deadline begins after resolution. Each failed
 * candidate is closed before trying another, and the address list is always freed.
 */
static int ws_address(const char *host, int port, int listener, int timeout_ms, int reuse_port, int backlog) {
    struct addrinfo hints = {0}, *addresses = NULL;
    char service[6];
    snprintf(service, sizeof service, "%d", port);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = listener ? AI_PASSIVE : 0;
    int status = getaddrinfo(host[0] ? host : NULL, service, &hints, &addresses);
    if (status) { errno = EHOSTUNREACH; return -1; }
    int result = -1, saved_error = EHOSTUNREACH;
    int64_t deadline = ws_now_ms() + timeout_ms;
    for (struct addrinfo *p = addresses; p; p = p->ai_next) {
        /* Set flags atomically so accepted/created descriptors never leak across exec. */
        int fd = socket(p->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, p->ai_protocol);
        if (fd < 0) { saved_error=errno; continue; }
        if (listener) {
            int yes = 1;
            if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) ||
                (reuse_port && setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof yes)) ||
                bind(fd, p->ai_addr, p->ai_addrlen) || listen(fd, backlog)) {
                saved_error=errno; close(fd); continue;
            }
            result=fd; break;
        }
        int connected = connect(fd, p->ai_addr, p->ai_addrlen);
        if (connected && errno == EINPROGRESS) {
            /* Writable readiness alone does not prove connect succeeded: inspect SO_ERROR. */
            int ready;
            do {
                int64_t left = deadline-ws_now_ms();
                ready = ws_poll(fd, 1, left > 0 ? (int)left : 0);
            } while (ready == -2);
            int error = ETIMEDOUT;
            socklen_t length=sizeof error;
            if (ready > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)) error=errno;
            connected=error ? -1 : 0;
            errno=error;
        }
        if (!connected) { result=fd; break; }
        saved_error=errno; close(fd);
        if (ws_now_ms() >= deadline) break;
    }
    freeaddrinfo(addresses);
    if (result < 0) errno=saved_error;
    return result;
}
int ws_listen(const char *host, int port) { return ws_address(host, port, 1, 0, 0, 128); }
/* Each reuseport listener sets options before bind and owns its accept queue. */
int ws_listen_config(const char *host, int port, int reuse_port, int backlog) {
    if (port < 0 || port > 65535 || backlog < 1) { errno=EINVAL; return -1; }
    return ws_address(host, port, 1, 0, reuse_port, backlog);
}
int ws_connect(const char *host, int port, int timeout_ms) { return ws_address(host, port, 0, timeout_ms, 0, 128); }
int ws_port(int fd) {
    struct sockaddr_storage address;
    socklen_t length=sizeof address;
    char service[6];
    if (getsockname(fd, (struct sockaddr *)&address, &length) ||
        getnameinfo((struct sockaddr *)&address, length, NULL, 0, service, sizeof service, NI_NUMERICSERV)) return -1;
    int port=0;
    for (const char *p=service; *p; ++p) port=port*10+*p-'0';
    return port;
}
/* -2 means retry after readiness, while -1 preserves an actual accept failure. */
int ws_accept(int fd) {
    int result;
    do { result=accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC); } while (result < 0 && errno == EINTR);
    if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNABORTED)) return -2;
    return result;
}
/* A zero-byte recv is EOF; EAGAIN must remain distinguishable from it. */
int64_t ws_recv(int fd, void *buffer, int64_t capacity) {
    ssize_t result;
    do { result=recv(fd, buffer, (size_t)capacity, 0); } while (result < 0 && errno == EINTR);
    return result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : result;
}
/* Suppress SIGPIPE per send so a disconnected peer cannot terminate the process. */
int64_t ws_send(int fd, const void *buffer, int64_t size) {
    ssize_t result;
    do { result=send(fd, buffer, (size_t)size, MSG_NOSIGNAL); } while (result < 0 && errno == EINTR);
    return result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : result;
}
int ws_epoll_create(void) { return epoll_create1(EPOLL_CLOEXEC); }
/* Level-triggered registration: enable writable events only while output is queued.
 * Use a generation-like connection ID, not a potentially recycled descriptor.
 */
int ws_epoll_watch(int epfd, int operation, int fd, uint64_t id, int writing) {
    struct epoll_event event = {.events=EPOLLIN | EPOLLRDHUP | (writing ? EPOLLOUT : 0), .data.u64=id};
    return epoll_ctl(epfd, operation, fd, operation == EPOLL_CTL_DEL ? NULL : &event);
}
/* Translate packed epoll_event structures into simple scalar arrays for Mojo.
 * The fixed stack array bounds allocation even during a large event burst.
 */
int ws_epoll_wait(int epfd, uint64_t *ids, uint32_t *flags, int capacity, int timeout_ms) {
    struct epoll_event events[128];
    if (capacity < 1 || capacity > 128) { errno=EINVAL; return -1; }
    int count=epoll_wait(epfd, events, capacity, timeout_ms);
    if (count < 0) return errno == EINTR ? -2 : -1;
    for (int i=0; i<count; ++i) { ids[i]=events[i].data.u64; flags[i]=events[i].events; }
    return count;
}
