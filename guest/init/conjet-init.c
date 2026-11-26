// Conjet Pulse PID 1.
//
// This binary is built static for ARM64 Linux and packaged as /init in the
// Pulse initramfs. It performs only launch-critical work: mount the minimal
// kernel filesystems, publish the binary readiness vector over virtio-vsock,
// optionally start one configured process, reap children, and shut down cleanly.

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ptrace.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef VMADDR_CID_HOST
#define VMADDR_CID_HOST 2
#endif

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#define CONJET_READY_PORT 1029U
#define CONJET_FRAME_MAGIC 0x4356534fU
#define CONJET_FRAME_VERSION 1U
#define CONJET_FRAME_KIND_READINESS 8U
#define CONJET_READINESS_MAGIC 0x43524459U
#define CONJET_READINESS_VERSION 1U
#define CONJET_EVENT_CONTROL_READY 1U
#define CONJET_EVENT_PROCESS_STARTED 2U
#define CONJET_EVENT_CHILD_CREATED 3U
#define CONJET_EVENT_EXEC_CONFIRMED 4U
#define CONJET_EVENT_APPLICATION_READY 5U
#define CONJET_EVENT_EXEC_FAILED 6U
#define CONJET_EVENT_PROCESS_EXITED 7U
#define CONJET_STATUS_OK 0U
#define CONJET_STATUS_FAILED 1U

static volatile sig_atomic_t shutdown_requested = 0;
static volatile sig_atomic_t child_signal_seen = 0;
static int console_fd = -1;
static int readiness_fd = -1;
static int application_ready_fd = -1;
static int trace_exec = 0;
static pid_t managed_child = -1;
static uint64_t boot_id_hash = 0;

static void put16le(uint8_t *dst, uint16_t value) {
    dst[0] = (uint8_t)(value & 0xffU);
    dst[1] = (uint8_t)((value >> 8) & 0xffU);
}

static void put32le(uint8_t *dst, uint32_t value) {
    put16le(dst, (uint16_t)(value & 0xffffU));
    put16le(dst + 2, (uint16_t)(value >> 16));
}

static void put64le(uint8_t *dst, uint64_t value) {
    put32le(dst, (uint32_t)(value & 0xffffffffULL));
    put32le(dst + 4, (uint32_t)(value >> 32));
}

static uint64_t monotonic_nanos(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static void log_line(const char *message) {
    if (console_fd >= 0) {
        (void)dprintf(console_fd, "conjet-init: %s\n", message);
    }
}

static void log_errno(const char *operation) {
    if (console_fd >= 0) {
        (void)dprintf(console_fd, "conjet-init: %s failed: %s\n", operation, strerror(errno));
    }
}

static int mkdir_if_needed(const char *path, mode_t mode) {
    if (mkdir(path, mode) == 0 || errno == EEXIST) {
        return 0;
    }
    log_errno(path);
    return -1;
}

static void mount_if_needed(const char *source, const char *target, const char *type,
                            unsigned long flags, const char *data) {
    if (mount(source, target, type, flags, data) == 0 || errno == EBUSY) {
        return;
    }
    log_errno(target);
}

static void open_console(void) {
    console_fd = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (console_fd < 0) {
        console_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    }
}

static uint64_t fnv1a64(const char *bytes, size_t count) {
    uint64_t hash = 1469598103934665603ULL;
    for (size_t index = 0; index < count; index++) {
        hash ^= (uint8_t)bytes[index];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static uint64_t load_boot_id_hash(void) {
    char buffer[128];
    int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return (uint64_t)getpid();
    }
    ssize_t bytes = read(fd, buffer, sizeof(buffer));
    (void)close(fd);
    if (bytes <= 0) {
        return (uint64_t)getpid();
    }
    return fnv1a64(buffer, (size_t)bytes);
}

static int write_all(int fd, const uint8_t *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(fd, bytes + offset, count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

static int connect_readiness(void) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        log_errno("socket(AF_VSOCK)");
        return -1;
    }

    struct sockaddr_vm address;
    memset(&address, 0, sizeof(address));
    address.svm_family = AF_VSOCK;
    address.svm_cid = VMADDR_CID_HOST;
    address.svm_port = CONJET_READY_PORT;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        log_errno("connect(readiness-vsock)");
        (void)close(fd);
        return -1;
    }
    return fd;
}

static int send_readiness(uint16_t event, uint16_t status, uint32_t error_code) {
    if (readiness_fd < 0) {
        readiness_fd = connect_readiness();
        if (readiness_fd < 0) {
            return -1;
        }
    }

    uint8_t frame[28 + 32];
    memset(frame, 0, sizeof(frame));
    put32le(frame + 0, CONJET_FRAME_MAGIC);
    put16le(frame + 4, CONJET_FRAME_VERSION);
    put16le(frame + 6, CONJET_FRAME_KIND_READINESS);
    put32le(frame + 8, 32U);
    put32le(frame + 12, 3U);
    put32le(frame + 16, CONJET_READY_PORT);
    put32le(frame + 20, VMADDR_CID_HOST);
    put32le(frame + 24, CONJET_READY_PORT);

    uint8_t *record = frame + 28;
    put32le(record + 0, CONJET_READINESS_MAGIC);
    put16le(record + 4, CONJET_READINESS_VERSION);
    put16le(record + 6, event);
    put16le(record + 8, status);
    put16le(record + 10, 0U);
    put64le(record + 12, boot_id_hash);
    put64le(record + 20, monotonic_nanos());
    put32le(record + 28, error_code);

    if (write_all(readiness_fd, frame, sizeof(frame)) != 0) {
        log_errno("write(readiness-vsock)");
        (void)close(readiness_fd);
        readiness_fd = -1;
        return -1;
    }
    return 0;
}

static void handle_signal(int signo) {
    if (signo == SIGCHLD) {
        child_signal_seen = 1;
    } else {
        shutdown_requested = 1;
    }
}

static void install_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = handle_signal;
    action.sa_flags = SA_RESTART;
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGCHLD, &action, NULL);
    (void)signal(SIGPIPE, SIG_IGN);
}

static void setup_mounts(void) {
    mkdir_if_needed("/dev", 0755);
    mount_if_needed("devtmpfs", "/dev", "devtmpfs", MS_NOSUID | MS_NOEXEC, "mode=0755");
    open_console();

    mkdir_if_needed("/proc", 0555);
    mkdir_if_needed("/sys", 0555);
    mkdir_if_needed("/run", 0755);
    mkdir_if_needed("/tmp", 01777);
    mkdir_if_needed("/run/conjet", 0755);

    mount_if_needed("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
    mount_if_needed("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
    mount_if_needed("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755,size=16m");
    mount_if_needed("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777,size=16m");
    mkdir_if_needed("/run/conjet", 0755);
}

static int hex_value(char value) {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return 10 + value - 'a';
    }
    if (value >= 'A' && value <= 'F') {
        return 10 + value - 'A';
    }
    return -1;
}

static void percent_decode(char *value) {
    char *read_cursor = value;
    char *write_cursor = value;
    while (*read_cursor != '\0') {
        if (read_cursor[0] == '%' && read_cursor[1] != '\0' && read_cursor[2] != '\0') {
            int high = hex_value(read_cursor[1]);
            int low = hex_value(read_cursor[2]);
            if (high >= 0 && low >= 0) {
                *write_cursor++ = (char)((high << 4) | low);
                read_cursor += 3;
                continue;
            }
        }
        *write_cursor++ = *read_cursor++;
    }
    *write_cursor = '\0';
}

static char *cmdline_value(const char *key) {
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return NULL;
    }
    char buffer[4096];
    ssize_t bytes = read(fd, buffer, sizeof(buffer) - 1);
    (void)close(fd);
    if (bytes <= 0) {
        return NULL;
    }
    buffer[bytes] = '\0';

    size_t key_len = strlen(key);
    char *cursor = buffer;
    while (*cursor != '\0') {
        while (isspace((unsigned char)*cursor)) {
            cursor++;
        }
        if (strncmp(cursor, key, key_len) == 0) {
            char *value = cursor + key_len;
            char *end = value;
            while (*end != '\0' && !isspace((unsigned char)*end)) {
                end++;
            }
            size_t value_len = (size_t)(end - value);
            if (value_len == 0 || value_len > 1024) {
                return NULL;
            }
            char *copy = calloc(value_len + 1, 1);
            if (copy == NULL) {
                return NULL;
            }
            memcpy(copy, value, value_len);
            percent_decode(copy);
            return copy;
        }
        while (*cursor != '\0' && !isspace((unsigned char)*cursor)) {
            cursor++;
        }
    }
    return NULL;
}

static void free_argv(char **argv, int argc) {
    if (argv == NULL) {
        return;
    }
    for (int index = 0; index < argc; index++) {
        free(argv[index]);
    }
    free(argv);
}

static char **configured_argv(int *argc_out) {
    *argc_out = 0;
    char *argc_text = cmdline_value("conjet.argc=");
    if (argc_text != NULL) {
        char *end = NULL;
        long argc_long = strtol(argc_text, &end, 10);
        int valid = end != argc_text && *end == '\0' && argc_long > 0 && argc_long <= 32;
        free(argc_text);
        if (!valid) {
            return NULL;
        }
        int argc = (int)argc_long;
        char **argv = calloc((size_t)argc + 1, sizeof(char *));
        if (argv == NULL) {
            return NULL;
        }
        for (int index = 0; index < argc; index++) {
            char key[32];
            (void)snprintf(key, sizeof(key), "conjet.arg%d=", index);
            argv[index] = cmdline_value(key);
            if (argv[index] == NULL || argv[index][0] == '\0') {
                free_argv(argv, argc);
                return NULL;
            }
        }
        argv[argc] = NULL;
        *argc_out = argc;
        return argv;
    }

    char *exec_path = cmdline_value("conjet.exec=");
    if (exec_path == NULL) {
        return NULL;
    }
    char **argv = calloc(2, sizeof(char *));
    if (argv == NULL) {
        free(exec_path);
        return NULL;
    }
    argv[0] = exec_path;
    argv[1] = NULL;
    *argc_out = 1;
    return argv;
}

static int cmdline_enabled(const char *key) {
    char *value = cmdline_value(key);
    int enabled = value != NULL && strcmp(value, "1") == 0;
    free(value);
    return enabled;
}

static pid_t wait_managed_child(int *status) {
    pid_t result;
    do {
        result = waitpid(managed_child, status, 0);
    } while (result < 0 && errno == EINTR);
    return result;
}

static void observe_application_ready(void) {
    if (application_ready_fd < 0) {
        return;
    }
    uint8_t marker = 0;
    ssize_t count = read(application_ready_fd, &marker, sizeof(marker));
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) {
        return;
    }
    (void)close(application_ready_fd);
    application_ready_fd = -1;
    if (count == 1 && marker == 1U) {
        (void)send_readiness(CONJET_EVENT_APPLICATION_READY, CONJET_STATUS_OK, 0);
    }
}

static void report_exit(int status) {
    observe_application_ready();
    managed_child = -1;
    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        (void)dprintf(console_fd, "conjet-init: child exited status=%d\n", code);
        if (trace_exec) {
            (void)send_readiness(CONJET_EVENT_PROCESS_EXITED, CONJET_STATUS_OK, (uint32_t)code);
        }
    } else if (WIFSIGNALED(status)) {
        int signal_number = WTERMSIG(status);
        (void)dprintf(console_fd, "conjet-init: child signaled signal=%d\n", signal_number);
        if (trace_exec) {
            (void)send_readiness(CONJET_EVENT_PROCESS_EXITED, CONJET_STATUS_FAILED,
                                 (uint32_t)signal_number);
        }
    }
}

static void fail_traced_child(int error_code) {
    (void)send_readiness(CONJET_EVENT_EXEC_FAILED, CONJET_STATUS_FAILED, (uint32_t)error_code);
    if (managed_child > 0) {
        (void)kill(managed_child, SIGKILL);
        int status = 0;
        if (wait_managed_child(&status) == managed_child) {
            report_exit(status);
        }
    }
}

static int confirm_traced_exec(int error_fd) {
    int status = 0;
    if (wait_managed_child(&status) != managed_child) {
        fail_traced_child(errno);
        return -1;
    }
    if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGSTOP) {
        if (ptrace(PTRACE_SETOPTIONS, managed_child, NULL,
                   (void *)(uintptr_t)(PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL)) != 0) {
            fail_traced_child(errno);
            return -1;
        }
        int deliver = 0;
        while (WIFSTOPPED(status)) {
            if (ptrace(PTRACE_CONT, managed_child, NULL, (void *)(uintptr_t)deliver) != 0 ||
                wait_managed_child(&status) != managed_child) {
                fail_traced_child(errno);
                return -1;
            }
            if (WIFSTOPPED(status) && (unsigned int)status >> 16 == PTRACE_EVENT_EXEC) {
                (void)send_readiness(CONJET_EVENT_EXEC_CONFIRMED, CONJET_STATUS_OK, 0);
                if (ptrace(PTRACE_DETACH, managed_child, NULL, NULL) != 0) {
                    log_errno("PTRACE_DETACH");
                    (void)kill(managed_child, SIGKILL);
                    if (wait_managed_child(&status) == managed_child) {
                        report_exit(status);
                    }
                    return -1;
                }
                return 0;
            }
            deliver = WIFSTOPPED(status) ? WSTOPSIG(status) : 0;
        }
    }

    if (WIFSTOPPED(status)) {
        fail_traced_child(EIO);
        return -1;
    }
    int code = 0;
    if (read(error_fd, &code, sizeof(code)) != (ssize_t)sizeof(code)) {
        code = WIFSIGNALED(status) ? EINTR : EIO;
    }
    (void)send_readiness(CONJET_EVENT_EXEC_FAILED, CONJET_STATUS_FAILED, (uint32_t)code);
    report_exit(status);
    return -1;
}

static void exec_failure(int error_fd, int code) {
    if (error_fd >= 0) {
        (void)write_all(error_fd, (const uint8_t *)&code, sizeof(code));
    }
    _exit(127);
}

static int start_configured_process(void) {
    int argc = 0;
    char **argv = configured_argv(&argc);
    if (argv == NULL) {
        return 0;
    }

    int exec_error[2] = {-1, -1};
    int ready[2] = {-1, -1};
    if (trace_exec &&
        (pipe2(exec_error, O_CLOEXEC) != 0 || pipe2(ready, O_CLOEXEC | O_NONBLOCK) != 0)) {
        int code = errno;
        if (exec_error[0] >= 0) {
            (void)close(exec_error[0]);
            (void)close(exec_error[1]);
        }
        (void)send_readiness(CONJET_EVENT_EXEC_FAILED, CONJET_STATUS_FAILED, (uint32_t)code);
        free_argv(argv, argc);
        return -1;
    }

    pid_t pid = fork();
    if (pid == 0) {
        char ready_env[64];
        char *envp[] = { "PATH=/bin:/usr/bin:/sbin:/usr/sbin", NULL, NULL };
        if (trace_exec) {
            (void)close(exec_error[0]);
            (void)close(ready[0]);
            if (fcntl(ready[1], F_SETFD, 0) != 0 ||
                ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) {
                exec_failure(exec_error[1], errno);
            }
            (void)snprintf(ready_env, sizeof(ready_env), "CONJET_READY_FD=%d", ready[1]);
            envp[1] = ready_env;
            if (raise(SIGSTOP) != 0) {
                exec_failure(exec_error[1], errno);
            }
        }
        execve(argv[0], argv, envp);
        exec_failure(exec_error[1], errno);
    }

    int code = errno;
    free_argv(argv, argc);
    if (trace_exec) {
        (void)close(exec_error[1]);
        (void)close(ready[1]);
    }
    if (pid < 0) {
        if (trace_exec) {
            (void)close(exec_error[0]);
            (void)close(ready[0]);
        }
        (void)send_readiness(trace_exec ? CONJET_EVENT_EXEC_FAILED : CONJET_EVENT_PROCESS_STARTED,
                             CONJET_STATUS_FAILED, (uint32_t)code);
        return -1;
    }

    managed_child = pid;
    if (!trace_exec) {
        (void)send_readiness(CONJET_EVENT_PROCESS_STARTED, CONJET_STATUS_OK, 0);
        return 0;
    }
    application_ready_fd = ready[0];
    (void)send_readiness(CONJET_EVENT_CHILD_CREATED, CONJET_STATUS_OK, 0);
    int result = confirm_traced_exec(exec_error[0]);
    (void)close(exec_error[0]);
    return result;
}

static void reap_children(void) {
    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid > 0) {
            if (pid == managed_child) {
                report_exit(status);
            }
            continue;
        }
        if (pid == 0 || (pid < 0 && errno == ECHILD)) {
            return;
        }
        if (pid < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

static void shutdown_child(void) {
    if (managed_child > 0) {
        (void)kill(managed_child, SIGTERM);
        for (int attempt = 0; attempt < 20; attempt++) {
            reap_children();
            if (managed_child <= 0) {
                return;
            }
            usleep(50000);
        }
        (void)kill(managed_child, SIGKILL);
        reap_children();
    }
}

// This entry runs only after the fixture execs /init with an explicit argument.
static int run_readiness_fixture(int argc, char **argv) {
    if (argc > 2 && strcmp(argv[2], "early-exit") == 0) {
        return 23;
    }
    const char *value = getenv("CONJET_READY_FD");
    if (value == NULL) {
        return 0;
    }
    char *end = NULL;
    long fd = strtol(value, &end, 10);
    if (end == value || *end != '\0' || fd < 3 || fd > INT32_MAX) {
        return 1;
    }
    const uint8_t ready = 1;
    int result = write_all((int)fd, &ready, sizeof(ready));
    (void)close((int)fd);
    return result == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--readiness-fixture") == 0) {
        return run_readiness_fixture(argc, argv);
    }
    install_signals();
    setup_mounts();
    boot_id_hash = load_boot_id_hash();
    trace_exec = cmdline_enabled("conjet.trace_exec=");
    int qa_exit = cmdline_enabled("conjet.qa_exit=");

    log_line("control plane starting");
    if (send_readiness(CONJET_EVENT_CONTROL_READY, CONJET_STATUS_OK, 0) == 0) {
        log_line("CONTROL_READY sent");
    }

    (void)start_configured_process();

    sigset_t blocked;
    sigset_t wait_mask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGCHLD);
    sigaddset(&blocked, SIGTERM);
    sigaddset(&blocked, SIGINT);
    int signals_blocked = sigprocmask(SIG_BLOCK, &blocked, &wait_mask) == 0;
    if (!signals_blocked) {
        log_errno("sigprocmask");
        shutdown_requested = 1;
    }
    while (!shutdown_requested) {
        observe_application_ready();
        if (child_signal_seen) {
            child_signal_seen = 0;
            reap_children();
        }
        if (qa_exit && managed_child < 0) {
            break;
        }
        struct pollfd readiness = { .fd = application_ready_fd, .events = POLLIN };
        if (ppoll(&readiness, 1, NULL, &wait_mask) < 0 && errno != EINTR) {
            log_errno("ppoll");
            break;
        }
    }
    if (signals_blocked) {
        (void)sigprocmask(SIG_SETMASK, &wait_mask, NULL);
    }
    log_line("shutdown requested");
    shutdown_child();
    if (application_ready_fd >= 0) {
        (void)close(application_ready_fd);
    }
    if (readiness_fd >= 0) {
        (void)close(readiness_fd);
    }
    sync();
    (void)reboot(LINUX_REBOOT_CMD_POWER_OFF);
    return 0;
}
