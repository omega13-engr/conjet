#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/vm_sockets.h>
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
#include <sys/types.h>
#include <sys/un.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif

#define CONJET_NETD_PORT 2375
#define DOCKER_UNIX_SOCKET "/var/run/docker.sock"
#define FRAME_MAGIC 0x434a4e54U
#define FRAME_VERSION 1
#define FRAME_HEADER_SIZE 20
#define FRAME_MAX_PAYLOAD (1024 * 1024)

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
    struct sockaddr_in udp_addr;
    int udp_addr_ready;
    struct target *next;
};

struct client_args {
    int fd;
};

struct pump_args {
    int from;
    int to;
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

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, p + done, len - done);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
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
            struct pollfd pfd = {.fd = fd, .events = POLLOUT};
            if (poll(&pfd, 1, 5000) <= 0) {
                return -1;
            }
        } else {
            return -1;
        }
    }
    return 0;
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
        "{\"version\":5,"
        "\"capabilities\":{\"tcp_proxy\":true,\"udp_proxy\":true,\"docker_events\":true,"
        "\"container_ip_lookup\":true,\"container_target_events\":true,\"port_probe\":true,\"proxy_metrics\":true,"
        "\"guest_echo\":true,\"guest_metrics\":true,\"binary_frames\":true,"
        "\"udp_binary_frames\":true,\"persistent_vsock\":true,"
        "\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true,"
        "\"bridge_engine\":\"conjet-netd-c\"},"
        "\"lazy_upstream\":true,\"docker_ready_cache\":true,"
        "\"tcp_proxy\":true,\"udp_proxy\":true,\"guest_echo\":true,\"guest_metrics\":true,"
        "\"binary_frames\":true,\"udp_binary_frames\":true,\"persistent_vsock\":true,"
        "\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true}\n";
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
        if ((size_t)(end - readp) < chunk_len + 2) {
            return -1;
        }
        memmove(writep, readp, chunk_len);
        writep += chunk_len;
        readp += chunk_len;
        if (readp + 1 > end || readp[0] != '\r' || readp[1] != '\n') {
            return -1;
        }
        readp += 2;
    }
    return -1;
}

static void write_container_targets(int client) {
    int upstream = connect_unix_socket(DOCKER_UNIX_SOCKET);
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
    int upstream = connect_unix_socket(DOCKER_UNIX_SOCKET);
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

static int emit_container_targets_snapshot(int client) {
    char body[65536];
    ssize_t n = fetch_container_targets_body(body, sizeof(body));
    if (n <= 0) {
        return -1;
    }
    return write_full(client, body, (size_t)n);
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
    (void)emit_container_targets_snapshot(client);

    int upstream = connect_unix_socket(DOCKER_UNIX_SOCKET);
    if (upstream < 0) {
        close_fd(client);
        return;
    }
    const char *request =
        "GET /events HTTP/1.1\r\n"
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
            offset = (size_t)(header_end - buf);
            header_done = 1;
        }

        for (size_t i = offset; i < used; i++) {
            if (buf[i] == '\n') {
                if (emit_container_targets_snapshot(client) != 0) {
                    close_fd(upstream);
                    close_fd(client);
                    return;
                }
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
    if (t->udp_fd < 0) {
        t->udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (t->udp_fd < 0) {
            pthread_mutex_unlock(&t->io_lock);
            return -1;
        }
        struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(t->udp_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    if (!t->udp_addr_ready) {
        memset(&t->udp_addr, 0, sizeof(t->udp_addr));
        t->udp_addr.sin_family = AF_INET;
        t->udp_addr.sin_port = htons(t->port);
        if (inet_pton(AF_INET, t->host, &t->udp_addr.sin_addr) != 1) {
            pthread_mutex_unlock(&t->io_lock);
            return -1;
        }
        t->udp_addr_ready = 1;
    }
    if (sendto(t->udp_fd, payload, payload_len, 0, (struct sockaddr *)&t->udp_addr, sizeof(t->udp_addr)) >= 0) {
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
    int upstream = connect_unix_socket(DOCKER_UNIX_SOCKET);
    if (upstream < 0) {
        write_http_response(client, "503 Service Unavailable", "text/plain", "Conjet guest bridge could not connect to Docker\n");
        close_fd(client);
        return;
    }
    if (first_len > 0 && write_full(upstream, first, first_len) != 0) {
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
    ba->from = upstream;
    ba->to = client;
    pthread_create(&a, NULL, pump_thread, ab);
    pthread_create(&b, NULL, pump_thread, ba);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
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
    ba->from = upstream;
    ba->to = client;
    pthread_create(&a, NULL, pump_thread, ab);
    pthread_create(&b, NULL, pump_thread, ba);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
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
    int upstream = socket(AF_INET, SOCK_DGRAM, 0);
    if (upstream < 0) {
        close_fd(client);
        return;
    }
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(upstream, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &addr.sin_addr);
    metric_inc(&g_metrics.udp_packets_in);
    if (sendto(upstream, payload, payload_len, 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
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
    if (n >= 32 && memcmp(first, "GET /conjet-bridge-capabilities ", 32) == 0) {
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
            puts("{\"version\":5,\"tcp_proxy\":true,\"udp_proxy\":true,\"docker_events\":true,\"container_ip_lookup\":true,\"container_target_events\":true,\"port_probe\":true,\"guest_echo\":true,\"guest_metrics\":true,\"binary_frames\":true,\"udp_binary_frames\":true,\"persistent_vsock\":true,\"tcp_binary_frames\":true,\"persistent_tcp_vsock\":true,\"tcp_vsock_pool\":true,\"bridge_engine\":\"conjet-netd-c\"}");
            return 0;
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
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
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
