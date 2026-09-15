/* Avoid two child processes per SD identity poll in the vendor broker.
 * Only the audited literal command and read mode are intercepted. All other
 * commands, and file-open/resource failures, retain libc popen semantics.
 */
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include <errno.h>

#ifndef CID_PATH
#define CID_PATH "/sys/block/mmcblk0/device/cid"
#endif
#define CID_COMMAND "cat /sys/block/mmcblk0/device/cid 2>/dev/null"
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *direct[4];
static FILE *(*real_popen)(const char *, const char *);
static int (*real_pclose)(FILE *);

static void resolve(void)
{
    real_popen = dlsym(RTLD_NEXT, "popen");
    real_pclose = dlsym(RTLD_NEXT, "pclose");
}

FILE *popen(const char *command, const char *mode)
{
    int saved = errno;
    pthread_once(&once, resolve);
    if (!real_popen || !real_pclose) { errno = ENOSYS; return NULL; }
    if (strcmp(command, CID_COMMAND) == 0 && strcmp(mode, "r") == 0) {
        FILE *f = fopen(CID_PATH, "r");
        if (f) {
            pthread_mutex_lock(&lock);
            for (unsigned i = 0; i < sizeof(direct)/sizeof(direct[0]); i++) {
                if (!direct[i]) {
                    direct[i] = f;
                    pthread_mutex_unlock(&lock);
                    errno = saved;
                    return f;
                }
            }
            pthread_mutex_unlock(&lock);
            fclose(f);
        }
    }
    errno = saved;
    return real_popen(command, mode);
}

int pclose(FILE *f)
{
    pthread_once(&once, resolve);
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < sizeof(direct)/sizeof(direct[0]); i++) {
        if (direct[i] == f) {
            direct[i] = NULL;
            pthread_mutex_unlock(&lock);
            int failed = ferror(f);
            if (fclose(f) != 0) failed = 1;
            /* pclose returns wait status, not an exit code. */
            return failed ? 1 << 8 : 0;
        }
    }
    pthread_mutex_unlock(&lock);
    if (!real_pclose) { errno = ENOSYS; return -1; }
    return real_pclose(f);
}
