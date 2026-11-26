#ifndef MOJOLT_CONTROL_H
#define MOJOLT_CONTROL_H

#ifdef __cplusplus
extern "C" {
#endif

/** @file
 * @brief Opaque mutexes and eventfd notifications for externally synchronized owners.
 * Status functions return zero or a positive POSIX error. Descriptor creation
 * returns a nonnegative fd or -errno. Handles and fd arguments are borrowed;
 * only the owner destroys a mutex or closes an fd after all users have stopped.
 */

/** @brief Opaque, nonrecursive mutex with exclusive destruction ownership. */
typedef struct MojoltMutex MojoltMutex;
/** @brief Allocate an unlocked mutex; return zero or a positive POSIX error. */
int mojolt_mutex_create(MojoltMutex **mutex);
/** @brief Destroy an unused, unlocked mutex; failure preserves its handle. */
int mojolt_mutex_destroy(MojoltMutex **mutex);
/** @brief Block until locked; the calling thread must not already own it. */
int mojolt_mutex_lock(MojoltMutex *mutex);
/** @brief Unlock on the locking thread; return zero or a positive error. */
int mojolt_mutex_unlock(MojoltMutex *mutex);
/** @brief Acquire without blocking; EBUSY means another thread owns it. */
int mojolt_mutex_try_lock(MojoltMutex *mutex);
/** @brief Create nonblocking CLOEXEC eventfd; return a descriptor or -errno. */
int mojolt_event_create(void);
/** @brief Signal eventfd, retry EINTR, and treat saturation as already signaled.
 * @return Zero or a positive POSIX error code.
 * @note The owner must synchronize close against concurrent signal/drain.
 */
int mojolt_event_signal(int fd);
/** @brief Consume coalesced notifications; empty counters succeed as well. */
int mojolt_event_drain(int fd);

#ifdef __cplusplus
}
#endif
#endif
