#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MIB ((size_t)1024 * 1024)
static volatile sig_atomic_t stopping;

static void fail(const char *message) {
    perror(message);
    exit(1);
}

static void require(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

static bool try_parse_size(const char *value, size_t *size) {
    if (*value < '0' || *value > '9') return false;
    char *end;
    errno = 0;
    unsigned long mib = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || mib < 1 || mib > 1024) return false;
    *size = (size_t)mib * MIB;
    return true;
}

static size_t parse_size(const char *value) {
    size_t size;
    require(try_parse_size(value, &size), "allocation must be between 1 and 1024 MiB");
    return size;
}

static void check_bytes(const unsigned char *memory, size_t size, unsigned char expected) {
    for (size_t i = 0; i < size; i++) {
        if (memory[i] != expected) {
            fprintf(stderr, "canary mismatch at byte %zu: expected %u, found %u\n",
                    i, expected, memory[i]);
            exit(1);
        }
    }
}

static unsigned char *allocate(size_t size, unsigned char pattern) {
    unsigned char *memory = mmap(NULL, size, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) fail("mmap");
    // Check demand-zero reuse before any userspace initialization can hide stale backing.
    check_bytes(memory, size, 0);
    memset(memory, pattern, size);
    return memory;
}

static void release(unsigned char *memory, size_t size) {
    if (memory != NULL && munmap(memory, size) != 0) fail("munmap");
}

static void write_all(int fd, const void *data, size_t size) {
    const unsigned char *bytes = data;
    while (size > 0) {
        ssize_t written = write(fd, bytes, size);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) fail("write");
        bytes += written;
        size -= (size_t)written;
    }
}

static void socket_address(struct sockaddr_un *address) {
    const char *path = getenv("CONJET_MEMORY_FIXTURE_SOCKET");
    if (path == NULL) path = "/tmp/conjet-memory-fixture.sock";
    require(strlen(path) < sizeof(address->sun_path), "socket path is too long");
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, strlen(path) + 1);
}

static int connect_socket(void) {
    struct sockaddr_un address;
    socket_address(&address);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) fail("socket");
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) fail("connect");
    struct timeval timeout = {.tv_sec = 30};
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) fail("setsockopt");
    return fd;
}

static void stop(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static void serve(size_t retained_size) {
    unsigned char *retained = allocate(retained_size, 0xa7);
    unsigned char *temporary = NULL;
    size_t temporary_size = 0;
    struct sockaddr_un address;
    socket_address(&address);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) fail("socket");
    // Do not unlink an existing endpoint belonging to another fixture.
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) fail("bind");
    if (listen(listener, 8) != 0) fail("listen");
    struct sigaction action = {0};
    action.sa_handler = stop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0) fail("sigaction");
    while (!stopping) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0 && errno == EINTR) continue;
        if (fd < 0) fail("accept");
        struct timeval timeout = {.tv_sec = 5};
        if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) fail("setsockopt");
        char request[64] = {0};
        size_t length = 0;
        while (length < sizeof(request) - 1) {
            ssize_t count = read(fd, request + length, 1);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0 || request[length] == '\n') break;
            length++;
        }
        request[length] = '\0';
        bool ok = true;
        const char *error = "";
        if (strcmp(request, "status") == 0) {
            // Health probes do not scan memory or create a periodic allocator workload.
        } else if (strcmp(request, "verify") == 0 || strcmp(request, "free") == 0) {
            check_bytes(retained, retained_size, 0xa7);
            if (temporary != NULL) check_bytes(temporary, temporary_size, 0x5c);
            if (strcmp(request, "free") == 0) {
                release(temporary, temporary_size);
                temporary = NULL;
                temporary_size = 0;
            }
        } else if (strncmp(request, "allocate ", 9) == 0 || strncmp(request, "reuse ", 6) == 0) {
            bool reuse = strncmp(request, "reuse ", 6) == 0;
            size_t size = 0;
            if (temporary != NULL) {
                ok = false;
                error = "allocation already held";
            } else if (!try_parse_size(request + (reuse ? 6 : 9), &size)) {
                ok = false;
                error = "allocation must be between 1 and 1024 MiB";
            } else {
                check_bytes(retained, retained_size, 0xa7);
                temporary = allocate(size, 0x5c);
                temporary_size = size;
                check_bytes(retained, retained_size, 0xa7);
                if (reuse) {
                    check_bytes(temporary, temporary_size, 0x5c);
                    release(temporary, temporary_size);
                    temporary = NULL;
                    temporary_size = 0;
                }
            }
        } else {
            ok = false;
            error = "unknown command";
        }
        char response[256];
        int count = snprintf(response, sizeof(response),
            "{\"ok\":%s,\"retained_bytes\":%zu,\"allocated_bytes\":%zu,\"error\":\"%s\"}\n",
            ok ? "true" : "false", retained_size, temporary_size, error);
        require(count > 0 && (size_t)count < sizeof(response), "response overflow");
        write_all(fd, response, (size_t)count);
        close(fd);
    }
    check_bytes(retained, retained_size, 0xa7);
    release(temporary, temporary_size);
    release(retained, retained_size);
    close(listener);
    if (unlink(address.sun_path) != 0) fail("unlink socket");
}

static void control(int argc, char **argv) {
    require(argc == 3 || argc == 4, "usage: memory-fixture ctl COMMAND [MIB]");
    int fd = connect_socket();
    write_all(fd, argv[2], strlen(argv[2]));
    if (argc == 4) {
        write_all(fd, " ", 1);
        write_all(fd, argv[3], strlen(argv[3]));
    }
    write_all(fd, "\n", 1);
    char response[256];
    ssize_t size;
    bool received = false;
    while ((size = read(fd, response, sizeof(response))) > 0) {
        received = true;
        write_all(STDOUT_FILENO, response, (size_t)size);
    }
    if (size < 0) fail("read response");
    require(received, "fixture closed without a response");
    close(fd);
}

static void build_workload(size_t size, const char *path) {
    unsigned char *memory = allocate(size, 0x5c);
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) fail("create build file");
    write_all(fd, memory, size);
    if (fsync(fd) != 0 || lseek(fd, 0, SEEK_SET) < 0) fail("sync build file");
    unsigned char buffer[65536];
    size_t remaining = size;
    while (remaining > 0) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail("read build file");
        check_bytes(buffer, (size_t)count, 0x5c);
        remaining -= (size_t)count;
    }
    puts("build allocation and file canaries held");
    fflush(stdout);
    // Hold a known allocation long enough for a coarse correctness sampler to observe it.
    struct timespec delay = {.tv_sec = 6};
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    check_bytes(memory, size, 0x5c);
    release(memory, size);
    if (close(fd) != 0 || unlink(path) != 0) fail("remove build file");
    puts("build allocation and file canaries verified and released");
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    require(argc >= 2, "usage: memory-fixture serve MIB | ctl COMMAND [MIB] | build MIB PATH");
    if (strcmp(argv[1], "serve") == 0 && argc == 3) serve(parse_size(argv[2]));
    else if (strcmp(argv[1], "ctl") == 0) control(argc, argv);
    else if (strcmp(argv[1], "build") == 0 && argc == 4) build_workload(parse_size(argv[2]), argv[3]);
    else require(false, "invalid fixture arguments");
    return 0;
}
