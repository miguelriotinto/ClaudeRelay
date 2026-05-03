#include "pty_shim.h"
#include <util.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/proc.h>

int relay_forkpty(int *master_fd, struct winsize *ws) {
    return forkpty(master_fd, NULL, NULL, ws);
}

int relay_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int relay_get_foreground_pgid(int fd) {
    return tcgetpgrp(fd);
}

int relay_get_process_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;
    char *args = malloc(size);
    if (!args) return -1;
    if (sysctl(mib, 3, args, &size, NULL, 0) < 0) { free(args); return -1; }
    // KERN_PROCARGS2: first 4 bytes = argc, then the executable path as a C string.
    if (size < sizeof(int) + 2) { free(args); return -1; }
    const char *path = args + sizeof(int);
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    strncpy(buf, name, bufsize - 1);
    buf[bufsize - 1] = '\0';
    free(args);
    return 0;
}

int relay_get_process_script_name(int pid, char *buf, int bufsize) {
    if (bufsize <= 0) return -1;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;
    char *args = malloc(size);
    if (!args) return -1;
    if (sysctl(mib, 3, args, &size, NULL, 0) < 0) { free(args); return -1; }
    // KERN_PROCARGS2 layout:
    //   int argc
    //   char exec_path[]    (null-terminated executable path)
    //   char[] padding of \0 bytes
    //   char argv[0][]      (null-terminated)
    //   char argv[1][]      (null-terminated)  ← we want this
    //   ...
    if (size < sizeof(int) + 2) { free(args); return -1; }
    int argc = *(int *)args;
    if (argc < 2) { free(args); return -1; }

    const char *cursor = args + sizeof(int);
    const char *end = args + size;

    // Skip the executable path (first null-terminated string).
    while (cursor < end && *cursor != '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }
    cursor++;

    // Skip any padding nulls between exec_path and argv[0].
    while (cursor < end && *cursor == '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }

    // Now at argv[0]. Skip to the end of it.
    while (cursor < end && *cursor != '\0') cursor++;
    if (cursor >= end) { free(args); return -1; }
    cursor++;

    // Now at argv[1], if present.
    if (cursor >= end || *cursor == '\0') { free(args); return -1; }

    const char *argv1 = cursor;
    const char *name = strrchr(argv1, '/');
    name = name ? name + 1 : argv1;
    strncpy(buf, name, bufsize - 1);
    buf[bufsize - 1] = '\0';
    free(args);
    return 0;
}

int relay_get_parent_pid(int pid) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) < 0) return -1;
    if (size == 0) return -1;
    return (int)info.kp_eproc.e_ppid;
}
