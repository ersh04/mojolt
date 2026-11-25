#ifndef MOJOLT_THREADING_H
#define MOJOLT_THREADING_H
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>

#ifdef __cplusplus
extern "C" {
#endif

/// @brief Opaque native thread handle.
typedef struct MojoltThread MojoltThread;

/// @brief Native thread entry point.
typedef void *(*MojoltThreadEntry)(void *);

int mojolt_thread_create(
    MojoltThread **thread,
    MojoltThreadEntry start_routine,
    void *arg
);

int mojolt_thread_join(MojoltThread **thread);

int mojolt_thread_detach(MojoltThread **thread);

int mojolt_thread_set_current_affinity(int cpu);

int mojolt_thread_get_online_cpus(void);

int mojolt_thread_get_available_cpus(void);

int mojolt_thread_get_available_cpu_ids(
    int *cpu_ids,
    int max_cpus
);

#ifdef __cplusplus
}
#endif

#endif