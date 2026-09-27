#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define ASKPASS_SOCKET_ENV "JTS_TERMINAL_ASKPASS_SOCKET"
#define ASKPASS_CHALLENGE_ENV "JTS_TERMINAL_ASKPASS_CHALLENGE"
#define CHALLENGE_BYTES 32U
#define CHALLENGE_HEX_BYTES (CHALLENGE_BYTES * 2U)
#define MAXIMUM_SECRET_BYTES 4096U
#define IO_TIMEOUT_SECONDS 5

static const uint8_t request_magic[] = "JTSA1REQ";
static const uint8_t response_magic[] = "JTSA1RES";
static const uint8_t acknowledgement_magic[] = "JTSA1ACK";

struct socket_identity {
    dev_t device;
    ino_t inode;
};

static bool ends_case_insensitive(
    const char *bytes,
    size_t length,
    const char *suffix
) {
    size_t suffix_length = strlen(suffix);
    if (suffix_length == 0 || suffix_length > length) {
        return false;
    }

    return strncasecmp(
        bytes + length - suffix_length,
        suffix,
        suffix_length
    ) == 0;
}

static bool is_server_password_prompt(const char *prompt) {
    if (prompt == NULL) {
        return false;
    }

    const char *start = prompt;
    while (*start != '\0' && isspace((unsigned char)*start)) {
        start++;
    }

    const char *end = prompt + strlen(prompt);
    while (end > start && isspace((unsigned char)end[-1])) {
        end--;
    }

    size_t length = (size_t)(end - start);
    static const char generic_prompt[] = "password:";
    static const char ascii_possessive_suffix[] = "'s password:";
    static const char unicode_possessive_suffix[] = "\xE2\x80\x99s password:";
    return (length == sizeof(generic_prompt) - 1 &&
            ends_case_insensitive(start, length, generic_prompt)) ||
        ends_case_insensitive(start, length, ascii_possessive_suffix) ||
        ends_case_insensitive(start, length, unicode_possessive_suffix);
}

static int hex_nibble(unsigned char byte) {
    if (byte >= '0' && byte <= '9') {
        return byte - '0';
    }
    if (byte >= 'a' && byte <= 'f') {
        return byte - 'a' + 10;
    }
    return -1;
}

static bool decode_challenge(const char *encoded, uint8_t output[CHALLENGE_BYTES]) {
    if (encoded == NULL || strlen(encoded) != CHALLENGE_HEX_BYTES) {
        return false;
    }

    for (size_t index = 0; index < CHALLENGE_BYTES; index++) {
        int high = hex_nibble((unsigned char)encoded[index * 2]);
        int low = hex_nibble((unsigned char)encoded[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        output[index] = (uint8_t)((high << 4) | low);
    }
    return true;
}

static bool owner_only_socket_boundary(
    const char *socket_path,
    struct socket_identity *identity
) {
    if (socket_path == NULL || socket_path[0] != '/' ||
        strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
        strchr(socket_path, '\n') != NULL || strchr(socket_path, '\r') != NULL) {
        return false;
    }

    const char *last_slash = strrchr(socket_path, '/');
    if (last_slash == NULL || strcmp(last_slash + 1, "s") != 0 ||
        last_slash == socket_path) {
        return false;
    }

    char parent_path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    size_t parent_length = (size_t)(last_slash - socket_path);
    if (parent_length == 0 || parent_length >= sizeof(parent_path)) {
        return false;
    }
    memcpy(parent_path, socket_path, parent_length);

    struct stat parent_status;
    struct stat socket_status;
    bool safe = lstat(parent_path, &parent_status) == 0 &&
        S_ISDIR(parent_status.st_mode) &&
        parent_status.st_uid == geteuid() &&
        (parent_status.st_mode & 0777) == S_IRWXU &&
        lstat(socket_path, &socket_status) == 0 &&
        S_ISSOCK(socket_status.st_mode) &&
        socket_status.st_uid == geteuid() &&
        (socket_status.st_mode & 0777) == (S_IRUSR | S_IWUSR) &&
        socket_status.st_nlink == 1;
    (void)memset_s(parent_path, sizeof(parent_path), 0, sizeof(parent_path));
    if (!safe) {
        return false;
    }

    identity->device = socket_status.st_dev;
    identity->inode = socket_status.st_ino;
    return true;
}

static bool same_socket_identity(
    const struct socket_identity *left,
    const struct socket_identity *right
) {
    return left->device == right->device && left->inode == right->inode;
}

static bool configure_socket(int descriptor) {
    struct timeval timeout = {
        .tv_sec = IO_TIMEOUT_SECONDS,
        .tv_usec = 0,
    };
    int enabled = 1;
    return setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        sizeof(timeout)
    ) == 0 &&
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            sizeof(timeout)
        ) == 0 &&
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            sizeof(enabled)
        ) == 0;
}

static bool connect_to_broker(int descriptor, const char *socket_path) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    if (strlcpy(address.sun_path, socket_path, sizeof(address.sun_path)) >=
        sizeof(address.sun_path)) {
        return false;
    }
    return connect(
        descriptor,
        (const struct sockaddr *)&address,
        sizeof(address)
    ) == 0;
}

static bool peer_is_current_user(int descriptor) {
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    return getpeereid(descriptor, &peer_uid, &peer_gid) == 0 &&
        peer_uid == geteuid();
}

static bool write_all(int descriptor, const uint8_t *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = send(descriptor, bytes, length, 0);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }

        bytes += written;
        length -= (size_t)written;
    }
    return true;
}

static bool write_all_output(const uint8_t *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(STDOUT_FILENO, bytes, length);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }
        bytes += written;
        length -= (size_t)written;
    }
    return true;
}

static bool read_exactly(int descriptor, uint8_t *bytes, size_t length) {
    while (length > 0) {
        ssize_t received = recv(descriptor, bytes, length, 0);
        if (received < 0 && errno == EINTR) {
            continue;
        }
        if (received <= 0) {
            return false;
        }

        bytes += received;
        length -= (size_t)received;
    }
    return true;
}

static bool broker_finished_response(int descriptor) {
    uint8_t extra = 0;
    while (true) {
        ssize_t received = recv(descriptor, &extra, sizeof(extra), 0);
        if (received < 0 && errno == EINTR) {
            continue;
        }
        return received == 0;
    }
}

static uint32_t decode_big_endian_u32(const uint8_t bytes[4]) {
    return ((uint32_t)bytes[0] << 24) |
        ((uint32_t)bytes[1] << 16) |
        ((uint32_t)bytes[2] << 8) |
        (uint32_t)bytes[3];
}

int main(int argc, char *argv[]) {
    int result = EXIT_FAILURE;
    int descriptor = -1;
    uint8_t challenge[CHALLENGE_BYTES] = {0};
    uint8_t request[sizeof(request_magic) - 1 + CHALLENGE_BYTES] = {0};
    uint8_t response_header[sizeof(response_magic) - 1 + 4] = {0};
    uint8_t secret[MAXIMUM_SECRET_BYTES] = {0};

    if (argc != 2 || !is_server_password_prompt(argv[1])) {
        goto cleanup;
    }

    const char *socket_path = getenv(ASKPASS_SOCKET_ENV);
    if (!decode_challenge(getenv(ASKPASS_CHALLENGE_ENV), challenge)) {
        goto cleanup;
    }

    struct socket_identity original_socket;
    if (!owner_only_socket_boundary(socket_path, &original_socket)) {
        goto cleanup;
    }

    descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0 || !configure_socket(descriptor) ||
        !connect_to_broker(descriptor, socket_path) ||
        !peer_is_current_user(descriptor)) {
        goto cleanup;
    }

    struct socket_identity connected_socket;
    if (!owner_only_socket_boundary(socket_path, &connected_socket) ||
        !same_socket_identity(&original_socket, &connected_socket)) {
        goto cleanup;
    }

    memcpy(request, request_magic, sizeof(request_magic) - 1);
    memcpy(request + sizeof(request_magic) - 1, challenge, sizeof(challenge));
    if (!write_all(descriptor, request, sizeof(request)) ||
        !read_exactly(descriptor, response_header, sizeof(response_header)) ||
        memcmp(response_header, response_magic, sizeof(response_magic) - 1) != 0) {
        goto cleanup;
    }

    uint32_t secret_length = decode_big_endian_u32(
        response_header + sizeof(response_magic) - 1
    );
    if (secret_length == 0 || secret_length > MAXIMUM_SECRET_BYTES ||
        !read_exactly(descriptor, secret, secret_length) ||
        !broker_finished_response(descriptor) ||
        memchr(secret, '\0', secret_length) != NULL ||
        memchr(secret, '\n', secret_length) != NULL ||
        memchr(secret, '\r', secret_length) != NULL) {
        goto cleanup;
    }

    if (!write_all_output(secret, secret_length) ||
        !write_all_output((const uint8_t *)"\n", 1)) {
        goto cleanup;
    }
    if (!write_all(
            descriptor,
            acknowledgement_magic,
            sizeof(acknowledgement_magic) - 1
        ) ||
        shutdown(descriptor, SHUT_WR) != 0) {
        goto cleanup;
    }
    result = EXIT_SUCCESS;

cleanup:
    if (descriptor >= 0) {
        close(descriptor);
    }
    (void)memset_s(secret, sizeof(secret), 0, sizeof(secret));
    (void)memset_s(
        response_header,
        sizeof(response_header),
        0,
        sizeof(response_header)
    );
    (void)memset_s(request, sizeof(request), 0, sizeof(request));
    (void)memset_s(challenge, sizeof(challenge), 0, sizeof(challenge));
    return result;
}
