#ifndef RNNOISE_UNISTD_H
#define RNNOISE_UNISTD_H

#ifdef _WIN32
#include <process.h>
#include <io.h>
#include <windows.h>

/* Minimal POSIX compatibility */
#ifndef getpid
#define getpid _getpid
#endif

#ifndef ssize_t
#if defined(_WIN64)
typedef long long ssize_t;
#else
typedef int ssize_t;
#endif
#endif

/* Provide sleep in seconds -> Sleep expects ms */
static inline unsigned sleep(unsigned seconds) { Sleep(seconds * 1000); return 0; }

#else
#include_next <unistd.h>
#endif

#endif /* RNNOISE_UNISTD_H */
