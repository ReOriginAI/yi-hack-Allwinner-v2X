/* Bound a recovery worker and its process group without blocking its watchdog. */
#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

static volatile sig_atomic_t stopped;
static void stop(int sig) { stopped = sig; }
static double monotime(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) _exit(125);
    return t.tv_sec + t.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    char *end;
    long limit;
    pid_t child, result;
    int status = 0, expired = 0;
    struct sigaction action = {0};
    struct timespec tick = {0, 100000000};
    double deadline;
    if (argc < 3) return 2;
    errno = 0;
    limit = strtol(argv[1], &end, 10);
    if (errno || *end || limit < 1 || limit > 3600) return 2;
    /* An inherited ignored SIGCHLD would make children auto-reap. */
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(SIGCHLD, &action, NULL);
    sigprocmask(SIG_SETMASK, &action.sa_mask, NULL);
    action.sa_handler = stop;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    child = fork();
    if (child < 0) { perror("service_guard fork"); return 125; }
    if (!child) {
        /* The caller may be a shell without job control. Use a private group. */
        if (setpgid(0, 0)) _exit(125);
        action.sa_handler = SIG_DFL;
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGINT, &action, NULL);
        sigaction(SIGHUP, &action, NULL);
        execvp(argv[2], argv + 2);
        perror("service_guard exec");
        _exit(127);
    }
    /* Either parent or child may establish the group first. */
    if (setpgid(child, child) && errno != EACCES && errno != ESRCH) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        return 125;
    }
    deadline = monotime() + limit;
    for (;;) {
        result = waitpid(child, &status, WNOHANG);
        if (result == child) break;
        if (result < 0 && errno != EINTR) return 125;
        if (stopped || monotime() >= deadline) {
            expired = 1;
            break;
        }
        nanosleep(&tick, NULL);
    }
    if (expired) {
        /* Keep child unreaped until the final kill: its PID/group cannot recycle. */
        fprintf(stderr, "service_guard: worker stopped or exceeded %lds\n", limit);
        kill(-child, SIGTERM);
        deadline = monotime() + 1;
        while (monotime() < deadline) nanosleep(&tick, NULL);
        kill(-child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        return stopped ? 128 + stopped : 124;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
