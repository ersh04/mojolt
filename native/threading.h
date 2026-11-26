#ifndef MOJOLT_THREADING_H
#define MOJOLT_THREADING_H

#ifdef __cplusplus
extern "C" {
#endif

/** @brief Exclusive native thread ownership; platform types remain private. */
typedef struct MojoltThread MojoltThread;
/** @brief C ABI callback; arg is borrowed until thread termination. */
typedef void *(*MojoltThreadEntry)(void *);

/** @brief Start a thread. On failure *thread remains NULL.
 * @param thread Initialized NULL output owned by the caller.
 * @param start_routine Non-NULL callback that must not unwind through C.
 * @param arg Borrowed stable context, alive until termination.
 * @return Zero or a positive POSIX error code.
 */
int mojolt_thread_create(MojoltThread **thread, MojoltThreadEntry start_routine, void *arg);
/** @brief Join and release a handle; failure leaves ownership unchanged. */
int mojolt_thread_join(MojoltThread **thread);
/** @brief Join, optionally return the entry result, and clear the owning handle. */
int mojolt_thread_join_result(MojoltThread **thread, void **result);
/** @brief Detach and release a handle; the context must outlive the thread. */
int mojolt_thread_detach(MojoltThread **thread);
/** @brief Return one for the calling thread, zero otherwise, or -EINVAL. */
int mojolt_thread_is_current(const MojoltThread *thread);
/** @brief Pin the calling thread; return zero or a positive POSIX error. */
int mojolt_thread_set_current_affinity(int cpu);
/** @brief Set a thread's CPU set; IDs must be nonnegative and count positive. */
int mojolt_thread_set_affinity(const MojoltThread *thread, const int *ids, int count);
/** @brief Set the calling thread's CPU set; return zero or a positive error. */
int mojolt_thread_set_current_cpu_ids(const int *ids, int count);
/** @brief Set a Linux thread name of at most 15 bytes; return status. */
int mojolt_thread_set_current_name(const char *name);
/** @brief Return online CPU count or a negative POSIX error code. */
int mojolt_thread_get_online_cpus(void);
/** @brief Return calling thread's affinity count or a negative error code. */
int mojolt_thread_get_available_cpus(void);
/** @brief Fill IDs in ascending order; return count or -ENOSPC/-errno.
 * @note Affinity masks are dynamically sized; IDs need not be contiguous.
 */
int mojolt_thread_get_available_cpu_ids(int *cpu_ids, int max_cpus);

#ifdef __cplusplus
}
#endif
#endif
