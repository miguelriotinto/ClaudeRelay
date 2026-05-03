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

/// Get argv[1] (typically the script path for node/python/ruby scripts) for
/// the given PID via sysctl(KERN_PROCARGS2). Writes the basename into `buf`
/// (max `bufsize` bytes). Returns 0 on success, -1 on error or if argv[1]
/// is absent. Used to detect script-based agents whose executable is an
/// interpreter (e.g. `node /opt/homebrew/bin/codex` → returns "codex").
int relay_get_process_script_name(int pid, char *buf, int bufsize);

/// Get the parent PID of the given PID via sysctl(KERN_PROC).
/// Returns the PPID, or -1 on error.
int relay_get_parent_pid(int pid);

#endif /* PTY_SHIM_H */
