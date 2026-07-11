#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#ifdef CONJET_NETD_UNIT_TEST
#include <sys/socket.h>
struct sockaddr_vm {
    sa_family_t svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) - sizeof(unsigned int) - sizeof(unsigned int)];
};
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif
#ifndef VMADDR_CID_HOST
#define VMADDR_CID_HOST 2U
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
static int conjet_netd_unit_test_mount_stub(const char *source, const char *target, const char *filesystemtype, unsigned long mountflags, const void *data) {
    (void)source;
    (void)target;
    (void)filesystemtype;
    (void)mountflags;
    (void)data;
    errno = ENOSYS;
    return -1;
}
#else
#include <linux/vm_sockets.h>
#endif
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifdef CONJET_NETD_UNIT_TEST
#define mount(source, target, filesystemtype, mountflags, data) conjet_netd_unit_test_mount_stub(source, target, filesystemtype, mountflags, data)
#endif

#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif

#define CONJET_NETD_PORT 2375
#define DOCKER_UNIX_SOCKET "/var/run/docker.sock"
#define FRAME_MAGIC 0x434a4e54U
#define FRAME_VERSION 1
#define FRAME_HEADER_SIZE 20
#define FRAME_MAX_PAYLOAD (1024 * 1024)
#define CONJET_READINESS_PORT 1029
#define CONJET_VSOCK_FRAME_MAGIC 0x4356534fU
#define CONJET_VSOCK_FRAME_VERSION 1
#define CONJET_VSOCK_FRAME_KIND_READINESS 8
#define CONJET_READINESS_MAGIC 0x43524459U
#define CONJET_READINESS_VERSION 1
#define CONJET_READINESS_EVENT_CONTROL_READY 1
#define CONJET_READINESS_EVENT_PROCESS_STARTED 2
#define CONJET_READINESS_STATUS_OK 0
#define CONJET_READINESS_RECORD_SIZE 32
#define CONJET_VSOCK_FRAME_HEADER_SIZE 28
#define CONJET_SERVICE_CGROUP_PARENT "conjet-services.slice"
#define CONJET_BUILD_CGROUP_PARENT "conjet-build.slice"
#define CONJET_BUILD_API_CGROUP_PARENT "conjet-build.slice"

enum frame_type {
    FRAME_HELLO = 1,
    FRAME_HELLO_ACK = 2,
    FRAME_PING = 3,
    FRAME_PONG = 4,
    FRAME_REGISTER_TARGET = 5,
    FRAME_OPEN = 6,
    FRAME_DATA = 7,
    FRAME_FIN = 8,
    FRAME_RESET = 9,
    FRAME_UDP = 10,
    FRAME_METRICS = 11,
    FRAME_ERROR = 12,
    FRAME_WINDOW_UPDATE = 13,
    FRAME_TCP_OPEN = 14,
    FRAME_TCP_DATA = 15,
    FRAME_TCP_HALF_CLOSE = 16,
    FRAME_TCP_CLOSE = 17,
    FRAME_TCP_ERROR = 18
};

struct frame_header {
    uint32_t magic;
    uint8_t version;
    uint8_t type;
    uint16_t flags;
    uint32_t stream_id;
    uint32_t port_forward_id;
    uint32_t payload_len;
};

struct metrics {
    pthread_mutex_t lock;
    uint64_t tcp_connections;
    uint64_t udp_packets_in;
    uint64_t udp_packets_out;
    uint64_t udp_drops;
    uint64_t target_registrations;
    uint64_t target_lookup_hits;
    uint64_t target_lookup_misses;
    uint64_t tcp_binary_streams;
    uint64_t tcp_binary_errors;
};

struct target {
    uint32_t id;
    int proto;
    char host[64];
    uint16_t port;
    pthread_mutex_t io_lock;
    int udp_fd;
    struct sockaddr_storage udp_addr;
    socklen_t udp_addr_len;
    int udp_addr_ready;
    struct target *next;
};

struct client_args {
    int fd;
};

struct pump_args {
    int from;
    int to;
    int shutdown_to_on_eof;
};

struct frame_reader {
    int fd;
    const uint8_t *pending;
    size_t pending_len;
};

static struct metrics g_metrics = {
    PTHREAD_MUTEX_INITIALIZER,
    0, 0, 0, 0, 0, 0, 0, 0, 0
};
static pthread_mutex_t g_targets_lock = PTHREAD_MUTEX_INITIALIZER;
static struct target *g_targets = NULL;

static int connect_unix_socket(const char *path);
static int connect_tcp_target(const char *host, uint16_t port);

static int is_host_vsock_peer(const struct sockaddr_vm *peer, socklen_t peer_len) {
    return peer_len >= sizeof(*peer) &&
           peer->svm_family == AF_VSOCK &&
           peer->svm_cid == VMADDR_CID_HOST;
}

#ifdef CONJET_NETD_UNIT_TEST
static const char *g_conjet_netd_test_docker_socket_path = NULL;
#endif

static const char *docker_unix_socket_path(void) {
#ifdef CONJET_NETD_UNIT_TEST
    if (g_conjet_netd_test_docker_socket_path != NULL) {
        return g_conjet_netd_test_docker_socket_path;
    }
#endif
    return DOCKER_UNIX_SOCKET;
}

static void metric_inc(uint64_t *field) {
    pthread_mutex_lock(&g_metrics.lock);
    (*field)++;
    pthread_mutex_unlock(&g_metrics.lock);
}

static uint16_t read_u16_be(const uint8_t *p) {
    return ((uint16_t)p[0] << 8) | (uint16_t)p[1];
}

static uint32_t read_u32_be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void write_u16_be(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)((v >> 8) & 0xff);
    p[1] = (uint8_t)(v & 0xff);
}

static void write_u32_be(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)((v >> 24) & 0xff);
    p[1] = (uint8_t)((v >> 16) & 0xff);
    p[2] = (uint8_t)((v >> 8) & 0xff);
    p[3] = (uint8_t)(v & 0xff);
}

static void write_u16_le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
}

static void write_u32_le(uint8_t *p, uint32_t v) {
    write_u16_le(p, (uint16_t)(v & 0xffff));
    write_u16_le(p + 2, (uint16_t)((v >> 16) & 0xffff));
}

static void write_u64_le(uint8_t *p, uint64_t v) {
    write_u32_le(p, (uint32_t)(v & 0xffffffffU));
    write_u32_le(p + 4, (uint32_t)((v >> 32) & 0xffffffffU));
}

static int wait_for_fd_event(int fd, short events, int timeout_ms) {
    struct pollfd pfd = {.fd = fd, .events = events};
    while (1) {
        int rc = poll(&pfd, 1, timeout_ms);
        if (rc > 0) {
            return (pfd.revents & (events | POLLHUP | POLLERR)) != 0 ? 0 : -1;
        }
        if (rc < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
}

static ssize_t read_retry_poll(int fd, void *buf, size_t len) {
    while (1) {
        ssize_t n = read(fd, buf, len);
        if (n >= 0) {
            return n;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (wait_for_fd_event(fd, POLLIN, 5000) == 0) {
                continue;
            }
        }
        return -1;
    }
}

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = read_retry_poll(fd, p + done, len - done);
        if (n > 0) {
            done += (size_t)n;
        } else {
            return -1;
        }
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, p + done, len - done);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_for_fd_event(fd, POLLOUT, 5000) == 0) {
                continue;
            }
            return -1;
        } else {
            return -1;
        }
    }
    return 0;
}

static int write_full_poll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, p + done, len - done);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_for_fd_event(fd, POLLOUT, 5000) != 0) {
                return -1;
            }
        } else {
            return -1;
        }
    }
    return 0;
}

static uint32_t env_u32(const char *name, uint32_t fallback) {
    const char *raw = getenv(name);
    if (raw == NULL || raw[0] == '\0') {
        return fallback;
    }
    char *end = NULL;
    unsigned long value = strtoul(raw, &end, 10);
    if (end == raw || *end != '\0' || value > UINT32_MAX) {
        return fallback;
    }
    return (uint32_t)value;
}

static uint64_t boot_id_hash(void) {
    FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
    uint64_t hash = 1469598103934665603ULL;
    if (f == NULL) {
        return (uint64_t)getpid();
    }
    int ch;
    while ((ch = fgetc(f)) != EOF) {
        if (ch == '-' || ch == '\n' || ch == '\r') {
            continue;
        }
        hash ^= (uint8_t)ch;
        hash *= 1099511628211ULL;
    }
    fclose(f);
    return hash;
}

static uint64_t monotonic_time_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static int readiness_event_from_name(const char *name, uint16_t *event) {
    if (strcmp(name, "control-ready") == 0 || strcmp(name, "CONTROL_READY") == 0) {
        *event = CONJET_READINESS_EVENT_CONTROL_READY;
        return 0;
    }
    if (strcmp(name, "process-started") == 0 || strcmp(name, "PROCESS_STARTED") == 0) {
        *event = CONJET_READINESS_EVENT_PROCESS_STARTED;
        return 0;
    }
    return -1;
}

static int send_readiness_record(const char *event_name) {
    uint16_t event = 0;
    if (readiness_event_from_name(event_name, &event) != 0) {
        fprintf(stderr, "unknown readiness event: %s\n", event_name);
        return 2;
    }

    uint32_t host_cid = env_u32("CONJET_READINESS_HOST_CID", 2);
    uint32_t host_port = env_u32("CONJET_READINESS_PORT", CONJET_READINESS_PORT);
    uint8_t record[CONJET_READINESS_RECORD_SIZE];
    memset(record, 0, sizeof(record));
    write_u32_le(record, CONJET_READINESS_MAGIC);
    write_u16_le(record + 4, CONJET_READINESS_VERSION);
    write_u16_le(record + 6, event);
    write_u16_le(record + 8, CONJET_READINESS_STATUS_OK);
    write_u16_le(record + 10, 0);
    write_u64_le(record + 12, boot_id_hash());
    write_u64_le(record + 20, monotonic_time_ns());
    write_u32_le(record + 28, 0);

    uint8_t frame[CONJET_VSOCK_FRAME_HEADER_SIZE + CONJET_READINESS_RECORD_SIZE];
    memset(frame, 0, sizeof(frame));
    write_u32_le(frame, CONJET_VSOCK_FRAME_MAGIC);
    write_u16_le(frame + 4, CONJET_VSOCK_FRAME_VERSION);
    write_u16_le(frame + 6, CONJET_VSOCK_FRAME_KIND_READINESS);
    write_u32_le(frame + 8, CONJET_READINESS_RECORD_SIZE);
    write_u32_le(frame + 12, VMADDR_CID_ANY);
    write_u32_le(frame + 16, host_port);
    write_u32_le(frame + 20, host_cid);
    write_u32_le(frame + 24, host_port);
    memcpy(frame + CONJET_VSOCK_FRAME_HEADER_SIZE, record, sizeof(record));

    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("readiness socket(AF_VSOCK)");
        return 1;
    }
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = host_cid;
    addr.svm_port = host_port;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("readiness connect");
        close(fd);
        return 1;
    }
    int rc = write_full(fd, frame, sizeof(frame));
    if (rc != 0) {
        perror("readiness write");
    }
    shutdown(fd, SHUT_WR);
    close(fd);
    return rc == 0 ? 0 : 1;
}

static void set_nonblocking_fd(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

static int write_frame(int fd, uint8_t type, uint16_t flags, uint32_t stream_id, uint32_t port_forward_id, const uint8_t *payload, uint32_t payload_len) {
    uint8_t header[FRAME_HEADER_SIZE];
    write_u32_be(header, FRAME_MAGIC);
    header[4] = FRAME_VERSION;
    header[5] = type;
    write_u16_be(header + 6, flags);
    write_u32_be(header + 8, stream_id);
    write_u32_be(header + 12, port_forward_id);
    write_u32_be(header + 16, payload_len);
    if (write_full(fd, header, sizeof(header)) != 0) {
        return -1;
    }
    if (payload_len > 0 && payload != NULL) {
        return write_full(fd, payload, payload_len);
    }
    return 0;
}

static int parse_frame_header(const uint8_t *buf, struct frame_header *h) {
    h->magic = read_u32_be(buf);
    h->version = buf[4];
    h->type = buf[5];
    h->flags = read_u16_be(buf + 6);
    h->stream_id = read_u32_be(buf + 8);
    h->port_forward_id = read_u32_be(buf + 12);
    h->payload_len = read_u32_be(buf + 16);
    if (h->magic != FRAME_MAGIC || h->version != FRAME_VERSION || h->payload_len > FRAME_MAX_PAYLOAD) {
        return -1;
    }
    return 0;
}

static void close_fd(int fd) {
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

static void write_http_response(int fd, const char *status, const char *content_type, const char *body) {
    char header[512];
    size_t body_len = strlen(body);
    int n = snprintf(header, sizeof(header),
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nConnection: close\r\nContent-Length: %zu\r\n\r\n",
        status, content_type, body_len);
    if (n > 0) {
        write_full(fd, header, (size_t)n);
        write_full(fd, body, body_len);
    }
}

static void write_capabilities(int fd) {
    const char *body =
        "{\"version\":6,"
        "\"capabilities\":{\"tcp_proxy\":true,\"udp_proxy\":true,\"docker_events\":true,"
        "\"container_ip_lookup\":true,\"container_target_events\":true,\"port_probe\":true,\"proxy_metrics\":true,"
        "\"guest_echo\":true,\"guest_metrics\":true,\"binary_frames\":true,"
        "\"udp_binary_frames\":true,\"persistent_vsock\":true,"
        "\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true,"
        "\"guest_control\":true,\"bridge_engine\":\"conjet-netd-c\"},"
        "\"lazy_upstream\":true,\"docker_ready_cache\":true,"
        "\"tcp_proxy\":true,\"udp_proxy\":true,\"guest_echo\":true,\"guest_metrics\":true,"
        "\"binary_frames\":true,\"udp_binary_frames\":true,\"persistent_vsock\":true,"
        "\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true,"
        "\"guest_control\":true}\n";
    write_http_response(fd, "200 OK", "application/json", body);
}

static void write_metrics(int fd) {
    char body[1024];
    pthread_mutex_lock(&g_metrics.lock);
    snprintf(body, sizeof(body),
        "{\"bridge_engine\":\"conjet-netd-c\",\"vsock_mode\":\"persistent-binary-tcp-pool\","
        "\"tcp_mode\":\"persistent-binary-tcp-pool\",\"udp_mode\":\"persistent-binary-udp\","
        "\"tcp_connections\":%llu,\"udp_packets_in\":%llu,\"udp_packets_out\":%llu,"
        "\"udp_drops\":%llu,\"target_registrations\":%llu,"
        "\"target_lookup_cache_hits\":%llu,\"target_lookup_cache_misses\":%llu,"
        "\"tcp_binary_streams\":%llu,\"tcp_binary_errors\":%llu}\n",
        (unsigned long long)g_metrics.tcp_connections,
        (unsigned long long)g_metrics.udp_packets_in,
        (unsigned long long)g_metrics.udp_packets_out,
        (unsigned long long)g_metrics.udp_drops,
        (unsigned long long)g_metrics.target_registrations,
        (unsigned long long)g_metrics.target_lookup_hits,
        (unsigned long long)g_metrics.target_lookup_misses,
        (unsigned long long)g_metrics.tcp_binary_streams,
        (unsigned long long)g_metrics.tcp_binary_errors);
    pthread_mutex_unlock(&g_metrics.lock);
    write_http_response(fd, "200 OK", "application/json", body);
}

static int is_supported_virtiofs_mount(const char *tag, const char *target) {
    return (strcmp(tag, "conjethostusers") == 0 && strcmp(target, "/Users") == 0) ||
           (strcmp(tag, "conjethostvolumes") == 0 && strcmp(target, "/Volumes") == 0) ||
           (strcmp(tag, "conjetboot") == 0 && strcmp(target, "/mnt/conjetboot") == 0);
}

static const char *default_virtiofs_tag_for_target(const char *target) {
    if (strcmp(target, "/Users") == 0) {
        return "conjethostusers";
    }
    if (strcmp(target, "/Volumes") == 0) {
        return "conjethostvolumes";
    }
    if (strcmp(target, "/mnt/conjetboot") == 0) {
        return "conjetboot";
    }
    return NULL;
}

static int ensure_mount_directory(const char *target) {
    if (mkdir(target, 0755) == 0 || errno == EEXIST) {
        return 0;
    }
    return -1;
}

static int path_is_mountpoint(const char *target) {
    FILE *fp = fopen("/proc/self/mountinfo", "r");
    if (fp == NULL) {
        return 0;
    }
    char needle[128];
    snprintf(needle, sizeof(needle), " %s ", target);
    char line[8192];
    int found = 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strstr(line, needle) != NULL) {
            found = 1;
            break;
        }
    }
    fclose(fp);
    return found;
}

static int copy_json_string_value(const char *body, const char *key, char *out, size_t out_len) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(body, pattern);
    if (p == NULL) {
        return -1;
    }
    p = strchr(p + strlen(pattern), ':');
    if (p == NULL) {
        return -1;
    }
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
        p++;
    }
    if (*p != '"') {
        return -1;
    }
    p++;
    size_t used = 0;
    while (*p != '\0' && *p != '"') {
        if (*p == '\\' && p[1] != '\0') {
            p++;
        }
        if (used + 1 >= out_len) {
            return -1;
        }
        out[used++] = *p++;
    }
    if (*p != '"') {
        return -1;
    }
    out[used] = '\0';
    return used > 0 ? 0 : -1;
}

static int parse_content_length_header(const uint8_t *headers, size_t headers_len, size_t *out) {
    if (headers_len >= 4096) {
        return -1;
    }
    char text[4096];
    memcpy(text, headers, headers_len);
    text[headers_len] = '\0';

    char *p = strcasestr(text, "\nContent-Length:");
    if (p == NULL) {
        return -1;
    }
    p = strchr(p, ':');
    if (p == NULL) {
        return -1;
    }
    p++;
    while (*p == ' ' || *p == '\t') {
        p++;
    }

    errno = 0;
    char *end = NULL;
    unsigned long value = strtoul(p, &end, 10);
    if (errno != 0 || end == p) {
        return -1;
    }
    *out = (size_t)value;
    return 0;
}

static int header_line_is_content_length(const uint8_t *line, size_t len) {
    const char prefix[] = "Content-Length:";
    return len >= sizeof(prefix) - 1 && strncasecmp((const char *)line, prefix, sizeof(prefix) - 1) == 0;
}

static int header_line_is_connection(const uint8_t *line, size_t len) {
    const char prefix[] = "Connection:";
    return len >= sizeof(prefix) - 1 && strncasecmp((const char *)line, prefix, sizeof(prefix) - 1) == 0;
}

static int docker_request_is_container_create(const uint8_t *request, size_t request_len) {
    const uint8_t *line_end = memmem(request, request_len, "\r\n", 2);
    if (line_end == NULL) {
        return 0;
    }
    size_t line_len = (size_t)(line_end - request);
    if (line_len < sizeof("POST /containers/create HTTP/1.1") - 1 ||
        memcmp(request, "POST ", 5) != 0) {
        return 0;
    }
    return memmem(request, line_len, "/containers/create", sizeof("/containers/create") - 1) != NULL;
}

static int docker_request_target_is_build_path(const uint8_t *target, size_t target_len) {
    const uint8_t *query = memchr(target, '?', target_len);
    size_t path_len = query == NULL ? target_len : (size_t)(query - target);
    if (path_len == sizeof("/build") - 1 &&
        memcmp(target, "/build", sizeof("/build") - 1) == 0) {
        return 1;
    }

    if (path_len <= sizeof("/v/build") - 1 ||
        target[0] != '/' ||
        target[1] != 'v') {
        return 0;
    }

    size_t index = 2;
    while (index < path_len &&
           ((target[index] >= '0' && target[index] <= '9') || target[index] == '.')) {
        index++;
    }
    return index > 2 &&
           path_len - index == sizeof("/build") - 1 &&
           memcmp(target + index, "/build", sizeof("/build") - 1) == 0;
}

static int docker_build_request_has_cgroup_parent(const uint8_t *target, size_t target_len) {
    const uint8_t *query = memchr(target, '?', target_len);
    if (query == NULL) {
        return 0;
    }
    query++;
    size_t query_len = target_len - (size_t)(query - target);
    const uint8_t key[] = "cgroupparent=";
    const uint8_t *cursor = query;
    const uint8_t *end = query + query_len;
    while (cursor < end) {
        const uint8_t *next = memchr(cursor, '&', (size_t)(end - cursor));
        size_t item_len = next == NULL ? (size_t)(end - cursor) : (size_t)(next - cursor);
        if (item_len >= sizeof(key) - 1 &&
            memcmp(cursor, key, sizeof(key) - 1) == 0) {
            return 1;
        }
        if (next == NULL) {
            break;
        }
        cursor = next + 1;
    }
    return 0;
}

static int rewrite_docker_build_request_cgroup_parent(const uint8_t *request, size_t request_len, uint8_t **out, size_t *out_len) {
    const uint8_t *line_end = memmem(request, request_len, "\r\n", 2);
    if (line_end == NULL) {
        return 0;
    }
    size_t line_len = (size_t)(line_end - request);
    if (line_len < sizeof("POST /build HTTP/1.1") - 1 ||
        memcmp(request, "POST ", 5) != 0) {
        return 0;
    }

    const uint8_t *target = request + 5;
    const uint8_t *target_end = memchr(target, ' ', line_len - 5);
    if (target_end == NULL) {
        return 0;
    }
    size_t target_len = (size_t)(target_end - target);
    if (!docker_request_target_is_build_path(target, target_len) ||
        docker_build_request_has_cgroup_parent(target, target_len)) {
        return 0;
    }

    const char *separator = memchr(target, '?', target_len) == NULL ? "?" : "&";
    char addition[96];
    int addition_len = snprintf(
        addition,
        sizeof(addition),
        "%scgroupparent=%s",
        separator,
        CONJET_BUILD_API_CGROUP_PARENT
    );
    if (addition_len <= 0 || (size_t)addition_len >= sizeof(addition)) {
        return -1;
    }

    size_t insert_at = (size_t)(target_end - request);
    size_t total_len = request_len + (size_t)addition_len;
    uint8_t *rewritten = malloc(total_len);
    if (rewritten == NULL) {
        return -1;
    }
    memcpy(rewritten, request, insert_at);
    memcpy(rewritten + insert_at, addition, (size_t)addition_len);
    memcpy(rewritten + insert_at + (size_t)addition_len, request + insert_at, request_len - insert_at);
    *out = rewritten;
    *out_len = total_len;
    return 1;
}

static int docker_request_is_upgraded_stream(const uint8_t *request, size_t request_len) {
    const uint8_t *header_end = memmem(request, request_len, "\r\n\r\n", 4);
    size_t headers_len = header_end == NULL ? request_len : (size_t)(header_end - request);
    const uint8_t *line_end = memmem(request, request_len, "\r\n", 2);
    size_t line_len = line_end == NULL ? headers_len : (size_t)(line_end - request);

    if (memmem(request, line_len, "/grpc", sizeof("/grpc") - 1) != NULL) {
        return 1;
    }
    return memmem(request, headers_len, "Connection: Upgrade", sizeof("Connection: Upgrade") - 1) != NULL ||
           memmem(request, headers_len, "connection: Upgrade", sizeof("connection: Upgrade") - 1) != NULL ||
           memmem(request, headers_len, "Upgrade: h2c", sizeof("Upgrade: h2c") - 1) != NULL ||
           memmem(request, headers_len, "upgrade: h2c", sizeof("upgrade: h2c") - 1) != NULL;
}

static int docker_request_is_streaming_http(const uint8_t *request, size_t request_len) {
    const uint8_t *line_end = memmem(request, request_len, "\r\n", 2);
    size_t line_len = line_end == NULL ? request_len : (size_t)(line_end - request);

    if (memmem(request, line_len, "/events", sizeof("/events") - 1) != NULL) {
        return 1;
    }
    if (memmem(request, line_len, "/stats", sizeof("/stats") - 1) != NULL &&
        memmem(request, line_len, "stream=0", sizeof("stream=0") - 1) == NULL &&
        memmem(request, line_len, "stream=false", sizeof("stream=false") - 1) == NULL) {
        return 1;
    }
    if (memmem(request, line_len, "/logs", sizeof("/logs") - 1) != NULL &&
        (memmem(request, line_len, "follow=1", sizeof("follow=1") - 1) != NULL ||
         memmem(request, line_len, "follow=true", sizeof("follow=true") - 1) != NULL)) {
        return 1;
    }
    return 0;
}

static int docker_http_request_extent(const uint8_t *request, size_t request_len, size_t *out_needed) {
    const uint8_t marker[] = {'\r', '\n', '\r', '\n'};
    const uint8_t *header_end = memmem(request, request_len, marker, sizeof(marker));
    if (header_end == NULL) {
        return 0;
    }
    size_t headers_len = (size_t)(header_end - request);
    if (memmem(request, headers_len, "Transfer-Encoding:", sizeof("Transfer-Encoding:") - 1) != NULL) {
        return 0;
    }

    size_t body_offset = (size_t)(header_end + sizeof(marker) - request);
    size_t content_length = 0;
    if (parse_content_length_header(request, headers_len, &content_length) != 0) {
        content_length = 0;
    }
    if (content_length > SIZE_MAX - body_offset) {
        return -1;
    }
    *out_needed = body_offset + content_length;
    return 1;
}

#ifdef CONJET_NETD_UNIT_TEST
static int docker_http_request_is_complete(const uint8_t *request, size_t request_len) {
    size_t needed = 0;
    int rc = docker_http_request_extent(request, request_len, &needed);
    return rc > 0 && request_len >= needed;
}
#endif

#define DOCKER_MAX_INITIAL_REQUEST (4U * 1024U * 1024U)
#define DOCKER_MAX_REQUEST_HEADERS (128U * 1024U)

/*
 * Assemble enough of one Docker HTTP request to make the relay mode decision
 * independent of socket/vsock read boundaries. Requests with a large fixed
 * body, such as Docker archive uploads, are deliberately not buffered in
 * full: return their header and already-read prefix so the duplex relay can
 * stream the remaining bytes without a size ceiling.
 */
static int receive_initial_docker_request(
    int fd,
    const uint8_t *first,
    size_t first_len,
    uint8_t **out,
    size_t *out_len,
    int *out_complete
) {
    if (first_len == 0 || first_len > DOCKER_MAX_INITIAL_REQUEST) {
        return -1;
    }

    size_t capacity = first_len < 8192 ? 8192 : first_len;
    uint8_t *buffer = malloc(capacity);
    if (buffer == NULL) {
        return -1;
    }
    memcpy(buffer, first, first_len);
    size_t used = first_len;

    for (;;) {
        size_t needed = 0;
        int extent_rc = docker_http_request_extent(buffer, used, &needed);
        if (extent_rc < 0) {
            free(buffer);
            return -1;
        }

        if (extent_rc > 0 && needed > DOCKER_MAX_INITIAL_REQUEST) {
            *out = buffer;
            *out_len = used;
            *out_complete = 0;
            return 0;
        }

        if (extent_rc > 0) {
            if (needed > capacity) {
                uint8_t *grown = realloc(buffer, needed);
                if (grown == NULL) {
                    free(buffer);
                    return -1;
                }
                buffer = grown;
            }
            while (used < needed) {
                ssize_t n = read(fd, buffer + used, needed - used);
                if (n > 0) {
                    used += (size_t)n;
                } else if (n < 0 && errno == EINTR) {
                    continue;
                } else {
                    free(buffer);
                    return -1;
                }
            }
            *out = buffer;
            *out_len = used;
            *out_complete = 1;
            return 0;
        }

        /* Header complete but framing is unsupported by extent parser. */
        if (memmem(buffer, used, "\r\n\r\n", 4) != NULL) {
            *out = buffer;
            *out_len = used;
            *out_complete = 0;
            return 0;
        }

        if (used >= DOCKER_MAX_REQUEST_HEADERS) {
            free(buffer);
            return -1;
        }
        if (used == capacity) {
            size_t next = capacity * 2;
            if (next > DOCKER_MAX_REQUEST_HEADERS) {
                next = DOCKER_MAX_REQUEST_HEADERS;
            }
            uint8_t *grown = realloc(buffer, next);
            if (grown == NULL) {
                free(buffer);
                return -1;
            }
            buffer = grown;
            capacity = next;
        }

        ssize_t n = read(fd, buffer + used, capacity - used);
        if (n > 0) {
            used += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            free(buffer);
            return -1;
        }
    }
}

static int body_contains_marker(const uint8_t *body, size_t body_len, const char *marker) {
    return memmem(body, body_len, marker, strlen(marker)) != NULL;
}

static int container_create_body_is_build_related(const uint8_t *body, size_t body_len) {
    return body_contains_marker(body, body_len, "moby.buildkit") ||
           body_contains_marker(body, body_len, "moby/buildkit") ||
           body_contains_marker(body, body_len, "moby\\/buildkit") ||
           body_contains_marker(body, body_len, "buildx_buildkit") ||
           body_contains_marker(body, body_len, "buildkitd");
}

static const uint8_t *skip_json_ws(const uint8_t *cursor, const uint8_t *end) {
    while (cursor < end && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')) {
        cursor++;
    }
    return cursor;
}

static int rewrite_container_create_body(const uint8_t *body, size_t body_len, uint8_t **out, size_t *out_len) {
    const char cgroup_key[] = "\"CgroupParent\"";
    const char host_config_key[] = "\"HostConfig\"";
    const int build_related = container_create_body_is_build_related(body, body_len);
    const char *cgroup_parent = build_related ? CONJET_BUILD_CGROUP_PARENT : CONJET_SERVICE_CGROUP_PARENT;
    char service_value[96];
    char service_insert[128];
    char host_config_insert[160];
    int cgroup_value_len = snprintf(service_value, sizeof(service_value), "\"%s\"", cgroup_parent);
    int cgroup_insert_len = snprintf(service_insert, sizeof(service_insert), "\"CgroupParent\":\"%s\"", cgroup_parent);
    int host_insert_len = snprintf(host_config_insert, sizeof(host_config_insert), "\"HostConfig\":{\"CgroupParent\":\"%s\"}", cgroup_parent);
    if (cgroup_value_len <= 0 || (size_t)cgroup_value_len >= sizeof(service_value) ||
        cgroup_insert_len <= 0 || (size_t)cgroup_insert_len >= sizeof(service_insert) ||
        host_insert_len <= 0 || (size_t)host_insert_len >= sizeof(host_config_insert)) {
        return -1;
    }

    const uint8_t *existing_cgroup = memmem(body, body_len, cgroup_key, sizeof(cgroup_key) - 1);
    if (existing_cgroup != NULL) {
        const uint8_t *cursor = existing_cgroup + sizeof(cgroup_key) - 1;
        const uint8_t *end = body + body_len;
        cursor = skip_json_ws(cursor, end);
        if (cursor >= end || *cursor != ':') {
            return 0;
        }
        cursor = skip_json_ws(cursor + 1, end);
        if (cursor + 1 >= end || cursor[0] != '"' || cursor[1] != '"') {
            return 0;
        }

        size_t value_start = (size_t)(cursor - body);
        size_t value_len = 2;
        size_t replacement_len = (size_t)cgroup_value_len;
        uint8_t *rewritten = malloc(body_len - value_len + replacement_len);
        if (rewritten == NULL) {
            return -1;
        }
        memcpy(rewritten, body, value_start);
        memcpy(rewritten + value_start, service_value, replacement_len);
        memcpy(
            rewritten + value_start + replacement_len,
            body + value_start + value_len,
            body_len - value_start - value_len
        );
        *out = rewritten;
        *out_len = body_len - value_len + replacement_len;
        return 1;
    }

    const uint8_t *host_config = memmem(body, body_len, host_config_key, sizeof(host_config_key) - 1);
    if (host_config != NULL) {
        const uint8_t *cursor = host_config + sizeof(host_config_key) - 1;
        const uint8_t *end = body + body_len;
        while (cursor < end && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')) {
            cursor++;
        }
        if (cursor >= end || *cursor != ':') {
            return 0;
        }
        cursor++;
        while (cursor < end && (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')) {
            cursor++;
        }
        if (cursor >= end || *cursor != '{') {
            return 0;
        }
        size_t insert_at = (size_t)(cursor + 1 - body);
        const uint8_t *first_host_config_field = skip_json_ws(cursor + 1, end);
        int host_config_empty = first_host_config_field < end && *first_host_config_field == '}';
        size_t service_insert_len = (size_t)cgroup_insert_len;
        size_t insert_len = service_insert_len + (host_config_empty ? 0 : 1);
        uint8_t *rewritten = malloc(body_len + insert_len);
        if (rewritten == NULL) {
            return -1;
        }
        memcpy(rewritten, body, insert_at);
        memcpy(rewritten + insert_at, service_insert, service_insert_len);
        if (!host_config_empty) {
            rewritten[insert_at + service_insert_len] = ',';
        }
        memcpy(rewritten + insert_at + insert_len, body + insert_at, body_len - insert_at);
        *out = rewritten;
        *out_len = body_len + insert_len;
        return 1;
    }

    const uint8_t *end = body + body_len;
    while (end > body && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
        end--;
    }
    if (end <= body || end[-1] != '}') {
        return 0;
    }
    const uint8_t *start = skip_json_ws(body, end);
    if (start >= end || *start != '{') {
        return 0;
    }
    const uint8_t *first_top_level_field = skip_json_ws(start + 1, end - 1);
    int body_empty = first_top_level_field >= end - 1;
    char host_config_insert_with_comma[sizeof(host_config_insert) + 1];
    const char *insert_text = host_config_insert;
    if (!body_empty) {
        host_config_insert_with_comma[0] = ',';
        memcpy(host_config_insert_with_comma + 1, host_config_insert, sizeof(host_config_insert));
        insert_text = host_config_insert_with_comma;
    }
    size_t insert_at = (size_t)(end - 1 - body);
    size_t insert_len = strlen(insert_text);
    uint8_t *rewritten = malloc(body_len + insert_len);
    if (rewritten == NULL) {
        return -1;
    }
    memcpy(rewritten, body, insert_at);
    memcpy(rewritten + insert_at, insert_text, insert_len);
    memcpy(rewritten + insert_at + insert_len, body + insert_at, body_len - insert_at);
    *out = rewritten;
    *out_len = body_len + insert_len;
    return 1;
}

static int rewrite_container_create_request(const uint8_t *request, size_t request_len, uint8_t **out, size_t *out_len) {
    if (!docker_request_is_container_create(request, request_len)) {
        return 0;
    }

    const uint8_t marker[] = {'\r', '\n', '\r', '\n'};
    const uint8_t *header_end = memmem(request, request_len, marker, sizeof(marker));
    if (header_end == NULL) {
        return 0;
    }
    size_t headers_len = (size_t)(header_end - request);
    if (memmem(request, headers_len, "Transfer-Encoding:", sizeof("Transfer-Encoding:") - 1) != NULL) {
        return 0;
    }

    size_t content_length = 0;
    if (parse_content_length_header(request, headers_len, &content_length) != 0) {
        return 0;
    }
    const uint8_t *body = header_end + sizeof(marker);
    if ((size_t)(request + request_len - body) < content_length) {
        return 0;
    }

    uint8_t *rewritten_body = NULL;
    size_t rewritten_body_len = 0;
    int body_status = rewrite_container_create_body(body, content_length, &rewritten_body, &rewritten_body_len);
    if (body_status <= 0) {
        return body_status;
    }

    char content_length_line[64];
    int content_length_line_len = snprintf(
        content_length_line,
        sizeof(content_length_line),
        "Content-Length: %zu\r\n\r\n",
        rewritten_body_len
    );
    if (content_length_line_len <= 0 || content_length_line_len >= (int)sizeof(content_length_line)) {
        free(rewritten_body);
        return -1;
    }

    size_t header_without_content_length = 0;
    const uint8_t *line = request;
    const uint8_t *headers_end = request + headers_len;
    while (line < headers_end) {
        const uint8_t *next = memmem(line, (size_t)(headers_end - line), "\r\n", 2);
        size_t line_len = next == NULL ? (size_t)(headers_end - line) : (size_t)(next - line);
        if (!header_line_is_content_length(line, line_len)) {
            header_without_content_length += line_len + 2;
        }
        if (next == NULL) {
            break;
        }
        line = next + 2;
    }

    size_t suffix_len = request_len - ((size_t)(body - request) + content_length);
    size_t total_len = header_without_content_length + (size_t)content_length_line_len + rewritten_body_len + suffix_len;
    uint8_t *rewritten = malloc(total_len);
    if (rewritten == NULL) {
        free(rewritten_body);
        return -1;
    }

    size_t used = 0;
    line = request;
    while (line < headers_end) {
        const uint8_t *next = memmem(line, (size_t)(headers_end - line), "\r\n", 2);
        size_t line_len = next == NULL ? (size_t)(headers_end - line) : (size_t)(next - line);
        if (!header_line_is_content_length(line, line_len)) {
            memcpy(rewritten + used, line, line_len);
            used += line_len;
            memcpy(rewritten + used, "\r\n", 2);
            used += 2;
        }
        if (next == NULL) {
            break;
        }
        line = next + 2;
    }
    memcpy(rewritten + used, content_length_line, (size_t)content_length_line_len);
    used += (size_t)content_length_line_len;
    memcpy(rewritten + used, rewritten_body, rewritten_body_len);
    used += rewritten_body_len;
    if (suffix_len > 0) {
        memcpy(rewritten + used, body + content_length, suffix_len);
        used += suffix_len;
    }
    free(rewritten_body);
    *out = rewritten;
    *out_len = used;
    return 1;
}

static int rewrite_http_request_connection_close(const uint8_t *request, size_t request_len, uint8_t **out, size_t *out_len) {
    const uint8_t marker[] = {'\r', '\n', '\r', '\n'};
    const uint8_t *header_end = memmem(request, request_len, marker, sizeof(marker));
    if (header_end == NULL) {
        return 0;
    }

    size_t headers_len = (size_t)(header_end - request);
    size_t body_offset = headers_len + sizeof(marker);
    size_t kept_headers_len = 0;
    int changed = 0;
    const uint8_t *line = request;
    const uint8_t *headers_end = request + headers_len;
    while (line < headers_end) {
        const uint8_t *next = memmem(line, (size_t)(headers_end - line), "\r\n", 2);
        size_t line_len = next == NULL ? (size_t)(headers_end - line) : (size_t)(next - line);
        if (header_line_is_connection(line, line_len)) {
            changed = 1;
        } else {
            kept_headers_len += line_len + 2;
        }
        if (next == NULL) {
            break;
        }
        line = next + 2;
    }

    static const char close_header[] = "Connection: close\r\n\r\n";
    size_t body_len = request_len - body_offset;
    size_t total_len = kept_headers_len + sizeof(close_header) - 1 + body_len;
    uint8_t *rewritten = malloc(total_len);
    if (rewritten == NULL) {
        return -1;
    }

    size_t used = 0;
    line = request;
    while (line < headers_end) {
        const uint8_t *next = memmem(line, (size_t)(headers_end - line), "\r\n", 2);
        size_t line_len = next == NULL ? (size_t)(headers_end - line) : (size_t)(next - line);
        if (!header_line_is_connection(line, line_len)) {
            memcpy(rewritten + used, line, line_len);
            used += line_len;
            memcpy(rewritten + used, "\r\n", 2);
            used += 2;
        }
        if (next == NULL) {
            break;
        }
        line = next + 2;
    }
    memcpy(rewritten + used, close_header, sizeof(close_header) - 1);
    used += sizeof(close_header) - 1;
    if (body_len > 0) {
        memcpy(rewritten + used, request + body_offset, body_len);
        used += body_len;
    }

    *out = rewritten;
    *out_len = used;
    return changed ? 1 : 1;
}

static void write_control_ping(int client) {
    write_http_response(client, "200 OK", "application/json",
        "{\"ok\":true,\"bridge_engine\":\"conjet-netd-c\",\"control_version\":1}\n");
    close_fd(client);
}

static void write_control_mounts(int client) {
    char body[512];
    snprintf(body, sizeof(body),
        "{\"mounts\":[{\"target\":\"/Users\",\"tag\":\"conjethostusers\",\"mounted\":%s},"
        "{\"target\":\"/Volumes\",\"tag\":\"conjethostvolumes\",\"mounted\":%s},"
        "{\"target\":\"/mnt/conjetboot\",\"tag\":\"conjetboot\",\"mounted\":%s}]}\n",
        path_is_mountpoint("/Users") ? "true" : "false",
        path_is_mountpoint("/Volumes") ? "true" : "false",
        path_is_mountpoint("/mnt/conjetboot") ? "true" : "false");
    write_http_response(client, "200 OK", "application/json", body);
    close_fd(client);
}

static void write_control_mount_virtiofs(int client, const uint8_t *first, ssize_t first_len) {
    const uint8_t marker[] = {'\r', '\n', '\r', '\n'};
    const uint8_t *header_end = memmem(first, (size_t)first_len, marker, sizeof(marker));
    if (header_end == NULL) {
        write_http_response(client, "400 Bad Request", "application/json", "{\"error\":\"missing request body\"}\n");
        close_fd(client);
        return;
    }

    size_t content_length = 0;
    if (parse_content_length_header(first, (size_t)(header_end - first), &content_length) != 0) {
        write_http_response(client, "411 Length Required", "application/json", "{\"error\":\"invalid content length\"}\n");
        close_fd(client);
        return;
    }
    if (content_length == 0 || content_length >= 512) {
        write_http_response(client, "413 Payload Too Large", "application/json", "{\"error\":\"request body too large\"}\n");
        close_fd(client);
        return;
    }

    const uint8_t *body_start = header_end + sizeof(marker);
    size_t body_len = (size_t)(first + first_len - body_start);
    if (body_len > content_length) {
        body_len = content_length;
    }

    char body[512];
    memcpy(body, body_start, body_len);
    if (body_len < content_length &&
        read_full(client, body + body_len, content_length - body_len) != 0) {
        write_http_response(client, "400 Bad Request", "application/json", "{\"error\":\"truncated request body\"}\n");
        close_fd(client);
        return;
    }
    body[content_length] = '\0';

    char target[64] = "";
    char tag[64] = "";
    if (copy_json_string_value(body, "target", target, sizeof(target)) != 0) {
        write_http_response(client, "400 Bad Request", "application/json", "{\"error\":\"missing target\"}\n");
        close_fd(client);
        return;
    }
    if (copy_json_string_value(body, "tag", tag, sizeof(tag)) != 0) {
        const char *default_tag = default_virtiofs_tag_for_target(target);
        if (default_tag == NULL) {
            write_http_response(client, "400 Bad Request", "application/json", "{\"error\":\"unsupported target\"}\n");
            close_fd(client);
            return;
        }
        snprintf(tag, sizeof(tag), "%s", default_tag);
    }

    if (!is_supported_virtiofs_mount(tag, target)) {
        write_http_response(client, "403 Forbidden", "application/json", "{\"error\":\"unsupported virtiofs mount\"}\n");
        close_fd(client);
        return;
    }
    if (ensure_mount_directory(target) != 0) {
        char error_body[256];
        snprintf(error_body, sizeof(error_body),
            "{\"mounted\":false,\"target\":\"%s\",\"tag\":\"%s\",\"error\":\"mkdir failed: %s\"}\n",
            target, tag, strerror(errno));
        write_http_response(client, "500 Internal Server Error", "application/json", error_body);
        close_fd(client);
        return;
    }

    int already_mounted = path_is_mountpoint(target);
    if (!already_mounted && mount(tag, target, "virtiofs", 0, NULL) != 0) {
        char error_body[256];
        snprintf(error_body, sizeof(error_body),
            "{\"mounted\":false,\"already_mounted\":false,\"target\":\"%s\",\"tag\":\"%s\",\"error\":\"mount failed: %s\"}\n",
            target, tag, strerror(errno));
        write_http_response(client, "503 Service Unavailable", "application/json", error_body);
        close_fd(client);
        return;
    }

    int mounted = path_is_mountpoint(target);
    char ok_body[256];
    snprintf(ok_body, sizeof(ok_body),
        "{\"mounted\":%s,\"already_mounted\":%s,\"target\":\"%s\",\"tag\":\"%s\"}\n",
        mounted ? "true" : "false",
        already_mounted ? "true" : "false",
        target,
        tag);
    write_http_response(client, mounted ? "200 OK" : "503 Service Unavailable", "application/json", ok_body);
    close_fd(client);
}

static int decode_http_chunked_body_in_place(char *body, size_t *body_len) {
    char *readp = body;
    char *writep = body;
    char *end = body + *body_len;

    while (readp < end) {
        char *line_end = NULL;
        for (char *p = readp; p + 1 < end; p++) {
            if (p[0] == '\r' && p[1] == '\n') {
                line_end = p;
                break;
            }
        }
        if (line_end == NULL) {
            return -1;
        }

        char saved = *line_end;
        *line_end = '\0';
        char *parse_end = NULL;
        errno = 0;
        unsigned long chunk_len = strtoul(readp, &parse_end, 16);
        *line_end = saved;
        if (errno != 0 || parse_end == readp) {
            return -1;
        }

        readp = line_end + 2;
        if (chunk_len == 0) {
            *body_len = (size_t)(writep - body);
            return 0;
        }
        if (chunk_len > (unsigned long)SIZE_MAX) {
            return -1;
        }
        size_t chunk_size = (size_t)chunk_len;
        size_t remaining = (size_t)(end - readp);
        if (chunk_size > remaining || remaining - chunk_size < 2) {
            return -1;
        }
        memmove(writep, readp, chunk_size);
        writep += chunk_size;
        readp += chunk_size;
        if ((size_t)(end - readp) < 2 || readp[0] != '\r' || readp[1] != '\n') {
            return -1;
        }
        readp += 2;
    }
    return -1;
}

static void write_container_targets(int client) {
    int upstream = connect_unix_socket(docker_unix_socket_path());
    if (upstream < 0) {
        write_http_response(client, "503 Service Unavailable", "text/plain", "Conjet guest bridge could not connect to Docker\n");
        close_fd(client);
        return;
    }

    const char *request =
        "GET /containers/json?all=false&size=false HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Connection: close\r\n"
        "\r\n";
    if (write_full(upstream, request, strlen(request)) != 0) {
        close_fd(upstream);
        close_fd(client);
        return;
    }
    shutdown(upstream, SHUT_WR);

    uint8_t buf[65536];
    while (1) {
        ssize_t n = read(upstream, buf, sizeof(buf));
        if (n > 0) {
            if (write_full(client, buf, (size_t)n) != 0) {
                break;
            }
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close_fd(upstream);
    close_fd(client);
}

static ssize_t fetch_container_targets_body(char *out, size_t out_len) {
    int upstream = connect_unix_socket(docker_unix_socket_path());
    if (upstream < 0) {
        return -1;
    }
    const char *request =
        "GET /containers/json?all=false&size=false HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Connection: close\r\n"
        "\r\n";
    if (write_full(upstream, request, strlen(request)) != 0) {
        close_fd(upstream);
        return -1;
    }
    shutdown(upstream, SHUT_WR);

    char response[65536];
    size_t used = 0;
    while (used < sizeof(response) - 1) {
        ssize_t n = read(upstream, response + used, sizeof(response) - 1 - used);
        if (n > 0) {
            used += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close_fd(upstream);
    response[used] = '\0';

    char *body = strstr(response, "\r\n\r\n");
    if (body == NULL) {
        return -1;
    }
    char *headers = response;
    body += 4;
    size_t body_len = used - (size_t)(body - response);
    if (strcasestr(headers, "Transfer-Encoding: chunked") != NULL) {
        if (decode_http_chunked_body_in_place(body, &body_len) != 0) {
            return -1;
        }
    }
    if (body_len + 2 > out_len) {
        body_len = out_len > 2 ? out_len - 2 : 0;
    }
    if (body_len == 0) {
        return -1;
    }
    memcpy(out, body, body_len);
    while (body_len > 0 && (out[body_len - 1] == '\n' || out[body_len - 1] == '\r' || out[body_len - 1] == ' ' || out[body_len - 1] == '\t')) {
        body_len--;
    }
    out[body_len++] = '\n';
    out[body_len] = '\0';
    return (ssize_t)body_len;
}

struct container_targets_snapshot_cache {
    int has_snapshot;
    size_t body_len;
    char body[65536];
};

static int emit_container_targets_snapshot_if_changed(int client, struct container_targets_snapshot_cache *cache) {
    char body[65536];
    ssize_t n = fetch_container_targets_body(body, sizeof(body));
    if (n <= 0) {
        return -1;
    }
    size_t body_len = (size_t)n;
    if (cache != NULL && cache->has_snapshot && cache->body_len == body_len && memcmp(cache->body, body, body_len) == 0) {
        return 0;
    }
    if (write_full(client, body, body_len) != 0) {
        return -1;
    }
    if (cache != NULL) {
        cache->has_snapshot = 1;
        cache->body_len = body_len;
        memcpy(cache->body, body, body_len);
    }
    return 1;
}

static int buffer_contains_literal(const char *haystack, size_t haystack_len, const char *needle) {
    size_t needle_len = strlen(needle);
    if (needle_len == 0 || needle_len > haystack_len) {
        return 0;
    }
    for (size_t i = 0; i + needle_len <= haystack_len; i++) {
        if (memcmp(haystack + i, needle, needle_len) == 0) {
            return 1;
        }
    }
    return 0;
}

static int docker_event_line_should_refresh_targets(const char *line, size_t line_len) {
    if (line_len == 0) {
        return 0;
    }
    int target_type =
        buffer_contains_literal(line, line_len, "\"Type\":\"container\"") ||
        buffer_contains_literal(line, line_len, "\"type\":\"container\"") ||
        buffer_contains_literal(line, line_len, "\"Type\":\"network\"") ||
        buffer_contains_literal(line, line_len, "\"type\":\"network\"");
    if (!target_type) {
        return 0;
    }

    static const char *actions[] = {
        "create",
        "start",
        "stop",
        "die",
        "destroy",
        "connect",
        "disconnect",
        "network_connect",
        "network_disconnect"
    };
    char action_needle[64];
    char status_needle[64];
    for (size_t i = 0; i < sizeof(actions) / sizeof(actions[0]); i++) {
        snprintf(action_needle, sizeof(action_needle), "\"Action\":\"%s\"", actions[i]);
        snprintf(status_needle, sizeof(status_needle), "\"status\":\"%s\"", actions[i]);
        if (buffer_contains_literal(line, line_len, action_needle) ||
            buffer_contains_literal(line, line_len, status_needle)) {
            return 1;
        }
    }
    return 0;
}

struct docker_event_line_buffer {
    char data[65536];
    size_t used;
};

static int process_docker_event_payload(
    int client,
    struct container_targets_snapshot_cache *cache,
    struct docker_event_line_buffer *line_buffer,
    const char *payload,
    size_t payload_len
) {
    for (size_t i = 0; i < payload_len; i++) {
        if (line_buffer->used >= sizeof(line_buffer->data) - 1) {
            line_buffer->used = 0;
        }
        line_buffer->data[line_buffer->used++] = payload[i];
        if (payload[i] != '\n') {
            continue;
        }

        size_t line_len = line_buffer->used;
        while (line_len > 0 && (line_buffer->data[line_len - 1] == '\n' || line_buffer->data[line_len - 1] == '\r')) {
            line_len--;
        }
        if (docker_event_line_should_refresh_targets(line_buffer->data, line_len)) {
            if (emit_container_targets_snapshot_if_changed(client, cache) < 0) {
                return -1;
            }
        }
        line_buffer->used = 0;
    }
    return 0;
}

static int process_docker_chunked_event_stream(
    int client,
    struct container_targets_snapshot_cache *cache,
    struct docker_event_line_buffer *line_buffer,
    char *stream,
    size_t *stream_used,
    size_t *chunk_remaining
) {
    while (*stream_used > 0) {
        if (*chunk_remaining == 0) {
            char *line_end = NULL;
            for (size_t i = 1; i < *stream_used; i++) {
                if (stream[i - 1] == '\r' && stream[i] == '\n') {
                    line_end = stream + i - 1;
                    break;
                }
            }
            if (line_end == NULL) {
                return 0;
            }

            char saved = *line_end;
            *line_end = '\0';
            char *parse_end = NULL;
            errno = 0;
            unsigned long chunk_len = strtoul(stream, &parse_end, 16);
            *line_end = saved;
            if (errno != 0 || parse_end == stream) {
                return -1;
            }

            size_t header_len = (size_t)((line_end + 2) - stream);
            memmove(stream, stream + header_len, *stream_used - header_len);
            *stream_used -= header_len;
            if (chunk_len == 0) {
                return 1;
            }
            if (chunk_len > sizeof(line_buffer->data) || chunk_len > (unsigned long)(SIZE_MAX - 2)) {
                return -1;
            }
            *chunk_remaining = (size_t)chunk_len;
        }

        if (*stream_used < *chunk_remaining + 2) {
            return 0;
        }
        if (process_docker_event_payload(client, cache, line_buffer, stream, *chunk_remaining) < 0) {
            return -1;
        }
        if (stream[*chunk_remaining] != '\r' || stream[*chunk_remaining + 1] != '\n') {
            return -1;
        }
        size_t consumed = *chunk_remaining + 2;
        memmove(stream, stream + consumed, *stream_used - consumed);
        *stream_used -= consumed;
        *chunk_remaining = 0;
    }
    return 0;
}

static void write_container_target_events(int client) {
    const char *header =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/x-ndjson\r\n"
        "Cache-Control: no-cache\r\n"
        "Connection: close\r\n"
        "\r\n";
    if (write_full(client, header, strlen(header)) != 0) {
        close_fd(client);
        return;
    }
    struct container_targets_snapshot_cache snapshot_cache = {0};
    (void)emit_container_targets_snapshot_if_changed(client, &snapshot_cache);

    int upstream = connect_unix_socket(docker_unix_socket_path());
    if (upstream < 0) {
        close_fd(client);
        return;
    }
    const char *request =
        "GET /events?filters=%7B%22type%22%3A%7B%22container%22%3Atrue%2C%22network%22%3Atrue%7D%2C%22event%22%3A%7B%22create%22%3Atrue%2C%22start%22%3Atrue%2C%22stop%22%3Atrue%2C%22die%22%3Atrue%2C%22destroy%22%3Atrue%2C%22connect%22%3Atrue%2C%22disconnect%22%3Atrue%2C%22network_connect%22%3Atrue%2C%22network_disconnect%22%3Atrue%7D%7D HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Connection: keep-alive\r\n"
        "\r\n";
    if (write_full(upstream, request, strlen(request)) != 0) {
        close_fd(upstream);
        close_fd(client);
        return;
    }

    char buf[8192];
    size_t used = 0;
    int header_done = 0;
    int chunked = 0;
    char chunk_stream[65536];
    size_t chunk_stream_used = 0;
    size_t chunk_remaining = 0;
    struct docker_event_line_buffer line_buffer = {0};
    while (1) {
        ssize_t n = read(upstream, buf + used, sizeof(buf) - used);
        if (n > 0) {
            used += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }

        size_t offset = 0;
        if (!header_done) {
            char *header_end = NULL;
            for (size_t i = 3; i < used; i++) {
                if (buf[i - 3] == '\r' && buf[i - 2] == '\n' && buf[i - 1] == '\r' && buf[i] == '\n') {
                    header_end = &buf[i + 1];
                    break;
                }
            }
            if (header_end == NULL) {
                if (used == sizeof(buf)) {
                    break;
                }
                continue;
            }
            size_t header_len = (size_t)(header_end - buf);
            char header_copy[8192];
            size_t copy_len = header_len < sizeof(header_copy) - 1 ? header_len : sizeof(header_copy) - 1;
            memcpy(header_copy, buf, copy_len);
            header_copy[copy_len] = '\0';
            chunked = strcasestr(header_copy, "Transfer-Encoding: chunked") != NULL;
            offset = (size_t)(header_end - buf);
            header_done = 1;
        }

        if (used > offset) {
            const char *payload = buf + offset;
            size_t payload_len = used - offset;
            if (chunked) {
                if (payload_len > sizeof(chunk_stream) - chunk_stream_used) {
                    close_fd(upstream);
                    close_fd(client);
                    return;
                }
                memcpy(chunk_stream + chunk_stream_used, payload, payload_len);
                chunk_stream_used += payload_len;
                int status = process_docker_chunked_event_stream(
                    client,
                    &snapshot_cache,
                    &line_buffer,
                    chunk_stream,
                    &chunk_stream_used,
                    &chunk_remaining
                );
                if (status < 0) {
                    close_fd(upstream);
                    close_fd(client);
                    return;
                }
                if (status > 0) {
                    break;
                }
            } else if (process_docker_event_payload(client, &snapshot_cache, &line_buffer, payload, payload_len) < 0) {
                close_fd(upstream);
                close_fd(client);
                return;
            }
        }
        used = 0;
    }
    close_fd(upstream);
    close_fd(client);
}

static void write_port_probe(int client, const uint8_t *first, ssize_t first_len) {
    char request_line[512];
    size_t line_len = 0;
    while (line_len < (size_t)first_len && line_len + 1 < sizeof(request_line)) {
        if (first[line_len] == '\r' || first[line_len] == '\n') {
            break;
        }
        request_line[line_len] = (char)first[line_len];
        line_len++;
    }
    request_line[line_len] = '\0';

    char host[64];
    unsigned port = 0;
    if (sscanf(request_line, "GET /conjet-port-probe?host=%63[^&]&port=%u ", host, &port) != 2 ||
        port == 0 || port > 65535) {
        write_http_response(client, "400 Bad Request", "text/plain", "invalid port probe\n");
        close_fd(client);
        return;
    }

    int fd = connect_tcp_target(host, (uint16_t)port);
    if (fd >= 0) {
        close_fd(fd);
        write_http_response(client, "200 OK", "application/json", "{\"ready\":true}\n");
    } else {
        write_http_response(client, "503 Service Unavailable", "application/json", "{\"ready\":false}\n");
    }
    close_fd(client);
}

static void register_target(uint32_t id, int proto, const char *host, uint16_t port) {
    pthread_mutex_lock(&g_targets_lock);
    for (struct target *existing = g_targets; existing != NULL; existing = existing->next) {
        if (existing->id == id) {
            pthread_mutex_lock(&existing->io_lock);
            existing->proto = proto;
            existing->port = port;
            snprintf(existing->host, sizeof(existing->host), "%s", host);
            if (existing->udp_fd >= 0) {
                close(existing->udp_fd);
                existing->udp_fd = -1;
            }
            existing->udp_addr_ready = 0;
            pthread_mutex_unlock(&existing->io_lock);
            pthread_mutex_unlock(&g_targets_lock);
            metric_inc(&g_metrics.target_registrations);
            return;
        }
    }
    struct target *t = calloc(1, sizeof(*t));
    if (t == NULL) {
        pthread_mutex_unlock(&g_targets_lock);
        return;
    }
    t->id = id;
    t->proto = proto;
    t->port = port;
    pthread_mutex_init(&t->io_lock, NULL);
    t->udp_fd = -1;
    t->udp_addr_ready = 0;
    snprintf(t->host, sizeof(t->host), "%s", host);
    t->next = g_targets;
    g_targets = t;
    pthread_mutex_unlock(&g_targets_lock);
    metric_inc(&g_metrics.target_registrations);
}

static ssize_t udp_exchange_target(uint32_t id, const uint8_t *payload, uint32_t payload_len, uint8_t *out, size_t out_len) {
    ssize_t result = -1;
    pthread_mutex_lock(&g_targets_lock);
    struct target *t = NULL;
    for (struct target *candidate = g_targets; candidate != NULL; candidate = candidate->next) {
        if (candidate->id == id) {
            t = candidate;
            break;
        }
    }
    if (t == NULL || t->proto != SOCK_DGRAM) {
        pthread_mutex_unlock(&g_targets_lock);
        metric_inc(&g_metrics.target_lookup_misses);
        return -1;
    }
    metric_inc(&g_metrics.target_lookup_hits);
    if (t->port == 0) {
        size_t n = payload_len < out_len ? payload_len : out_len;
        memcpy(out, payload, n);
        pthread_mutex_unlock(&g_targets_lock);
        return (ssize_t)n;
    }
    pthread_mutex_lock(&t->io_lock);
    pthread_mutex_unlock(&g_targets_lock);
    int family = strchr(t->host, ':') != NULL ? AF_INET6 : AF_INET;
    if (t->udp_fd < 0) {
        t->udp_fd = socket(family, SOCK_DGRAM, 0);
        if (t->udp_fd < 0) {
            pthread_mutex_unlock(&t->io_lock);
            return -1;
        }
        struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(t->udp_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    if (!t->udp_addr_ready) {
        memset(&t->udp_addr, 0, sizeof(t->udp_addr));
        if (family == AF_INET6) {
            struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)&t->udp_addr;
            addr6->sin6_family = AF_INET6;
            addr6->sin6_port = htons(t->port);
            if (inet_pton(AF_INET6, t->host, &addr6->sin6_addr) != 1) {
                pthread_mutex_unlock(&t->io_lock);
                return -1;
            }
            t->udp_addr_len = sizeof(*addr6);
        } else {
            struct sockaddr_in *addr4 = (struct sockaddr_in *)&t->udp_addr;
            addr4->sin_family = AF_INET;
            addr4->sin_port = htons(t->port);
            if (inet_pton(AF_INET, t->host, &addr4->sin_addr) != 1) {
                pthread_mutex_unlock(&t->io_lock);
                return -1;
            }
            t->udp_addr_len = sizeof(*addr4);
        }
        t->udp_addr_ready = 1;
    }
    if (sendto(t->udp_fd, payload, payload_len, 0, (struct sockaddr *)&t->udp_addr, t->udp_addr_len) >= 0) {
        result = recv(t->udp_fd, out, out_len, 0);
    }
    pthread_mutex_unlock(&t->io_lock);
    return result;
}

static void *pump_thread(void *raw) {
    struct pump_args *args = (struct pump_args *)raw;
    uint8_t buf[65536];
    while (1) {
        ssize_t n = read(args->from, buf, sizeof(buf));
        if (n > 0) {
            if (write_full(args->to, buf, (size_t)n) != 0) {
                break;
            }
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    if (args->shutdown_to_on_eof) {
        shutdown(args->to, SHUT_WR);
    }
    free(args);
    return NULL;
}

enum chunked_parse_state {
    CHUNK_PARSE_SIZE,
    CHUNK_PARSE_DATA,
    CHUNK_PARSE_DATA_CRLF,
    CHUNK_PARSE_TRAILERS,
    CHUNK_PARSE_DONE,
    CHUNK_PARSE_ERROR,
};

struct chunked_response_parser {
    enum chunked_parse_state state;
    char line[128];
    size_t line_len;
    size_t remaining;
    unsigned crlf_seen;
};

static void chunked_response_parser_init(struct chunked_response_parser *parser) {
    memset(parser, 0, sizeof(*parser));
    parser->state = CHUNK_PARSE_SIZE;
}

static int chunked_line_append(struct chunked_response_parser *parser, char byte) {
    if (parser->line_len + 1 >= sizeof(parser->line)) {
        parser->state = CHUNK_PARSE_ERROR;
        return -1;
    }
    parser->line[parser->line_len++] = byte;
    parser->line[parser->line_len] = '\0';
    return 0;
}

static int parse_chunk_size_line(const char *line, size_t line_len, size_t *out) {
    char tmp[128];
    size_t copy_len = line_len;
    if (copy_len >= sizeof(tmp)) {
        return -1;
    }
    memcpy(tmp, line, copy_len);
    tmp[copy_len] = '\0';
    char *semicolon = strchr(tmp, ';');
    if (semicolon != NULL) {
        *semicolon = '\0';
    }
    char *cursor = tmp;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    if (*cursor == '\0') {
        return -1;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(cursor, &end, 16);
    if (errno != 0 || end == cursor) {
        return -1;
    }
    while (*end == ' ' || *end == '\t') {
        end++;
    }
    if (*end != '\0' || value > (unsigned long long)SIZE_MAX) {
        return -1;
    }
    *out = (size_t)value;
    return 0;
}

static int chunked_response_parser_feed(struct chunked_response_parser *parser, const char *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        char byte = data[i];
        switch (parser->state) {
        case CHUNK_PARSE_SIZE:
            if (byte == '\n') {
                size_t line_len = parser->line_len;
                if (line_len > 0 && parser->line[line_len - 1] == '\r') {
                    line_len--;
                }
                size_t chunk_size = 0;
                if (parse_chunk_size_line(parser->line, line_len, &chunk_size) != 0) {
                    parser->state = CHUNK_PARSE_ERROR;
                    return -1;
                }
                parser->line_len = 0;
                parser->line[0] = '\0';
                parser->remaining = chunk_size;
                parser->crlf_seen = 0;
                parser->state = chunk_size == 0 ? CHUNK_PARSE_TRAILERS : CHUNK_PARSE_DATA;
            } else if (chunked_line_append(parser, byte) != 0) {
                return -1;
            }
            break;
        case CHUNK_PARSE_DATA:
            if (parser->remaining > 0) {
                parser->remaining--;
            }
            if (parser->remaining == 0) {
                parser->crlf_seen = 0;
                parser->state = CHUNK_PARSE_DATA_CRLF;
            }
            break;
        case CHUNK_PARSE_DATA_CRLF:
            if ((parser->crlf_seen == 0 && byte == '\r') ||
                (parser->crlf_seen == 1 && byte == '\n')) {
                parser->crlf_seen++;
                if (parser->crlf_seen == 2) {
                    parser->line_len = 0;
                    parser->line[0] = '\0';
                    parser->state = CHUNK_PARSE_SIZE;
                }
            } else {
                parser->state = CHUNK_PARSE_ERROR;
                return -1;
            }
            break;
        case CHUNK_PARSE_TRAILERS:
            if (byte == '\n') {
                size_t line_len = parser->line_len;
                if (line_len > 0 && parser->line[line_len - 1] == '\r') {
                    line_len--;
                }
                parser->line_len = 0;
                parser->line[0] = '\0';
                if (line_len == 0) {
                    parser->state = CHUNK_PARSE_DONE;
                    return 1;
                }
            } else if (chunked_line_append(parser, byte) != 0) {
                return -1;
            }
            break;
        case CHUNK_PARSE_DONE:
            return 1;
        case CHUNK_PARSE_ERROR:
            return -1;
        }
    }
    return parser->state == CHUNK_PARSE_DONE ? 1 : 0;
}

static int parse_http_response_status_code(const char *header, size_t header_len) {
    const char *line_end = memmem(header, header_len, "\r\n", 2);
    size_t line_len = line_end == NULL ? header_len : (size_t)(line_end - header);
    if (line_len < sizeof("HTTP/1.1 000") - 1 || memcmp(header, "HTTP/", 5) != 0) {
        return 0;
    }
    const char *space = memchr(header, ' ', line_len);
    if (space == NULL || (size_t)(line_len - (space - header)) < 4) {
        return 0;
    }
    if (space[1] < '0' || space[1] > '9' ||
        space[2] < '0' || space[2] > '9' ||
        space[3] < '0' || space[3] > '9') {
        return 0;
    }
    return (space[1] - '0') * 100 + (space[2] - '0') * 10 + (space[3] - '0');
}

static int http_status_has_no_response_body(int status_code) {
    return (status_code >= 100 && status_code < 200) || status_code == 204 || status_code == 304;
}

static int write_docker_response_header_close(int fd, const char *header, size_t headers_len) {
    const char *cursor = header;
    const char *end = header + headers_len;
    while (cursor < end) {
        const char *next = memmem(cursor, (size_t)(end - cursor), "\r\n", 2);
        size_t line_len = next == NULL ? (size_t)(end - cursor) : (size_t)(next - cursor);
        if (!header_line_is_connection((const uint8_t *)cursor, line_len)) {
            if (write_full(fd, cursor, line_len) != 0 || write_full(fd, "\r\n", 2) != 0) {
                return -1;
            }
        }
        if (next == NULL) {
            break;
        }
        cursor = next + 2;
    }
    static const char close_header[] = "Connection: close\r\n\r\n";
    return write_full(fd, close_header, sizeof(close_header) - 1);
}

static void *docker_response_pump_thread(void *raw) {
    struct pump_args *args = (struct pump_args *)raw;
    char buf[65536];
    char pending[131072];
    size_t pending_len = 0;
    int header_done = 0;
    int has_content_length = 0;
    size_t content_length = 0;
    size_t body_seen = 0;
    int chunked = 0;
    int no_response_body = 0;
    struct chunked_response_parser chunked_parser;
    chunked_response_parser_init(&chunked_parser);

    while (1) {
        if (pending_len == sizeof(pending) && !header_done) {
            break;
        }

        ssize_t n = read(args->from, buf, sizeof(buf));
        if (n > 0) {
            if ((size_t)n > sizeof(pending) - pending_len) {
                break;
            }
            memcpy(pending + pending_len, buf, (size_t)n);
            pending_len += (size_t)n;

            while (pending_len > 0) {
                if (!header_done) {
                    const char marker[] = "\r\n\r\n";
                    char *header_end = memmem(pending, pending_len, marker, sizeof(marker) - 1);
                    if (header_end == NULL) {
                        break;
                    }

                    size_t headers_len = (size_t)(header_end - pending);
                    size_t header_total = headers_len + sizeof(marker) - 1;
                    int status_code = parse_http_response_status_code(pending, headers_len);

                    if (status_code >= 100 && status_code < 200 && status_code != 101) {
                        if (write_full(args->to, pending, header_total) != 0) {
                            goto done;
                        }
                        memmove(pending, pending + header_total, pending_len - header_total);
                        pending_len -= header_total;
                        continue;
                    }

                    if (status_code == 101) {
                        if (write_full(args->to, pending, pending_len) != 0) {
                            goto done;
                        }
                        pending_len = 0;
                        while ((n = read(args->from, buf, sizeof(buf))) > 0) {
                            if (write_full(args->to, buf, (size_t)n) != 0) {
                                goto done;
                            }
                        }
                        goto done;
                    }

                    header_done = 1;
                    no_response_body = http_status_has_no_response_body(status_code);
                    chunked = memmem(pending, headers_len, "Transfer-Encoding: chunked", sizeof("Transfer-Encoding: chunked") - 1) != NULL ||
                              memmem(pending, headers_len, "transfer-encoding: chunked", sizeof("transfer-encoding: chunked") - 1) != NULL;
                    if (parse_content_length_header((const uint8_t *)pending, headers_len, &content_length) == 0) {
                        has_content_length = 1;
                    }
                    if (write_docker_response_header_close(args->to, pending, headers_len) != 0) {
                        goto done;
                    }
                    memmove(pending, pending + header_total, pending_len - header_total);
                    pending_len -= header_total;
                    if (no_response_body) {
                        goto done;
                    }
                    continue;
                }

                size_t body_len = pending_len;
                if (has_content_length && body_seen + body_len > content_length) {
                    body_len = content_length - body_seen;
                }
                if (body_len > 0 && write_full(args->to, pending, body_len) != 0) {
                    goto done;
                }
                body_seen += body_len;
                if (chunked && body_len > 0) {
                    int chunk_status = chunked_response_parser_feed(&chunked_parser, pending, body_len);
                    if (chunk_status > 0) {
                        goto done;
                    }
                    if (chunk_status < 0) {
                        chunked = 0;
                    }
                }
                if (has_content_length && body_seen >= content_length) {
                    goto done;
                }
                if (body_len < pending_len) {
                    memmove(pending, pending + body_len, pending_len - body_len);
                    pending_len -= body_len;
                } else {
                    pending_len = 0;
                }
                break;
            }
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
done:
    shutdown(args->to, SHUT_WR);
    free(args);
    return NULL;
}

static int connect_tcp_target(const char *host, uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_unix_socket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void handle_docker_proxy(int client, const uint8_t *first, size_t first_len) {
    int upstream = connect_unix_socket(docker_unix_socket_path());
    if (upstream < 0) {
        write_http_response(client, "503 Service Unavailable", "text/plain", "Conjet guest bridge could not connect to Docker\n");
        close_fd(client);
        return;
    }

    uint8_t *request_storage = NULL;
    size_t request_storage_len = 0;
    int request_complete = 0;
    if (receive_initial_docker_request(
            client,
            first,
            first_len,
            &request_storage,
            &request_storage_len,
            &request_complete
        ) != 0) {
        close_fd(upstream);
        close_fd(client);
        return;
    }

    const uint8_t *request_to_send = request_storage;
    size_t request_to_send_len = request_storage_len;
    uint8_t *rewritten_request = NULL;
    uint8_t *connection_close_request = NULL;

    size_t rewritten_request_len = 0;
    if (rewrite_container_create_request(request_to_send, request_to_send_len, &rewritten_request, &rewritten_request_len) > 0) {
        request_to_send = rewritten_request;
        request_to_send_len = rewritten_request_len;
    } else if (rewrite_docker_build_request_cgroup_parent(request_to_send, request_to_send_len, &rewritten_request, &rewritten_request_len) > 0) {
        request_to_send = rewritten_request;
        request_to_send_len = rewritten_request_len;
    }

    const int upgraded_stream = docker_request_is_upgraded_stream(request_to_send, request_to_send_len);
    const int streaming_http = docker_request_is_streaming_http(request_to_send, request_to_send_len);
    size_t connection_close_request_len = 0;
    if (!upgraded_stream && !streaming_http && request_complete &&
        rewrite_http_request_connection_close(
            request_to_send,
            request_to_send_len,
            &connection_close_request,
            &connection_close_request_len
        ) > 0) {
        request_to_send = connection_close_request;
        request_to_send_len = connection_close_request_len;
    }

    int write_rc = 0;
    if (request_to_send_len > 0) {
        write_rc = write_full(upstream, request_to_send, request_to_send_len);
    }

    free(connection_close_request);
    free(rewritten_request);
    free(request_storage);

    if (write_rc != 0) {
        close_fd(upstream);
        close_fd(client);
        return;
    }

    if (!upgraded_stream && streaming_http && request_complete) {
        struct pump_args *ba = calloc(1, sizeof(*ba));
        if (ba == NULL) {
            close_fd(upstream);
            close_fd(client);
            return;
        }
        ba->from = upstream;
        ba->to = client;
        ba->shutdown_to_on_eof = 1;
        pthread_t response_thread;
        if (pthread_create(&response_thread, NULL, pump_thread, ba) != 0) {
            free(ba);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        pthread_join(response_thread, NULL);
        close_fd(upstream);
        close_fd(client);
        return;
    }

    if (!upgraded_stream && !streaming_http && request_complete) {
        struct pump_args *ba = calloc(1, sizeof(*ba));
        if (ba == NULL) {
            close_fd(upstream);
            close_fd(client);
            return;
        }
        ba->from = upstream;
        ba->to = client;
        ba->shutdown_to_on_eof = 1;
        pthread_t response_thread;
        if (pthread_create(&response_thread, NULL, docker_response_pump_thread, ba) != 0) {
            free(ba);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        pthread_join(response_thread, NULL);
        close_fd(upstream);
        close_fd(client);
        return;
    }

    if (!upgraded_stream && !streaming_http) {
        pthread_t request_thread, response_thread;
        struct pump_args *ab = calloc(1, sizeof(*ab));
        struct pump_args *ba = calloc(1, sizeof(*ba));
        if (ab == NULL || ba == NULL) {
            free(ab);
            free(ba);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        ab->from = client;
        ab->to = upstream;
        ab->shutdown_to_on_eof = 1;
        ba->from = upstream;
        ba->to = client;
        ba->shutdown_to_on_eof = 1;

        if (pthread_create(&request_thread, NULL, pump_thread, ab) != 0) {
            free(ab);
            free(ba);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        if (pthread_create(&response_thread, NULL, docker_response_pump_thread, ba) != 0) {
            free(ba);
            shutdown(client, SHUT_RDWR);
            shutdown(upstream, SHUT_RDWR);
            pthread_join(request_thread, NULL);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        pthread_join(response_thread, NULL);
        shutdown(client, SHUT_RDWR);
        shutdown(upstream, SHUT_RDWR);
        pthread_join(request_thread, NULL);
        close_fd(upstream);
        close_fd(client);
        return;
    }

    pthread_t a, b;
    struct pump_args *ab = calloc(1, sizeof(*ab));
    struct pump_args *ba = calloc(1, sizeof(*ba));
    if (ab == NULL || ba == NULL) {
        free(ab);
        free(ba);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    ab->from = client;
    ab->to = upstream;
    ab->shutdown_to_on_eof = 1;
    ba->from = upstream;
    ba->to = client;
    ba->shutdown_to_on_eof = 1;

    if (pthread_create(&a, NULL, pump_thread, ab) != 0) {
        free(ab);
        free(ba);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    if (pthread_create(&b, NULL, pump_thread, ba) != 0) {
        free(ba);
        shutdown(client, SHUT_RDWR);
        shutdown(upstream, SHUT_RDWR);
        pthread_join(a, NULL);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    pthread_join(b, NULL);
    shutdown(client, SHUT_RDWR);
    shutdown(upstream, SHUT_RDWR);
    pthread_join(a, NULL);
    close_fd(upstream);
    close_fd(client);
}

static void handle_legacy_tcp(int client, const char *line, const uint8_t *remainder, size_t remainder_len) {
    const char *target = line + strlen("CONJET-TCP ");
    const char *colon = strrchr(target, ':');
    if (colon == NULL) {
        close_fd(client);
        return;
    }
    char host[64];
    size_t host_len = (size_t)(colon - target);
    if (host_len >= sizeof(host)) {
        close_fd(client);
        return;
    }
    memcpy(host, target, host_len);
    host[host_len] = '\0';
    int port = atoi(colon + 1);
    int upstream = connect_tcp_target(host, (uint16_t)port);
    if (upstream < 0) {
        write_http_response(client, "502 Bad Gateway", "text/plain", "Conjet guest TCP proxy could not connect\n");
        close_fd(client);
        return;
    }
    metric_inc(&g_metrics.tcp_connections);
    if (remainder_len > 0) {
        write_full(upstream, remainder, remainder_len);
    }
    pthread_t a, b;
    struct pump_args *ab = calloc(1, sizeof(*ab));
    struct pump_args *ba = calloc(1, sizeof(*ba));
    if (ab == NULL || ba == NULL) {
        free(ab);
        free(ba);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    ab->from = client;
    ab->to = upstream;
    ab->shutdown_to_on_eof = 1;
    ba->from = upstream;
    ba->to = client;
    ba->shutdown_to_on_eof = 1;
    if (pthread_create(&a, NULL, pump_thread, ab) != 0) {
        free(ab);
        free(ba);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    if (pthread_create(&b, NULL, pump_thread, ba) != 0) {
        free(ba);
        shutdown(client, SHUT_RDWR);
        shutdown(upstream, SHUT_RDWR);
        pthread_join(a, NULL);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    pthread_join(b, NULL);
    shutdown(client, SHUT_RDWR);
    shutdown(upstream, SHUT_RDWR);
    pthread_join(a, NULL);
    close_fd(upstream);
    close_fd(client);
}

static void handle_legacy_udp(int client, const char *line, const uint8_t *payload, size_t payload_len) {
    const char *target = line + strlen("CONJET-UDP ");
    const char *colon = strrchr(target, ':');
    if (colon == NULL) {
        close_fd(client);
        return;
    }
    char host[64];
    size_t host_len = (size_t)(colon - target);
    if (host_len >= sizeof(host)) {
        close_fd(client);
        return;
    }
    memcpy(host, target, host_len);
    host[host_len] = '\0';
    int port = atoi(colon + 1);
    int family = strchr(host, ':') != NULL ? AF_INET6 : AF_INET;
    int upstream = socket(family, SOCK_DGRAM, 0);
    if (upstream < 0) {
        close_fd(client);
        return;
    }
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(upstream, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_storage addr;
    socklen_t addr_len = 0;
    memset(&addr, 0, sizeof(addr));
    if (family == AF_INET6) {
        struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)&addr;
        addr6->sin6_family = AF_INET6;
        addr6->sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, host, &addr6->sin6_addr) != 1) {
            metric_inc(&g_metrics.udp_drops);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        addr_len = sizeof(*addr6);
    } else {
        struct sockaddr_in *addr4 = (struct sockaddr_in *)&addr;
        addr4->sin_family = AF_INET;
        addr4->sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, host, &addr4->sin_addr) != 1) {
            metric_inc(&g_metrics.udp_drops);
            close_fd(upstream);
            close_fd(client);
            return;
        }
        addr_len = sizeof(*addr4);
    }
    metric_inc(&g_metrics.udp_packets_in);
    if (sendto(upstream, payload, payload_len, 0, (struct sockaddr *)&addr, addr_len) < 0) {
        metric_inc(&g_metrics.udp_drops);
        close_fd(upstream);
        close_fd(client);
        return;
    }
    uint8_t buf[65507];
    ssize_t n = recv(upstream, buf, sizeof(buf), 0);
    if (n > 0) {
        write_full(client, buf, (size_t)n);
        metric_inc(&g_metrics.udp_packets_out);
    } else {
        metric_inc(&g_metrics.udp_drops);
    }
    close_fd(upstream);
    close_fd(client);
}

static int frame_reader_has_pending(const struct frame_reader *reader) {
    return reader->pending != NULL && reader->pending_len > 0;
}

static int read_frame_bytes(struct frame_reader *reader, uint8_t *buffer, size_t length) {
    size_t copied = 0;
    while (copied < length) {
        if (frame_reader_has_pending(reader)) {
            size_t n = reader->pending_len < (length - copied) ? reader->pending_len : (length - copied);
            memcpy(buffer + copied, reader->pending, n);
            reader->pending += n;
            reader->pending_len -= n;
            copied += n;
            continue;
        }
        if (read_full(reader->fd, buffer + copied, length - copied) != 0) {
            return -1;
        }
        copied = length;
    }
    return 0;
}

static int read_next_frame(struct frame_reader *reader, struct frame_header *h, uint8_t **payload) {
    uint8_t header_buf[FRAME_HEADER_SIZE];
    *payload = NULL;
    if (read_frame_bytes(reader, header_buf, sizeof(header_buf)) != 0) {
        return -1;
    }
    if (parse_frame_header(header_buf, h) != 0) {
        return -1;
    }
    if (h->payload_len > 0) {
        *payload = malloc(h->payload_len);
        if (*payload == NULL) {
            return -1;
        }
        if (read_frame_bytes(reader, *payload, h->payload_len) != 0) {
            free(*payload);
            *payload = NULL;
            return -1;
        }
    }
    return 0;
}

static int parse_tcp_open_payload(const uint8_t *payload, uint32_t payload_len, char *host, size_t host_len, uint16_t *port) {
    if (payload == NULL || payload_len == 0 || host_len == 0) {
        return -1;
    }
    char *text = calloc(1, (size_t)payload_len + 1);
    if (text == NULL) {
        return -1;
    }
    memcpy(text, payload, payload_len);
    unsigned parsed_port = 0;
    char parsed_host[64];
    int count = sscanf(text, "%63s %u", parsed_host, &parsed_port);
    free(text);
    if (count != 2 || parsed_port == 0 || parsed_port > 65535) {
        return -1;
    }
    snprintf(host, host_len, "%s", parsed_host);
    *port = (uint16_t)parsed_port;
    return 0;
}

static int write_tcp_error(int client, uint32_t stream_id, const char *message) {
    metric_inc(&g_metrics.tcp_binary_errors);
    return write_frame(client, FRAME_TCP_ERROR, 0, stream_id, 0, (const uint8_t *)message, (uint32_t)strlen(message));
}

static int handle_binary_tcp_stream(struct frame_reader *reader, const struct frame_header *open_header, const uint8_t *payload) {
    int client = reader->fd;
    char host[64];
    uint16_t port = 0;
    if (parse_tcp_open_payload(payload, open_header->payload_len, host, sizeof(host), &port) != 0) {
        write_tcp_error(client, open_header->stream_id, "bad tcp open target");
        return 0;
    }

    int upstream = connect_tcp_target(host, port);
    if (upstream < 0) {
        write_tcp_error(client, open_header->stream_id, "tcp target connect failed");
        return 0;
    }

    metric_inc(&g_metrics.tcp_connections);
    metric_inc(&g_metrics.tcp_binary_streams);
    set_nonblocking_fd(upstream);
    write_frame(client, FRAME_TCP_OPEN, 0, open_header->stream_id, open_header->port_forward_id, NULL, 0);

    int host_write_closed = 0;
    int target_read_closed = 0;
    uint8_t buf[65536];
    while (1) {
        struct pollfd fds[2];
        int client_ready = frame_reader_has_pending(reader);
        if (!client_ready) {
            fds[0].fd = client;
            fds[0].events = POLLIN;
            fds[0].revents = 0;
            fds[1].fd = upstream;
            fds[1].events = target_read_closed ? 0 : POLLIN;
            fds[1].revents = 0;

            int poll_result = poll(fds, 2, -1);
            if (poll_result < 0) {
                if (errno == EINTR) {
                    continue;
                }
                write_tcp_error(client, open_header->stream_id, "tcp relay poll failed");
                close_fd(upstream);
                return 0;
            }
            client_ready = (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
        } else {
            fds[0].fd = client;
            fds[0].events = 0;
            fds[0].revents = 0;
            fds[1].fd = upstream;
            fds[1].events = 0;
            fds[1].revents = 0;
        }

        if (client_ready) {
            struct frame_header h;
            uint8_t *frame_payload = NULL;
            if (read_next_frame(reader, &h, &frame_payload) != 0) {
                close_fd(upstream);
                return -1;
            }

            if (h.stream_id != open_header->stream_id) {
                write_tcp_error(client, h.stream_id, "unexpected tcp stream id");
                free(frame_payload);
            } else if (h.type == FRAME_TCP_DATA) {
                if (h.payload_len > 0 && frame_payload != NULL &&
                    write_full_poll(upstream, frame_payload, h.payload_len) != 0) {
                    free(frame_payload);
                    write_tcp_error(client, h.stream_id, "tcp target write failed");
                    close_fd(upstream);
                    return 0;
                }
                free(frame_payload);
            } else if (h.type == FRAME_TCP_HALF_CLOSE) {
                host_write_closed = 1;
                shutdown(upstream, SHUT_WR);
                free(frame_payload);
            } else if (h.type == FRAME_TCP_CLOSE) {
                free(frame_payload);
                write_frame(client, FRAME_TCP_CLOSE, 0, h.stream_id, h.port_forward_id, NULL, 0);
                close_fd(upstream);
                return 0;
            } else if (h.type == FRAME_PING) {
                write_frame(client, FRAME_PONG, 0, h.stream_id, h.port_forward_id, frame_payload, h.payload_len);
                free(frame_payload);
            } else if (h.type == FRAME_METRICS) {
                char body[256];
                pthread_mutex_lock(&g_metrics.lock);
                int n = snprintf(body, sizeof(body), "{\"bridge_engine\":\"conjet-netd-c\",\"tcp_binary_streams\":%llu}\n",
                    (unsigned long long)g_metrics.tcp_binary_streams);
                pthread_mutex_unlock(&g_metrics.lock);
                write_frame(client, FRAME_METRICS, 0, h.stream_id, h.port_forward_id, (const uint8_t *)body, (uint32_t)n);
                free(frame_payload);
            } else {
                write_tcp_error(client, h.stream_id, "unexpected tcp frame");
                free(frame_payload);
            }
        }

        if (!target_read_closed && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            while (1) {
                ssize_t n = read(upstream, buf, sizeof(buf));
                if (n > 0) {
                    if (write_frame(client, FRAME_TCP_DATA, 0, open_header->stream_id, open_header->port_forward_id, buf, (uint32_t)n) != 0) {
                        close_fd(upstream);
                        return -1;
                    }
                } else if (n == 0) {
                    target_read_closed = 1;
                    if (write_frame(client, FRAME_TCP_HALF_CLOSE, 0, open_header->stream_id, open_header->port_forward_id, NULL, 0) != 0) {
                        close_fd(upstream);
                        return -1;
                    }
                    break;
                } else if (errno == EINTR) {
                    continue;
                } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                } else {
                    write_tcp_error(client, open_header->stream_id, "tcp target read failed");
                    close_fd(upstream);
                    return 0;
                }
            }
        }

        if (target_read_closed && host_write_closed) {
            write_frame(client, FRAME_TCP_CLOSE, 0, open_header->stream_id, open_header->port_forward_id, NULL, 0);
            close_fd(upstream);
            return 0;
        }
    }
}

static void handle_binary_frames(int client, const uint8_t *first_bytes, ssize_t first_len) {
    struct frame_reader reader = {
        .fd = client,
        .pending = first_bytes,
        .pending_len = (size_t)first_len
    };
    while (1) {
        struct frame_header h;
        uint8_t header_buf[FRAME_HEADER_SIZE];
        if (read_frame_bytes(&reader, header_buf, sizeof(header_buf)) != 0) {
            break;
        }
        if (parse_frame_header(header_buf, &h) != 0) {
            write_frame(client, FRAME_ERROR, 0, 0, 0, (const uint8_t *)"bad frame", 9);
            break;
        }
        uint8_t *payload = NULL;
        if (h.payload_len > 0) {
            payload = malloc(h.payload_len);
            if (payload == NULL) {
                break;
            }
            if (read_frame_bytes(&reader, payload, h.payload_len) != 0) {
                free(payload);
                break;
            }
        }
        if (h.type == FRAME_HELLO) {
            write_frame(client, FRAME_HELLO_ACK, 0, h.stream_id, h.port_forward_id, (const uint8_t *)"conjet-netd-c", 13);
        } else if (h.type == FRAME_PING) {
            write_frame(client, FRAME_PONG, 0, h.stream_id, h.port_forward_id, payload, h.payload_len);
        } else if (h.type == FRAME_REGISTER_TARGET) {
            if (payload != NULL) {
                char host[64] = "127.0.0.1";
                char proto[8] = "tcp";
                unsigned id = h.port_forward_id;
                unsigned port = 0;
                char *text = calloc(1, (size_t)h.payload_len + 1);
                if (text != NULL) {
                    memcpy(text, payload, h.payload_len);
                    sscanf(text, "%u %7s %63s %u", &id, proto, host, &port);
                    free(text);
                }
                register_target((uint32_t)id, strcmp(proto, "udp") == 0 ? SOCK_DGRAM : SOCK_STREAM, host, (uint16_t)port);
            }
            write_frame(client, FRAME_HELLO_ACK, 0, h.stream_id, h.port_forward_id, NULL, 0);
        } else if (h.type == FRAME_UDP) {
            if (payload == NULL) {
                metric_inc(&g_metrics.udp_drops);
                write_frame(client, FRAME_ERROR, 0, h.stream_id, h.port_forward_id, (const uint8_t *)"target missing", 14);
            } else {
                metric_inc(&g_metrics.udp_packets_in);
                uint8_t buf[65507];
                ssize_t n = udp_exchange_target(h.port_forward_id, payload, h.payload_len, buf, sizeof(buf));
                if (n > 0) {
                    write_frame(client, FRAME_UDP, 0, h.stream_id, h.port_forward_id, buf, (uint32_t)n);
                    metric_inc(&g_metrics.udp_packets_out);
                } else {
                    metric_inc(&g_metrics.udp_drops);
                    write_frame(client, FRAME_ERROR, 0, h.stream_id, h.port_forward_id, (const uint8_t *)"udp target failed", 17);
                }
            }
        } else if (h.type == FRAME_TCP_OPEN) {
            int result = handle_binary_tcp_stream(&reader, &h, payload);
            free(payload);
            payload = NULL;
            if (result != 0) {
                break;
            }
        } else if (h.type == FRAME_METRICS) {
            char body[512];
            pthread_mutex_lock(&g_metrics.lock);
            int n = snprintf(body, sizeof(body),
                "{\"bridge_engine\":\"conjet-netd-c\",\"tcp_mode\":\"persistent-binary-tcp-pool\","
                "\"udp_mode\":\"persistent-binary-udp\",\"udp_packets_in\":%llu,\"udp_packets_out\":%llu,"
                "\"tcp_binary_streams\":%llu}\n",
                (unsigned long long)g_metrics.udp_packets_in,
                (unsigned long long)g_metrics.udp_packets_out,
                (unsigned long long)g_metrics.tcp_binary_streams);
            pthread_mutex_unlock(&g_metrics.lock);
            write_frame(client, FRAME_METRICS, 0, h.stream_id, h.port_forward_id, (const uint8_t *)body, (uint32_t)n);
        } else {
            write_frame(client, FRAME_ERROR, 0, h.stream_id, h.port_forward_id, (const uint8_t *)"unknown frame", 13);
        }
        free(payload);
    }
    close_fd(client);
}

static void *handle_client(void *raw) {
    struct client_args *args = (struct client_args *)raw;
    int client = args->fd;
    free(args);
    uint8_t first[65536];
    ssize_t n = read(client, first, sizeof(first));
    if (n <= 0) {
        close_fd(client);
        return NULL;
    }
    if (n >= FRAME_HEADER_SIZE && read_u32_be(first) == FRAME_MAGIC) {
        handle_binary_frames(client, first, n);
        return NULL;
    }
    char *newline = memchr(first, '\n', (size_t)n);
    if (newline != NULL) {
        size_t line_len = (size_t)(newline - (char *)first);
        char line[512];
        if (line_len >= sizeof(line)) {
            close_fd(client);
            return NULL;
        }
        memcpy(line, first, line_len);
        line[line_len] = '\0';
        uint8_t *remainder = (uint8_t *)newline + 1;
        size_t remainder_len = (size_t)n - line_len - 1;
        if (strncmp(line, "CONJET-TCP ", 11) == 0) {
            handle_legacy_tcp(client, line, remainder, remainder_len);
            return NULL;
        }
        if (strncmp(line, "CONJET-UDP ", 11) == 0) {
            handle_legacy_udp(client, line, remainder, remainder_len);
            return NULL;
        }
    }
    if (n >= (ssize_t)(sizeof("GET /conjet-control/ping ") - 1) &&
               memcmp(first, "GET /conjet-control/ping ", sizeof("GET /conjet-control/ping ") - 1) == 0) {
        write_control_ping(client);
    } else if (n >= (ssize_t)(sizeof("GET /conjet-control/mounts ") - 1) &&
               memcmp(first, "GET /conjet-control/mounts ", sizeof("GET /conjet-control/mounts ") - 1) == 0) {
        write_control_mounts(client);
    } else if (n >= (ssize_t)(sizeof("POST /conjet-control/mount-virtiofs ") - 1) &&
               memcmp(first, "POST /conjet-control/mount-virtiofs ", sizeof("POST /conjet-control/mount-virtiofs ") - 1) == 0) {
        write_control_mount_virtiofs(client, first, n);
    } else if (n >= 32 && memcmp(first, "GET /conjet-bridge-capabilities ", 32) == 0) {
        write_capabilities(client);
        close_fd(client);
    } else if (n >= 23 && memcmp(first, "GET /conjet-guest-echo ", 23) == 0) {
        write_http_response(client, "200 OK", "application/octet-stream", "conjet-guest-echo\n");
        close_fd(client);
    } else if (n >= 27 && memcmp(first, "GET /conjet-bridge-metrics ", 27) == 0) {
        write_metrics(client);
        close_fd(client);
    } else if (n >= (ssize_t)(sizeof("GET /conjet-container-targets ") - 1) &&
               memcmp(first, "GET /conjet-container-targets ", sizeof("GET /conjet-container-targets ") - 1) == 0) {
        write_container_targets(client);
    } else if (n >= (ssize_t)(sizeof("GET /conjet-container-target-events ") - 1) &&
               memcmp(first, "GET /conjet-container-target-events ", sizeof("GET /conjet-container-target-events ") - 1) == 0) {
        write_container_target_events(client);
    } else if (n >= (ssize_t)(sizeof("GET /conjet-port-probe?") - 1) &&
               memcmp(first, "GET /conjet-port-probe?", sizeof("GET /conjet-port-probe?") - 1) == 0) {
        write_port_probe(client, first, n);
    } else {
        handle_docker_proxy(client, first, (size_t)n);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) {
        if (strcmp(argv[1], "--version") == 0) {
            printf("conjet-netd-c 0.1\n");
            return 0;
        }
        if (strcmp(argv[1], "--capabilities") == 0) {
            puts("{\"version\":6,\"tcp_proxy\":true,\"udp_proxy\":true,\"docker_events\":true,\"container_ip_lookup\":true,\"container_target_events\":true,\"port_probe\":true,\"guest_echo\":true,\"guest_metrics\":true,\"binary_frames\":true,\"udp_binary_frames\":true,\"persistent_vsock\":true,\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true,\"guest_control\":true,\"bridge_engine\":\"conjet-netd-c\"}");
            return 0;
        }
        if (strcmp(argv[1], "--send-readiness") == 0) {
            if (argc < 3) {
                fprintf(stderr, "usage: conjet-netd --send-readiness control-ready|process-started\n");
                return 2;
            }
            return send_readiness_record(argv[2]);
        }
    }
    signal(SIGPIPE, SIG_IGN);
    mkdir("/run/conjet", 0755);
    unlink("/run/conjet/docker-vsock-ready");
    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) {
        perror("socket(AF_VSOCK)");
        return 1;
    }
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = CONJET_NETD_PORT;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listener, 1024) != 0) {
        perror("bind/listen");
        close(listener);
        return 1;
    }
    FILE *ready = fopen("/run/conjet/docker-vsock-ready", "w");
    if (ready != NULL) {
        fprintf(ready, "%d\n", CONJET_NETD_PORT);
        fclose(ready);
    }
    fprintf(stderr, "conjet-netd: listening on VSOCK port %d\n", CONJET_NETD_PORT);
    while (1) {
        struct sockaddr_vm peer;
        socklen_t peer_len = sizeof(peer);
        memset(&peer, 0, sizeof(peer));
        int client = accept(listener, (struct sockaddr *)&peer, &peer_len);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            continue;
        }
        if (!is_host_vsock_peer(&peer, peer_len)) {
            close(client);
            continue;
        }
        struct client_args *args = calloc(1, sizeof(*args));
        if (args == NULL) {
            close(client);
            continue;
        }
        args->fd = client;
        pthread_t thread;
        if (pthread_create(&thread, NULL, handle_client, args) == 0) {
            pthread_detach(thread);
        } else {
            close(client);
            free(args);
        }
    }
}
