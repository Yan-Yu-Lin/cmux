#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC_RAW, &value);
    return (double)value.tv_sec * 1000.0 + (double)value.tv_nsec / 1000000.0;
}

static void bench_libproc(void) {
    double started = now_ms();
    int count = proc_listallpids(NULL, 0);
    double counted = now_ms();
    int capacity = count + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    int returned = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    double listed = now_ms();
    int infos = 0;
    for (int index = 0; index < returned && index < capacity; index++) {
        struct proc_bsdinfo info = {0};
        if (pids[index] > 0 &&
            proc_pidinfo(pids[index], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
            infos++;
        }
    }
    double finished = now_ms();
    printf(
        "libproc count=%d infos=%d count_ms=%.3f list_ms=%.3f info_ms=%.3f total_ms=%.3f\n",
        returned,
        infos,
        counted - started,
        listed - counted,
        finished - listed,
        finished - started
    );
    free(pids);
}

static void bench_sysctl(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t bytes = 0;
    double started = now_ms();
    int size_result = sysctl(mib, 3, NULL, &bytes, NULL, 0);
    double sized = now_ms();
    size_t capacity = bytes + 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = malloc(capacity);
    size_t returned_bytes = capacity;
    int data_result = sysctl(mib, 3, processes, &returned_bytes, NULL, 0);
    double finished = now_ms();
    printf(
        "sysctl result=%d/%d errno=%d count=%zu size_ms=%.3f data_ms=%.3f total_ms=%.3f\n",
        size_result,
        data_result,
        errno,
        returned_bytes / sizeof(struct kinfo_proc),
        sized - started,
        finished - sized,
        finished - started
    );
    free(processes);
}

int main(void) {
    for (int iteration = 0; iteration < 10; iteration++) {
        bench_libproc();
        bench_sysctl();
        fflush(stdout);
    }
    return 0;
}
