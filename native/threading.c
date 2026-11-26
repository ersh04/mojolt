#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "threading.h"

#include <pthread.h>
#include <sched.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>

struct MojoltThread {
    pthread_t handle;
};

// region Thread Management

/// @brief Creates a new MojoltThread and starts it with the given start routine and argument.
/// @returns 0 on success, or an error code on failure.
int mojolt_thread_create(
    MojoltThread **thread,
    void *(*start_routine)(void *),
    void *arg
) {
    // Validate input arguments
    if (!thread || *thread || !start_routine)
        return EINVAL;

    // Allocate the thread handle
    *thread = malloc(sizeof(MojoltThread));

    if (!*thread)
        return ENOMEM;

    // Create the native thread.
    int result = pthread_create(
        &(*thread)->handle, NULL, start_routine, arg
    );

    // Release resources if thread creation fails
    if (result != 0) {
        free(*thread);
        *thread = NULL;
    }

    return result;
}

/// @brief Joins the specified MojoltThread, blocking until it terminates.
/// @returns 0 on success, or an error code on failure.
int mojolt_thread_join_result(MojoltThread **thread, void **value) {
    // Validate the thread handle.
    if (!thread || !*thread)
        return EINVAL;

    // Wait for the thread to terminate.
    int result = pthread_join((*thread)->handle, value);

    // Release the thread handle after a successful join
    if (result == 0) {
        free(*thread);
        *thread = NULL;
    }

    return result;
}

/// @brief Detaches the specified MojoltThread, allowing it to run independently.
/// @returns 0 on success, or an error code on failure.
int mojolt_thread_detach(MojoltThread **thread) {
    if (!thread || !*thread)
        return EINVAL;

    int result = pthread_detach((*thread)->handle);
    if (result == 0) {
        free(*thread);
        *thread = NULL;
    }
    return result;
}

/** @brief Join without retaining the entry point result. */
int mojolt_thread_join(MojoltThread **thread) {
    return mojolt_thread_join_result(thread, NULL);
}

int mojolt_thread_is_current(const MojoltThread *thread) {
    return thread ? !!pthread_equal(pthread_self(), thread->handle) : -EINVAL;
}

/* Grow until the kernel accepts the mask; the caller releases it with CPU_FREE. */
static int current_mask(cpu_set_t **out, size_t *size, int *bits) {
    int capacity = 128;
    for (;;) {
        cpu_set_t *mask = CPU_ALLOC(capacity);
        if (!mask) return ENOMEM;
        size_t bytes = CPU_ALLOC_SIZE(capacity);
        CPU_ZERO_S(bytes, mask);
        int status = pthread_getaffinity_np(pthread_self(), bytes, mask);
        if (!status) {
            *out = mask; *size = bytes; *bits = capacity;
            return 0;
        }
        CPU_FREE(mask);
        if (status != EINVAL) return status;
        if (capacity > INT_MAX / 2) return EOVERFLOW;
        capacity *= 2;
    }
}

/* Build an owned dynamic mask, apply it, and release it on every result. */
static int set_affinity(pthread_t thread, const int *ids, int count) {
    if (!ids || count <= 0) return EINVAL;
    int highest = 0;
    for (int i = 0; i < count; ++i) {
        if (ids[i] < 0 || ids[i] == INT_MAX) return EINVAL;
        if (ids[i] > highest) highest = ids[i];
    }
    cpu_set_t *mask = CPU_ALLOC(highest + 1);
    if (!mask) return ENOMEM;
    size_t bytes = CPU_ALLOC_SIZE(highest + 1);
    CPU_ZERO_S(bytes, mask);
    for (int i = 0; i < count; ++i) CPU_SET_S(ids[i], bytes, mask);
    int status = pthread_setaffinity_np(thread, bytes, mask);
    CPU_FREE(mask);
    return status;
}

int mojolt_thread_set_current_affinity(int cpu) {
    return set_affinity(pthread_self(), &cpu, 1);
}

int mojolt_thread_set_current_cpu_ids(const int *ids, int count) {
    return set_affinity(pthread_self(), ids, count);
}

int mojolt_thread_set_affinity(const MojoltThread *thread, const int *ids, int count) {
    return thread ? set_affinity(thread->handle, ids, count) : EINVAL;
}

int mojolt_thread_set_current_name(const char *name) {
    if (!name) return EINVAL;
    return pthread_setname_np(pthread_self(), name);
}

int mojolt_thread_get_online_cpus(void) {
    errno = 0;
    long count = sysconf(_SC_NPROCESSORS_ONLN);
    if (count <= 0) return -(errno ? errno : EIO);
    return count > INT_MAX ? -EOVERFLOW : (int)count;
}

int mojolt_thread_get_available_cpus(void) {
    cpu_set_t *mask; size_t bytes; int bits;
    int status = current_mask(&mask, &bytes, &bits);
    if (status) return -status;
    int count = CPU_COUNT_S(bytes, mask);
    CPU_FREE(mask);
    return count;
}

int mojolt_thread_get_available_cpu_ids(int *cpu_ids, int max_cpus) {
    if (!cpu_ids || max_cpus <= 0) return -EINVAL;
    cpu_set_t *mask; size_t bytes; int bits;
    int status = current_mask(&mask, &bytes, &bits);
    if (status) return -status;
    if (CPU_COUNT_S(bytes, mask) > max_cpus) {
        CPU_FREE(mask);
        return -ENOSPC;
    }
    int count = 0;
    for (int i = 0; i < bits; ++i)
        if (CPU_ISSET_S(i, bytes, mask)) cpu_ids[count++] = i;
    CPU_FREE(mask);
    return count;
}
