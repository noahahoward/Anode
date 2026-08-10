// Reaching launchd's socket-activation call from Swift.
//
// `launch_activate_socket` is public, documented and stable — it is in
// <launch.h> in the macOS SDK and has been since 10.10 — but that header is not
// part of the Darwin module map, so Swift cannot see it. This target is the
// three lines that fix that, and it exists for no other reason.
//
// The wrapper is not a straight re-export. `launch_activate_socket` returns a
// malloc'd array of file descriptors that the caller must free, which is an
// ownership dance that has no business crossing into Swift when every socket in
// this project is a single listener. The wrapper does the dance in C and hands
// back one descriptor.

#pragma once

/// Fetch the single listening socket launchd is holding for `name`.
///
/// `name` is the key under `Sockets` in the job's plist — "FanControl" here.
///
/// Returns 0 on success, having written the descriptor to `out_fd`. The
/// descriptor belongs to this process and is already bound and listening;
/// launchd created it, which is the whole point (it holds the socket while
/// nothing is running, and starts this program when a connection arrives).
///
/// On failure returns the errno-style code from `launch_activate_socket` —
/// notably ESRCH when this process was not started by launchd, and ENOENT when
/// the job has no socket by that name. Returns EINVAL if launchd handed back a
/// number of sockets other than one, which would mean the plist and this code
/// disagree about the job's shape.
int bs_launch_activate_one(const char *name, int *out_fd);
