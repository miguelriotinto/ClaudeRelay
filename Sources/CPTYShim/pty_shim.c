#include "pty_shim.h"
#include <util.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <string.h>
#include <stdlib.h>
#include <libproc.h>

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
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    int ret = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
    if (ret <= 0) return -1;
    const char *name = strrchr(pathbuf, '/');
    name = name ? name + 1 : pathbuf;
    strncpy(buf, name, bufsize - 1);
    buf[bufsize - 1] = '\0';
    return 0;
}
