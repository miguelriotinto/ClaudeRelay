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

int relay_get_parent_pid(int pid) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) < 0) return -1;
    if (size == 0) return -1;
    return (int)info.kp_eproc.e_ppid;
}
