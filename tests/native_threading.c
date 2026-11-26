#define _GNU_SOURCE
#include "threading.h"
#include "control.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <unistd.h>

struct Context { MojoltMutex *mutex; int *counter; int fd; };

static void *increment(void *raw) {
    struct Context *context = raw;
    for (int i = 0; i < 1000; ++i) {
        assert(mojolt_mutex_lock(context->mutex) == 0);
        ++*context->counter;
        assert(mojolt_mutex_unlock(context->mutex) == 0);
        assert(mojolt_event_signal(context->fd) == 0);
    }
    return raw;
}

/* The borrowed context is read before notification and never accessed again. */
static void *notify_detached(void *raw) {
    int fd = *(int *)raw;
    assert(mojolt_event_signal(fd) == 0);
    return NULL;
}

int main(void) {
    MojoltThread *thread = NULL;
    assert(mojolt_thread_create(NULL, increment, NULL) == EINVAL);
    assert(mojolt_thread_create(&thread, NULL, NULL) == EINVAL);
    assert(mojolt_thread_join(&thread) == EINVAL);
    assert(mojolt_thread_detach(&thread) == EINVAL);
    assert(mojolt_thread_is_current(NULL) == -EINVAL);
    assert(mojolt_thread_set_current_affinity(-1) == EINVAL);
    assert(mojolt_thread_set_current_affinity(INT32_MAX) == EINVAL);
    assert(mojolt_thread_get_available_cpu_ids(NULL, 0) == -EINVAL);
    assert(mojolt_thread_set_current_name(NULL) == EINVAL);
    assert(mojolt_thread_set_current_name("mojolt-native-test-too-long") == ERANGE);
    assert(mojolt_thread_set_current_name("mojolt-test") == 0);

    int count = mojolt_thread_get_available_cpus();
    assert(count > 0 && mojolt_thread_get_online_cpus() > 0);
    int *ids = calloc((size_t)count, sizeof *ids);
    assert(ids && mojolt_thread_get_available_cpu_ids(ids, count) == count);
    if (count > 1) assert(mojolt_thread_get_available_cpu_ids(ids, 1) == -ENOSPC);
    assert(mojolt_thread_set_current_affinity(ids[0]) == 0);
    assert(mojolt_thread_get_available_cpus() == 1);
    assert(mojolt_thread_set_current_cpu_ids(ids, count) == 0);
    free(ids);

    MojoltMutex *mutex = NULL;
    assert(mojolt_mutex_create(NULL) == EINVAL);
    assert(mojolt_mutex_create(&mutex) == 0);
    assert(mojolt_mutex_create(&mutex) == EINVAL);
    assert(mojolt_mutex_lock(mutex) == 0);
    assert(mojolt_mutex_try_lock(mutex) == EBUSY);
    assert(mojolt_mutex_unlock(mutex) == 0);
    assert(mojolt_mutex_try_lock(mutex) == 0);
    assert(mojolt_mutex_unlock(mutex) == 0);
    int fd = mojolt_event_create();
    assert(fd >= 0);
    assert(mojolt_thread_create(&thread, notify_detached, &fd) == 0);
    assert(mojolt_thread_detach(&thread) == 0 && !thread);
    struct pollfd detached_event = {fd, POLLIN, 0};
    assert(poll(&detached_event, 1, 5000) == 1);
    assert(mojolt_event_drain(fd) == 0);
    uint64_t saturated = UINT64_MAX - 1;
    assert(write(fd, &saturated, sizeof saturated) == (ssize_t)sizeof saturated);
    assert(mojolt_event_signal(fd) == 0);
    assert(mojolt_event_drain(fd) == 0);
    int counter = 0;
    struct Context context = {mutex, &counter, fd};
    for (int round = 0; round < 8; ++round) {
        MojoltThread *threads[8] = {NULL};
        for (int i = 0; i < 8; ++i)
            assert(mojolt_thread_create(&threads[i], increment, &context) == 0);
        struct pollfd event = {fd, POLLIN, 0};
        assert(poll(&event, 1, 5000) == 1);
        for (int i = 0; i < 8; ++i) {
            void *result = NULL;
            assert(mojolt_thread_join_result(&threads[i], &result) == 0);
            assert(!threads[i] && result == &context);
        }
        assert(mojolt_event_drain(fd) == 0);
        assert(mojolt_event_drain(fd) == 0);
    }
    assert(counter == 64000);
    close(fd);
    assert(mojolt_event_signal(-1) == EBADF);
    assert(mojolt_event_drain(-1) == EBADF);
    assert(mojolt_mutex_destroy(&mutex) == 0 && !mutex);
    assert(mojolt_mutex_destroy(&mutex) == EINVAL);
    return 0;
}
