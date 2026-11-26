#define _GNU_SOURCE
#include "control.h"
#include <pthread.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>

struct MojoltMutex { pthread_mutex_t value; };

int mojolt_mutex_create(MojoltMutex **mutex) {
    if (!mutex || *mutex) return EINVAL;
    MojoltMutex *value = malloc(sizeof *value);
    if (!value) return ENOMEM;
    int status = pthread_mutex_init(&value->value, NULL);
    if (status) { free(value); return status; }
    *mutex = value;
    return 0;
}
int mojolt_mutex_destroy(MojoltMutex **mutex) {
    if (!mutex || !*mutex) return EINVAL;
    int status = pthread_mutex_destroy(&(*mutex)->value);
    if (!status) { free(*mutex); *mutex = NULL; }
    return status;
}
int mojolt_mutex_lock(MojoltMutex *mutex) {
    return mutex ? pthread_mutex_lock(&mutex->value) : EINVAL;
}
int mojolt_mutex_unlock(MojoltMutex *mutex) {
    return mutex ? pthread_mutex_unlock(&mutex->value) : EINVAL;
}
int mojolt_mutex_try_lock(MojoltMutex *mutex) {
    return mutex ? pthread_mutex_trylock(&mutex->value) : EINVAL;
}
int mojolt_event_create(void) {
    int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    return fd < 0 ? -errno : fd;
}
int mojolt_event_signal(int fd) {
    uint64_t value = 1;
    ssize_t count;
    do { count = write(fd, &value, sizeof value); } while (count < 0 && errno == EINTR);
    if (count == (ssize_t)sizeof value || (count < 0 && errno == EAGAIN)) return 0;
    return count < 0 ? errno : EIO;
}
int mojolt_event_drain(int fd) {
    uint64_t value;
    ssize_t count;
    do { count = read(fd, &value, sizeof value); } while (count < 0 && errno == EINTR);
    if (count == (ssize_t)sizeof value || (count < 0 && errno == EAGAIN)) return 0;
    return count < 0 ? errno : EIO;
}
