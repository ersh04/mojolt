#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "threading.h"

#include <pthread.h>
#include <sched.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h> // For sysconf and _SC_NPROCESSORS_ONLN
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
int mojolt_thread_join(MojoltThread **thread) {
    // Validate the thread handle.
    if (!thread || !*thread)
        return EINVAL;

    // Wait for the thread to terminate.
    int result = pthread_join((*thread)->handle, NULL);

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

/// @brief Pins the calling thread to a specific logical CPU.
/// @returns 0 on success, or an error code on failure.
int mojolt_thread_set_current_affinity(int cpu) {
    // Validate the logical CPU index.
    if (cpu < 0 || cpu >= CPU_SETSIZE)
        return EINVAL;

    // Initialize the CPU affinity mask
    cpu_set_t cpuset;

    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);

    // Apply the affinity mask to the calling thread
    return pthread_setaffinity_np(
        pthread_self(),
        sizeof(cpuset),
        &cpuset
    );
}

/// @brief Returns the number of online logical CPUs.
/// @return The number of online logical CPUs, or -1 on failure.
int mojolt_thread_get_online_cpus(void) {
    long nprocs = sysconf(_SC_NPROCESSORS_ONLN);

    if (nprocs <= 0 || nprocs > INT_MAX)
        return -1;

    return (int)nprocs;
}

/// @brief Returns the number of logical CPUs available to the calling thread.
/// @return The number of available logical CPUs, or -1 on failure.
int mojolt_thread_get_available_cpus(void) {
    cpu_set_t cpuset;

    // Initialize the CPU affinity mask
    CPU_ZERO(&cpuset);

    // Retrieve the affinity mask of the calling thread
    int result = pthread_getaffinity_np(
        pthread_self(),
        sizeof(cpuset),
        &cpuset
    );

    // Handle affinity retrieval failure
    if (result != 0)
        return -result;

    // Count the available logical CPUs
    return CPU_COUNT(&cpuset);
}

/// @brief Retrieves the logical CPU IDs available to the calling thread.
/// @param cpu_ids Output buffer for logical CPU IDs.
/// @param max_cpus Maximum number of CPU IDs the buffer can hold.
/// @return Number of CPU IDs written, or a negative error code.
int mojolt_thread_get_available_cpu_ids(
    int *cpu_ids,
    int max_cpus
) {
    // Validate the output buffer
    if (!cpu_ids || max_cpus <= 0)
        return -EINVAL;

    // Initialize the CPU affinity mask
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);

    // Retrieve the affinity mask of the calling thread
    int result = pthread_getaffinity_np(
        pthread_self(),
        sizeof(cpuset),
        &cpuset
    );

    // Return the negative error code on failure
    if (result != 0)
        return -result;

    // Ensure that the output buffer has sufficient capacity
    if (CPU_COUNT(&cpuset) > max_cpus)
        return -ENOSPC;

    // Extract available logical CPU IDs
    int count = 0;

    for (int i = 0; i < CPU_SETSIZE; i++) {
        if (CPU_ISSET(i, &cpuset))
            cpu_ids[count++] = i;
    }

    return count;
}

// endregion Thread Management