#ifndef PTY_SHIM_H
#define PTY_SHIM_H

#include <sys/ioctl.h>
#include <termios.h>

/// Fork a new process with a pseudo-terminal.
/// Returns child PID to parent (>0), 0 to child, -1 on error.
int relay_forkpty(int *master_fd, struct winsize *ws);

/// Set terminal window size on the given master fd.
int relay_set_winsize(int fd, unsigned short rows, unsigned short cols);

/// Get the foreground process group ID for the given fd via tcgetpgrp.
/// Returns the PGID, or -1 on error.
int relay_get_foreground_pgid(int fd);

/// Get the executable name for the given PID via sysctl(KERN_PROCARGS2).
/// Writes into `buf` (max `bufsize` bytes). Returns 0 on success, -1 on error.
int relay_get_process_name(int pid, char *buf, int bufsize);

#endif /* PTY_SHIM_H */
