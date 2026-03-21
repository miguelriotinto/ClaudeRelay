#ifndef PTY_SHIM_H
#define PTY_SHIM_H

#include <sys/ioctl.h>
#include <termios.h>

/// Fork a new process with a pseudo-terminal.
/// Returns child PID to parent (>0), 0 to child, -1 on error.
int relay_forkpty(int *master_fd, struct winsize *ws);

/// Set terminal window size on the given master fd.
int relay_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif /* PTY_SHIM_H */
