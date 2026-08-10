#include "CLaunchActivate.h"

#include <errno.h>
#include <launch.h>
#include <stdlib.h>

int bs_launch_activate_one(const char *name, int *out_fd) {
    int *fds = NULL;
    size_t count = 0;

    int rc = launch_activate_socket(name, &fds, &count);
    if (rc != 0) {
        // launchd frees nothing on failure, but it also promises nothing about
        // the out-parameter, so this is checked rather than assumed.
        if (fds) free(fds);
        return rc;
    }
    if (count != 1) {
        if (fds) free(fds);
        return EINVAL;
    }

    if (out_fd) *out_fd = fds[0];
    free(fds);
    return 0;
}
