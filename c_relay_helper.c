#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>

// Lightweight bidirectional relay between two TCP sockets using splice when available.
// Falls back to recv/send with a user-provided buffer size.

static int pipe_fds[2] = {-1, -1};

static int ensure_pipe(void) {
    if (pipe_fds[0] != -1) return 0;
    if (pipe(pipe_fds) == -1) return -1;
    fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK);
    fcntl(pipe_fds[1], F_SETFL, O_NONBLOCK);
    return 0;
}

static ssize_t splice_once(int from_fd, int to_fd, size_t max_bytes) {
    if (ensure_pipe() == -1) return -1;
    ssize_t n = splice(from_fd, NULL, pipe_fds[1], NULL, max_bytes, SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
    if (n <= 0) return n;
    ssize_t w = splice(pipe_fds[0], NULL, to_fd, NULL, (size_t)n, SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
    return w;
}

static ssize_t copy_once(int from_fd, int to_fd, char *buf, size_t buf_len) {
    ssize_t n = recv(from_fd, buf, buf_len, 0);
    if (n <= 0) return n;
    size_t sent = 0;
    while (sent < (size_t)n) {
        ssize_t w = send(to_fd, buf + sent, (size_t)n - sent, 0);
        if (w <= 0) return w;
        sent += (size_t)w;
    }
    return n;
}

// relay_pair blocks the calling thread; it returns when either side closes or errors.
// buf_len controls the fallback copy buffer size.
int relay_pair(int fd_a, int fd_b, int buf_len) {
    char *buf = NULL;
    if (buf_len > 0) {
        buf = (char *)malloc((size_t)buf_len);
        if (!buf) return -1;
    }

    struct pollfd fds[2];
    memset(fds, 0, sizeof(fds));
    fds[0].fd = fd_a;
    fds[0].events = POLLIN;
    fds[1].fd = fd_b;
    fds[1].events = POLLIN;

    while (1) {
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) break;

        if (fds[0].revents & POLLIN) {
            ssize_t n = splice_once(fd_a, fd_b, (size_t)buf_len);
            if (n == -1 && errno != EAGAIN) break;
            if (n == 0 || n == -1) {
                n = copy_once(fd_a, fd_b, buf, (size_t)buf_len);
            }
            if (n <= 0) break;
        }
        if (fds[1].revents & POLLIN) {
            ssize_t n = splice_once(fd_b, fd_a, (size_t)buf_len);
            if (n == -1 && errno != EAGAIN) break;
            if (n == 0 || n == -1) {
                n = copy_once(fd_b, fd_a, buf, (size_t)buf_len);
            }
            if (n <= 0) break;
        }
    }

    if (buf) free(buf);
    return 0;
}
