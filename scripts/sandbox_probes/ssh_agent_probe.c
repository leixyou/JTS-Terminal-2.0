// Measures what an App Sandbox process can reach of an ssh-agent and of
// ~/.ssh. Built and signed by run_ssh_agent_probe.sh with JTS Terminal's own
// entitlements; the same binary signed without entitlements is the control.
//
// Usage: ssh-agent-probe [file-to-open]
// Environment: SSH_AUTH_SOCK selects the agent socket to test.
// JTS_PROBE_SSH_TARGET (user@host) and JTS_PROBE_SSH_PORT, when set, add a
// real public-key login with /usr/bin/ssh that can only succeed through the
// agent, because the probe cannot read any private key file.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// libsystem_sandbox: returns 1 when `pid` runs inside a sandbox.
int sandbox_check(pid_t pid, const char *operation, int type, ...);

static int read_exactly(int fd, unsigned char *buffer, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = read(fd, buffer + done, length - done);
        if (count <= 0) {
            return -1;
        }
        done += (size_t)count;
    }
    return 0;
}

// Connects to the agent and asks for its identities, as ssh does before
// public-key authentication.
static const char *probe_agent_socket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("  socket(): FAILED errno=%d (%s)\n", errno, strerror(errno));
        return "SOCKET_FAILED";
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    if (strlcpy(address.sun_path, path, sizeof address.sun_path) >= sizeof address.sun_path) {
        close(fd);
        printf("  socket path too long\n");
        return "PATH_TOO_LONG";
    }

    if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) {
        int error = errno;
        close(fd);
        printf("  connect(): FAILED errno=%d (%s)\n", error, strerror(error));
        return error == EPERM || error == EACCES ? "DENIED" : "CONNECT_FAILED";
    }

    // SSH_AGENTC_REQUEST_IDENTITIES (11); reply SSH_AGENT_IDENTITIES_ANSWER (12).
    const unsigned char request[5] = {0, 0, 0, 1, 11};
    if (write(fd, request, sizeof request) != (ssize_t)sizeof request) {
        int error = errno;
        close(fd);
        printf("  write(): FAILED errno=%d (%s)\n", error, strerror(error));
        return "WRITE_FAILED";
    }

    unsigned char header[5];
    if (read_exactly(fd, header, sizeof header) != 0) {
        close(fd);
        printf("  read(): FAILED\n");
        return "READ_FAILED";
    }
    uint32_t length;
    memcpy(&length, header, sizeof length);
    length = ntohl(length);
    if (header[4] != 12 || length < 5) {
        close(fd);
        printf("  unexpected agent reply type=%u length=%u\n", header[4], length);
        return "BAD_REPLY";
    }
    unsigned char count_bytes[4];
    if (read_exactly(fd, count_bytes, sizeof count_bytes) != 0) {
        close(fd);
        printf("  read(count): FAILED\n");
        return "READ_FAILED";
    }
    close(fd);
    uint32_t count;
    memcpy(&count, count_bytes, sizeof count);
    printf("  connect(): OK, agent lists %u identities\n", ntohl(count));
    return "OK";
}

// Runs a system tool the way JTS Terminal runs /usr/bin/ssh: a child process
// that inherits the sandbox and SSH_AUTH_SOCK. Returns its exit status.
static int run_child(const char *label, char *const arguments[]) {
    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        printf("  pipe(): FAILED\n");
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipe_fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipe_fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipe_fds[0]);

    pid_t pid;
    int spawn_error = posix_spawn(&pid, arguments[0], &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipe_fds[1]);
    if (spawn_error != 0) {
        close(pipe_fds[0]);
        printf("  posix_spawn(%s): FAILED errno=%d (%s)\n", label, spawn_error, strerror(spawn_error));
        return -1;
    }

    char output[4096];
    size_t used = 0;
    ssize_t count;
    while (used < sizeof output - 1 && (count = read(pipe_fds[0], output + used, sizeof output - 1 - used)) > 0) {
        used += (size_t)count;
    }
    output[used] = '\0';
    close(pipe_fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    printf("  %s exit=%d: %s", label, exit_code, used > 0 ? output : "(no output)\n");
    if (used > 0 && output[used - 1] != '\n') {
        printf("\n");
    }
    return exit_code;
}

// ssh-add -l: 0 = identities listed, 1 = agent reached but empty,
// 2 = could not contact the agent.
static int probe_ssh_add(void) {
    char *const arguments[] = {"/usr/bin/ssh-add", "-l", NULL};
    return run_child("ssh-add -l", arguments);
}

// Public-key login without any configuration or key file, so only the agent
// can authenticate. 0 = logged in, 255 = rejected or unreachable.
static int probe_ssh_login(const char *target, const char *port) {
    char *const arguments[] = {
        "/usr/bin/ssh", "-F", "/dev/null", "-p", (char *)port,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "PreferredAuthentications=publickey",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=10",
        "--", (char *)target, "true", NULL
    };
    return run_child("ssh login", arguments);
}

static const char *probe_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        int error = errno;
        printf("  open(%s): FAILED errno=%d (%s)\n", path, error, strerror(error));
        return error == EPERM || error == EACCES ? "DENIED" : "OPEN_FAILED";
    }
    close(fd);
    printf("  open(%s): OK\n", path);
    return "OK";
}

int main(int argc, char *argv[]) {
    int sandboxed = sandbox_check(getpid(), NULL, 0) == 1;
    const char *socket_path = getenv("SSH_AUTH_SOCK");
    struct passwd *account = getpwuid(getuid());

    printf("  sandboxed=%s HOME=%s account_home=%s\n",
           sandboxed ? "yes" : "no",
           getenv("HOME") ? getenv("HOME") : "(unset)",
           account && account->pw_dir ? account->pw_dir : "(unknown)");

    const char *socket_result = "NO_SOCKET";
    int ssh_add_exit = -1;
    int ssh_login_exit = -1;
    if (socket_path && socket_path[0] != '\0') {
        printf("  SSH_AUTH_SOCK=%s\n", socket_path);
        socket_result = probe_agent_socket(socket_path);
        ssh_add_exit = probe_ssh_add();
        const char *target = getenv("JTS_PROBE_SSH_TARGET");
        const char *port = getenv("JTS_PROBE_SSH_PORT");
        if (target && target[0] != '\0' && port && port[0] != '\0') {
            ssh_login_exit = probe_ssh_login(target, port);
        }
    } else {
        printf("  SSH_AUTH_SOCK is not set\n");
    }

    const char *file_result = "NOT_TESTED";
    if (argc > 1) {
        file_result = probe_file(argv[1]);
    }

    printf("RESULT sandboxed=%s socket=%s ssh_add_exit=%d ssh_login_exit=%d key_file=%s\n",
           sandboxed ? "yes" : "no", socket_result, ssh_add_exit, ssh_login_exit, file_result);
    return 0;
}
