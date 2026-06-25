#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#ifdef __linux__
#include <linux/vm_sockets.h>
#include <sys/inotify.h>
#else
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef IN_NONBLOCK
#define IN_NONBLOCK O_NONBLOCK
#endif
#ifndef IN_CLOEXEC
#define IN_CLOEXEC O_CLOEXEC
#endif
#ifndef IN_MODIFY
#define IN_MODIFY 0x00000002
#endif
#ifndef IN_ATTRIB
#define IN_ATTRIB 0x00000004
#endif
struct sockaddr_vm {
    sa_family_t svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[
        sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) -
        sizeof(unsigned int) - sizeof(unsigned int)
    ];
};
static int inotify_init1(int flags) {
    (void)flags;
    errno = ENOSYS;
    return -1;
}
static int inotify_add_watch(int fd, const char *path, uint32_t mask) {
    (void)fd;
    (void)path;
    (void)mask;
    errno = ENOSYS;
    return -1;
}
#endif

#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xffffffffU
#endif

#define CONJET_MEMD_PORT 2376
#define MAX_CGROUP_DEPTH 8
#define MIN_EVENT_INTERVAL_MS 1000
#define MAX_MEMORY_HARD_DROP_RANGES 256

struct memory_metrics {
    uint64_t mem_total;
    uint64_t mem_available;
    uint64_t mem_free;
    uint64_t page_cache_bytes;
    uint64_t sreclaimable_bytes;
    uint64_t swap_total;
    uint64_t swap_free;
    uint64_t disk_swap_total;
    uint64_t disk_swap_free;
    uint64_t zram_orig_data_size;
    uint64_t zram_compr_data_size;
    uint64_t zram_mem_used_total;
    uint64_t container_memory_current;
    uint64_t container_memory_peak;
    uint64_t container_anon;
    uint64_t container_file;
    uint64_t container_inactive_file;
    uint64_t container_active_file;
    uint64_t container_slab_reclaimable;
    uint64_t container_slab_unreclaimable;
    uint64_t container_swap_current;
    uint64_t container_memory_high_events;
    uint64_t container_memory_oom_events;
    uint64_t container_memory_oom_kill_events;
    uint64_t build_cgroup_memory_current;
    uint64_t daemon_cgroup_memory_current;
    uint64_t service_cgroup_memory_current;
    double psi_some_avg10;
    double psi_full_avg10;
    int active_workloads;
    bool build_workload_detected;
};

enum reclaim_state {
    RECLAIM_IDLE,
    RECLAIM_QUEUED,
    RECLAIM_CANCELLED,
    RECLAIM_DONE,
    RECLAIM_ERROR,
};

struct reclaim_status {
    uint64_t epoch;
    uint64_t requested_bytes;
    uint64_t observed_current_drop_bytes;
    enum reclaim_state state;
    int error_number;
    char reason[64];
};

struct memory_hard_drop_range {
    uint64_t start;
    uint64_t size;
};

struct memory_hard_drop_result {
    bool accepted;
    uint64_t requested_bytes;
    uint64_t offlined_bytes;
    uint64_t failed_bytes;
    size_t candidate_count;
    size_t range_count;
    size_t failed_count;
    int error_number;
    int last_failed_error_number;
    uint64_t last_failed_start;
    uint64_t last_failed_size;
    char message[128];
    struct memory_hard_drop_range ranges[MAX_MEMORY_HARD_DROP_RANGES];
};

static pthread_mutex_t reclaim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t reclaim_cond = PTHREAD_COND_INITIALIZER;
static pid_t reclaim_worker_pid = -1;
static uint64_t reclaim_pending_epoch = 0;
static pthread_t reclaim_monitor_thread;
static bool reclaim_monitor_started = false;
static struct reclaim_status reclaim_status_state = {
    .epoch = 0,
    .requested_bytes = 0,
    .observed_current_drop_bytes = 0,
    .state = RECLAIM_IDLE,
    .reason = "",
};

static void write_http_response(int fd, const char *status, const char *content_type, const char *body);

static void close_fd(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

static int write_full(int fd, const void *data, size_t len) {
    const char *ptr = (const char *)data;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, ptr + off, len - off);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static int64_t monotonic_millis(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((int64_t)ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

static void sleep_millis(int64_t millis) {
    if (millis <= 0) {
        return;
    }
    struct timespec req;
    req.tv_sec = (time_t)(millis / 1000);
    req.tv_nsec = (long)((millis % 1000) * 1000000);
    while (nanosleep(&req, &req) != 0 && errno == EINTR) {}
}

static uint64_t read_uint_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return 0;
    }
    unsigned long long value = 0;
    if (fscanf(f, "%llu", &value) != 1) {
        value = 0;
    }
    fclose(f);
    return (uint64_t)value;
}

static void add_memory_stat(const char *path, struct memory_metrics *metrics) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        uint64_t bytes = (uint64_t)value;
        if (strcmp(key, "anon") == 0) {
            metrics->container_anon += bytes;
        } else if (strcmp(key, "file") == 0) {
            metrics->container_file += bytes;
        } else if (strcmp(key, "inactive_file") == 0) {
            metrics->container_inactive_file += bytes;
        } else if (strcmp(key, "active_file") == 0) {
            metrics->container_active_file += bytes;
        } else if (strcmp(key, "slab_reclaimable") == 0) {
            metrics->container_slab_reclaimable += bytes;
        } else if (strcmp(key, "slab_unreclaimable") == 0) {
            metrics->container_slab_unreclaimable += bytes;
        }
    }
    fclose(f);
}

static void add_memory_events(const char *path, struct memory_metrics *metrics) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        if (strcmp(key, "high") == 0) {
            metrics->container_memory_high_events += (uint64_t)value;
        } else if (strcmp(key, "oom") == 0) {
            metrics->container_memory_oom_events += (uint64_t)value;
        } else if (strcmp(key, "oom_kill") == 0) {
            metrics->container_memory_oom_kill_events += (uint64_t)value;
        }
    }
    fclose(f);
}

static bool path_contains_container_marker(const char *path) {
    return strstr(path, "containerd-") != NULL ||
           strstr(path, "containerd/") != NULL ||
           strstr(path, "containerd:") != NULL ||
           strstr(path, "docker-") != NULL ||
           strstr(path, "docker/") != NULL ||
           strstr(path, "docker:") != NULL ||
           strstr(path, "moby") != NULL;
}

static bool path_is_build_cgroup(const char *path) {
    return strstr(path, "/conjet-build.slice") != NULL ||
           strstr(path, "/conjet-build.slice/") != NULL ||
           strstr(path, ".slice/conjet-build.slice") != NULL;
}

static void scan_cgroups(const char *dir, int depth, struct memory_metrics *metrics) {
    if (depth > MAX_CGROUP_DEPTH) {
        return;
    }
    DIR *d = opendir(dir);
    if (d == NULL) {
        return;
    }
    if (path_is_build_cgroup(dir)) {
        closedir(d);
        return;
    }

    char memory_current[4096];
    snprintf(memory_current, sizeof(memory_current), "%s/memory.current", dir);
    if (path_contains_container_marker(dir)) {
        uint64_t current = read_uint_file(memory_current);
        if (current > 0) {
            char memory_peak[4096];
            char memory_stat[4096];
            char memory_events[4096];
            char memory_swap_current[4096];
            metrics->container_memory_current += current;
            metrics->active_workloads += 1;
            snprintf(memory_peak, sizeof(memory_peak), "%s/memory.peak", dir);
            uint64_t peak = read_uint_file(memory_peak);
            if (peak == 0) {
                peak = current;
            }
            if (peak > metrics->container_memory_peak) {
                metrics->container_memory_peak = peak;
            }
            snprintf(memory_stat, sizeof(memory_stat), "%s/memory.stat", dir);
            add_memory_stat(memory_stat, metrics);
            snprintf(memory_events, sizeof(memory_events), "%s/memory.events", dir);
            add_memory_events(memory_events, metrics);
            snprintf(memory_swap_current, sizeof(memory_swap_current), "%s/memory.swap.current", dir);
            metrics->container_swap_current += read_uint_file(memory_swap_current);
            closedir(d);
            return;
        }
    }

    struct dirent *entry;
    while ((entry = readdir(d)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char child[4096];
        snprintf(child, sizeof(child), "%s/%s", dir, entry->d_name);
        struct stat st;
        if (stat(child, &st) == 0 && S_ISDIR(st.st_mode)) {
            scan_cgroups(child, depth + 1, metrics);
        }
    }
    closedir(d);
}

static const char *configured_cgroup_path(const char *env_name, const char *fallback) {
    const char *path = getenv(env_name);
    if (path != NULL && path[0] != '\0') {
        return path;
    }
    return fallback;
}

static uint64_t read_cgroup_current(const char *cgroup) {
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/memory.current", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return 0;
    }
    return read_uint_file(path);
}

static bool read_cgroup_populated(const char *cgroup) {
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/cgroup.events", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return false;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    char key[128];
    unsigned long long value = 0;
    bool populated = false;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        if (strcmp(key, "populated") == 0) {
            populated = value != 0;
            break;
        }
    }
    fclose(f);
    return populated;
}

static uint64_t saturating_add_u64(uint64_t lhs, uint64_t rhs) {
    return UINT64_MAX - lhs < rhs ? UINT64_MAX : lhs + rhs;
}

struct build_cgroup_snapshot {
    uint64_t memory_current;
    bool populated;
};

static int split_parent_basename(const char *path, char *parent, size_t parent_len, const char **basename) {
    const char *slash = strrchr(path, '/');
    if (slash == NULL || slash == path || slash[1] == '\0') {
        return -1;
    }
    size_t len = (size_t)(slash - path);
    if (len + 1 > parent_len) {
        return -1;
    }
    memcpy(parent, path, len);
    parent[len] = '\0';
    *basename = slash + 1;
    return 0;
}

static bool cgroup_name_has_prefixed_scope(const char *name, const char *prefix) {
    size_t prefix_len = strlen(prefix);
    return strncmp(name, prefix, prefix_len) == 0 && name[prefix_len] == ':';
}

static struct build_cgroup_snapshot read_build_cgroup_snapshot(const char *cgroup) {
    struct build_cgroup_snapshot snapshot = {
        .memory_current = read_cgroup_current(cgroup),
        .populated = read_cgroup_populated(cgroup),
    };
    char parent[4096];
    const char *basename = NULL;
    if (split_parent_basename(cgroup, parent, sizeof(parent), &basename) != 0) {
        return snapshot;
    }
    DIR *dir = opendir(parent);
    if (dir == NULL) {
        return snapshot;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!cgroup_name_has_prefixed_scope(entry->d_name, basename)) {
            continue;
        }
        char child[4096];
        int written = snprintf(child, sizeof(child), "%s/%s", parent, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(child)) {
            continue;
        }
        snapshot.memory_current =
            saturating_add_u64(snapshot.memory_current, read_cgroup_current(child));
        snapshot.populated = snapshot.populated || read_cgroup_populated(child);
    }
    closedir(dir);
    return snapshot;
}

static void read_configured_cgroup_metrics(struct memory_metrics *metrics) {
    const char *build_cgroup = configured_cgroup_path(
        "CONJET_RECLAIM_BUILD_CGROUP",
        "/sys/fs/cgroup/conjet.slice/conjet-build.slice"
    );
    const char *daemon_cgroup = configured_cgroup_path(
        "CONJET_RECLAIM_DAEMON_CGROUP",
        "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice"
    );
    const char *service_cgroup = configured_cgroup_path(
        "CONJET_SERVICE_CGROUP",
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice"
    );

    struct build_cgroup_snapshot build_snapshot = read_build_cgroup_snapshot(build_cgroup);
    metrics->build_cgroup_memory_current = build_snapshot.memory_current;
    metrics->build_workload_detected = build_snapshot.populated;
    metrics->daemon_cgroup_memory_current = read_cgroup_current(daemon_cgroup);
    metrics->service_cgroup_memory_current = read_cgroup_current(service_cgroup);
}

static void read_meminfo(struct memory_metrics *metrics) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (f == NULL) {
        return;
    }
    char line[512];
    while (fgets(line, sizeof(line), f) != NULL) {
        char key[128];
        unsigned long long value_kib = 0;
        if (sscanf(line, "%127[^:]: %llu kB", key, &value_kib) != 2) {
            continue;
        }
        uint64_t bytes = (uint64_t)value_kib * 1024ULL;
        if (strcmp(key, "MemTotal") == 0) {
            metrics->mem_total = bytes;
        } else if (strcmp(key, "MemAvailable") == 0) {
            metrics->mem_available = bytes;
        } else if (strcmp(key, "MemFree") == 0) {
            metrics->mem_free = bytes;
        } else if (strcmp(key, "Cached") == 0 || strcmp(key, "Buffers") == 0) {
            metrics->page_cache_bytes += bytes;
        } else if (strcmp(key, "SReclaimable") == 0) {
            metrics->sreclaimable_bytes = bytes;
            metrics->page_cache_bytes += bytes;
        }
    }
    fclose(f);
}

static double parse_avg10(const char *line) {
    const char *needle = strstr(line, "avg10=");
    if (needle == NULL) {
        return 0.0;
    }
    return strtod(needle + 6, NULL);
}

static void read_psi(struct memory_metrics *metrics) {
    FILE *f = fopen("/proc/pressure/memory", "r");
    if (f == NULL) {
        return;
    }
    char line[512];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "some ", 5) == 0) {
            metrics->psi_some_avg10 = parse_avg10(line);
        } else if (strncmp(line, "full ", 5) == 0) {
            metrics->psi_full_avg10 = parse_avg10(line);
        }
    }
    fclose(f);
}

static void read_swaps(struct memory_metrics *metrics) {
    FILE *f = fopen("/proc/swaps", "r");
    if (f == NULL) {
        return;
    }
    char line[512];
    if (fgets(line, sizeof(line), f) == NULL) {
        fclose(f);
        return;
    }
    while (fgets(line, sizeof(line), f) != NULL) {
        char filename[256];
        char type[64];
        unsigned long long size_kib = 0;
        unsigned long long used_kib = 0;
        int priority = 0;
        if (sscanf(line, "%255s %63s %llu %llu %d", filename, type, &size_kib, &used_kib, &priority) < 4) {
            continue;
        }
        uint64_t total = (uint64_t)size_kib * 1024ULL;
        uint64_t used = (uint64_t)used_kib * 1024ULL;
        uint64_t free_bytes = total > used ? total - used : 0;
        metrics->swap_total += total;
        metrics->swap_free += free_bytes;
        if (strstr(filename, "zram") == NULL) {
            metrics->disk_swap_total += total;
            metrics->disk_swap_free += free_bytes;
        }
    }
    fclose(f);
}

static void read_zram(struct memory_metrics *metrics) {
    DIR *d = opendir("/sys/block");
    if (d == NULL) {
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(d)) != NULL) {
        if (strncmp(entry->d_name, "zram", 4) != 0) {
            continue;
        }
        char mm_stat[4096];
        snprintf(mm_stat, sizeof(mm_stat), "/sys/block/%s/mm_stat", entry->d_name);
        FILE *f = fopen(mm_stat, "r");
        if (f == NULL) {
            continue;
        }
        unsigned long long orig = 0;
        unsigned long long compr = 0;
        unsigned long long used = 0;
        if (fscanf(f, "%llu %llu %llu", &orig, &compr, &used) == 3) {
            metrics->zram_orig_data_size += (uint64_t)orig;
            metrics->zram_compr_data_size += (uint64_t)compr;
            metrics->zram_mem_used_total += (uint64_t)used;
        }
        fclose(f);
    }
    closedir(d);
}

static struct memory_metrics collect_metrics(void) {
    struct memory_metrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    read_meminfo(&metrics);
    read_psi(&metrics);
    read_swaps(&metrics);
    read_zram(&metrics);
    read_configured_cgroup_metrics(&metrics);
    scan_cgroups("/sys/fs/cgroup", 0, &metrics);
    return metrics;
}

static void metrics_json(const struct memory_metrics *metrics, char *body, size_t body_len) {
    snprintf(body, body_len,
        "{\"mem_total\":%llu,\"mem_available\":%llu,\"mem_free\":%llu,"
        "\"page_cache_bytes\":%llu,\"sreclaimable_bytes\":%llu,"
        "\"swap_total\":%llu,\"swap_free\":%llu,"
        "\"disk_swap_total\":%llu,\"disk_swap_free\":%llu,"
        "\"zram_orig_data_size\":%llu,\"zram_compr_data_size\":%llu,"
        "\"zram_mem_used_total\":%llu,"
        "\"container_memory_current\":%llu,\"container_memory_peak\":%llu,"
        "\"container_anon\":%llu,\"container_file\":%llu,"
        "\"container_inactive_file\":%llu,\"container_active_file\":%llu,"
        "\"container_slab_reclaimable\":%llu,\"container_slab_unreclaimable\":%llu,"
        "\"container_swap_current\":%llu,"
        "\"container_memory_high_events\":%llu,"
        "\"container_memory_oom_events\":%llu,"
        "\"container_memory_oom_kill_events\":%llu,"
        "\"build_cgroup_memory_current\":%llu,"
        "\"daemon_cgroup_memory_current\":%llu,"
        "\"service_cgroup_memory_current\":%llu,"
        "\"psi_some_avg10\":%.2f,\"psi_full_avg10\":%.2f,"
        "\"active_workloads\":%d,\"build_workload_detected\":%s,"
        "\"source\":\"conjet-memd\"}\n",
        (unsigned long long)metrics->mem_total,
        (unsigned long long)metrics->mem_available,
        (unsigned long long)metrics->mem_free,
        (unsigned long long)metrics->page_cache_bytes,
        (unsigned long long)metrics->sreclaimable_bytes,
        (unsigned long long)metrics->swap_total,
        (unsigned long long)metrics->swap_free,
        (unsigned long long)metrics->disk_swap_total,
        (unsigned long long)metrics->disk_swap_free,
        (unsigned long long)metrics->zram_orig_data_size,
        (unsigned long long)metrics->zram_compr_data_size,
        (unsigned long long)metrics->zram_mem_used_total,
        (unsigned long long)metrics->container_memory_current,
        (unsigned long long)metrics->container_memory_peak,
        (unsigned long long)metrics->container_anon,
        (unsigned long long)metrics->container_file,
        (unsigned long long)metrics->container_inactive_file,
        (unsigned long long)metrics->container_active_file,
        (unsigned long long)metrics->container_slab_reclaimable,
        (unsigned long long)metrics->container_slab_unreclaimable,
        (unsigned long long)metrics->container_swap_current,
        (unsigned long long)metrics->container_memory_high_events,
        (unsigned long long)metrics->container_memory_oom_events,
        (unsigned long long)metrics->container_memory_oom_kill_events,
        (unsigned long long)metrics->build_cgroup_memory_current,
        (unsigned long long)metrics->daemon_cgroup_memory_current,
        (unsigned long long)metrics->service_cgroup_memory_current,
        metrics->psi_some_avg10,
        metrics->psi_full_avg10,
        metrics->active_workloads,
        metrics->build_workload_detected ? "true" : "false");
}

static const char *reclaim_state_name(enum reclaim_state state) {
    switch (state) {
    case RECLAIM_IDLE:
        return "idle";
    case RECLAIM_QUEUED:
        return "queued";
    case RECLAIM_CANCELLED:
        return "cancelled";
    case RECLAIM_DONE:
        return "done";
    case RECLAIM_ERROR:
        return "error";
    }
    return "unknown";
}

static void extract_reclaim_reason(const char *request, char *reason, size_t reason_len) {
    const char *cursor = strstr(request, "reason=");
    if (cursor == NULL || reason_len == 0) {
        snprintf(reason, reason_len, "unknown");
        return;
    }
    cursor += strlen("reason=");
    size_t offset = 0;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '&' && offset + 1 < reason_len) {
        reason[offset++] = *cursor++;
    }
    reason[offset] = '\0';
}

static uint64_t extract_query_u64(const char *request, const char *name) {
    char needle[64];
    snprintf(needle, sizeof(needle), "%s=", name);
    const char *cursor = strstr(request, needle);
    if (cursor == NULL) {
        return 0;
    }
    cursor += strlen(needle);
    return strtoull(cursor, NULL, 10);
}

static const char *configured_memory_sysfs_root(void) {
    const char *root = getenv("CONJET_MEMORY_SYSFS_ROOT");
    if (root != NULL && root[0] != '\0') {
        return root;
    }
    return "/sys/devices/system/memory";
}

static int join_memory_path(char *out, size_t out_len, const char *lhs, const char *rhs) {
    int written = snprintf(out, out_len, "%s/%s", lhs, rhs);
    return written > 0 && (size_t)written < out_len ? 0 : ENAMETOOLONG;
}

static bool read_text_file(const char *path, char *out, size_t out_len) {
    if (out_len == 0) {
        return false;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    size_t n = fread(out, 1, out_len - 1, f);
    fclose(f);
    out[n] = '\0';
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' ' || out[n - 1] == '\t')) {
        out[--n] = '\0';
    }
    return n > 0;
}

static bool read_memory_u64_file(const char *path, uint64_t *value) {
    char text[64];
    if (!read_text_file(path, text, sizeof(text))) {
        return false;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno != 0 || end == text) {
        return false;
    }
    *value = (uint64_t)parsed;
    return true;
}

static bool write_text_file(const char *path, const char *value, int *error_out) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        if (error_out != NULL) {
            *error_out = errno == 0 ? EIO : errno;
        }
        return false;
    }
    bool ok = write_full(fd, value, strlen(value)) == 0;
    int saved = ok ? 0 : (errno == 0 ? EIO : errno);
    if (close(fd) != 0 && saved == 0) {
        saved = errno == 0 ? EIO : errno;
        ok = false;
    }
    if (error_out != NULL) {
        *error_out = saved;
    }
    return ok;
}

struct memory_block_candidate {
    uint64_t start;
    uint64_t size;
    char state_path[4096];
};

static int compare_memory_block_desc(const void *lhs, const void *rhs) {
    const struct memory_block_candidate *a = (const struct memory_block_candidate *)lhs;
    const struct memory_block_candidate *b = (const struct memory_block_candidate *)rhs;
    if (a->start < b->start) {
        return 1;
    }
    if (a->start > b->start) {
        return -1;
    }
    return 0;
}

static bool memory_entry_index(const char *name, uint64_t *index_out) {
    if (strncmp(name, "memory", 6) != 0 || name[6] == '\0') {
        return false;
    }
    const char *cursor = name + 6;
    for (const char *p = cursor; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') {
            return false;
        }
    }
    *index_out = strtoull(cursor, NULL, 10);
    return true;
}

static size_t collect_removable_memory_blocks(
    const char *root,
    uint64_t block_size,
    struct memory_block_candidate *candidates,
    size_t candidate_capacity
) {
    DIR *dir = opendir(root);
    if (dir == NULL) {
        return 0;
    }
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (count >= candidate_capacity) {
            break;
        }
        uint64_t fallback_index = 0;
        if (!memory_entry_index(entry->d_name, &fallback_index)) {
            continue;
        }
        char block_dir[4096];
        char state_path[4096];
        char removable_path[4096];
        char phys_index_path[4096];
        char state[64];
        uint64_t removable = 0;
        uint64_t phys_index = fallback_index;
        if (join_memory_path(block_dir, sizeof(block_dir), root, entry->d_name) != 0 ||
            join_memory_path(state_path, sizeof(state_path), block_dir, "state") != 0 ||
            join_memory_path(removable_path, sizeof(removable_path), block_dir, "removable") != 0 ||
            join_memory_path(phys_index_path, sizeof(phys_index_path), block_dir, "phys_index") != 0) {
            continue;
        }
        if (!read_text_file(state_path, state, sizeof(state)) ||
            strncmp(state, "online", strlen("online")) != 0 ||
            !read_memory_u64_file(removable_path, &removable) ||
            removable == 0) {
            continue;
        }
        (void)read_memory_u64_file(phys_index_path, &phys_index);
        candidates[count].start = phys_index * block_size;
        candidates[count].size = block_size;
        snprintf(candidates[count].state_path, sizeof(candidates[count].state_path), "%s", state_path);
        count++;
    }
    closedir(dir);
    qsort(candidates, count, sizeof(candidates[0]), compare_memory_block_desc);
    return count;
}

static struct memory_hard_drop_result offline_guest_memory_blocks(uint64_t requested_bytes) {
    struct memory_hard_drop_result result;
    memset(&result, 0, sizeof(result));
    result.requested_bytes = requested_bytes;
    result.accepted = false;
    snprintf(result.message, sizeof(result.message), "not attempted");

    if (requested_bytes == 0) {
        result.error_number = EINVAL;
        snprintf(result.message, sizeof(result.message), "bytes must be greater than zero");
        return result;
    }

    const char *root = configured_memory_sysfs_root();
    char block_size_path[4096];
    uint64_t block_size = 0;
    if (join_memory_path(block_size_path, sizeof(block_size_path), root, "block_size_bytes") != 0 ||
        !read_memory_u64_file(block_size_path, &block_size) ||
        block_size == 0) {
        result.error_number = ENOENT;
        snprintf(result.message, sizeof(result.message), "memory block size is unavailable");
        return result;
    }

    struct memory_block_candidate candidates[MAX_MEMORY_HARD_DROP_RANGES];
    size_t candidate_count = collect_removable_memory_blocks(
        root,
        block_size,
        candidates,
        MAX_MEMORY_HARD_DROP_RANGES
    );
    result.candidate_count = candidate_count;
    if (candidate_count == 0) {
        result.error_number = ENODATA;
        snprintf(result.message, sizeof(result.message), "no removable online memory blocks");
        return result;
    }

    for (size_t i = 0; i < candidate_count && result.offlined_bytes < requested_bytes; i++) {
        int write_error = 0;
        if (!write_text_file(candidates[i].state_path, "offline\n", &write_error)) {
            int saved = write_error == 0 ? EIO : write_error;
            result.failed_count++;
            result.failed_bytes += candidates[i].size;
            result.last_failed_error_number = saved;
            result.last_failed_start = candidates[i].start;
            result.last_failed_size = candidates[i].size;
            if (result.error_number == 0) {
                result.error_number = saved;
            }
            continue;
        }
        result.ranges[result.range_count].start = candidates[i].start;
        result.ranges[result.range_count].size = candidates[i].size;
        result.range_count++;
        result.offlined_bytes += candidates[i].size;
    }

    result.accepted = result.offlined_bytes > 0;
    if (result.accepted) {
        result.error_number = 0;
        snprintf(result.message, sizeof(result.message), "offlined %llu bytes across %zu memory blocks",
                 (unsigned long long)result.offlined_bytes,
                 result.range_count);
    } else if (result.error_number == 0) {
        result.error_number = EBUSY;
        snprintf(result.message, sizeof(result.message), "removable memory blocks could not be offlined");
    } else {
        snprintf(result.message, sizeof(result.message),
                 "memory block offline failed: %zu of %zu candidates failed, last errno %d (%s)",
                 result.failed_count,
                 result.candidate_count,
                 result.last_failed_error_number,
                 strerror(result.last_failed_error_number));
    }
    return result;
}

static void memory_hard_drop_json(
    char *body,
    size_t body_len,
    const struct memory_hard_drop_result *result
) {
    size_t offset = 0;
    int n = snprintf(body, body_len,
        "{\"accepted\":%s,\"requested_bytes\":%llu,\"offlined_bytes\":%llu,"
        "\"failed_bytes\":%llu,\"candidate_count\":%zu,"
        "\"range_count\":%zu,\"failed_count\":%zu,"
        "\"error_number\":%d,\"last_failed_error_number\":%d,"
        "\"last_failed_start\":%llu,\"last_failed_size\":%llu,"
        "\"message\":\"%s\",\"ranges\":[",
        result->accepted ? "true" : "false",
        (unsigned long long)result->requested_bytes,
        (unsigned long long)result->offlined_bytes,
        (unsigned long long)result->failed_bytes,
        result->candidate_count,
        result->range_count,
        result->failed_count,
        result->error_number,
        result->last_failed_error_number,
        (unsigned long long)result->last_failed_start,
        (unsigned long long)result->last_failed_size,
        result->message);
    if (n < 0) {
        return;
    }
    offset = (size_t)n < body_len ? (size_t)n : body_len;
    for (size_t i = 0; i < result->range_count && offset < body_len; i++) {
        n = snprintf(body + offset, body_len - offset,
            "%s{\"start\":%llu,\"size\":%llu}",
            i == 0 ? "" : ",",
            (unsigned long long)result->ranges[i].start,
            (unsigned long long)result->ranges[i].size);
        if (n < 0) {
            return;
        }
        offset += (size_t)n < body_len - offset ? (size_t)n : body_len - offset;
    }
    if (offset < body_len) {
        snprintf(body + offset, body_len - offset, "],\"source\":\"conjet-memd\"}\n");
    } else if (body_len > 0) {
        body[body_len - 1] = '\0';
    }
}

static void reclaim_submission_json(char *body, size_t body_len, const struct reclaim_status *status, bool accepted) {
    snprintf(body, body_len,
        "{\"accepted\":%s,\"epoch\":%llu,\"state\":\"%s\",\"error_number\":%d,\"source\":\"conjet-memd\"}\n",
        accepted ? "true" : "false",
        (unsigned long long)status->epoch,
        reclaim_state_name(status->state),
        status->error_number);
}

static void reclaim_status_json(char *body, size_t body_len, const struct reclaim_status *status) {
    snprintf(body, body_len,
        "{\"epoch\":%llu,\"state\":\"%s\","
        "\"requested_bytes\":%llu,\"observed_current_drop_bytes\":%llu,"
        "\"error_number\":%d,"
        "\"source\":\"conjet-memd\"}\n",
        (unsigned long long)status->epoch,
        reclaim_state_name(status->state),
        (unsigned long long)status->requested_bytes,
        (unsigned long long)status->observed_current_drop_bytes,
        status->error_number);
}

static int spawn_reclaim_worker(uint64_t epoch, pid_t *pid_out) {
    char epoch_arg[32];
    const char *worker_path = getenv("CONJET_RECLAIMD_PATH");
    if (worker_path == NULL || worker_path[0] == '\0') {
        worker_path = "/usr/local/sbin/conjet-reclaimd";
    }
    snprintf(epoch_arg, sizeof(epoch_arg), "%llu", (unsigned long long)epoch);
    char *const argv[] = {
        "conjet-reclaimd",
        "--epoch",
        epoch_arg,
        NULL
    };
    pid_t pid = -1;
    int rc = posix_spawn(&pid, worker_path, NULL, NULL, argv, environ);
    if (rc != 0) {
        return rc;
    }
    *pid_out = pid;
    return 0;
}

static void *reclaim_monitor_main(void *arg) {
    (void)arg;
    pthread_mutex_lock(&reclaim_lock);
    for (;;) {
        while (reclaim_worker_pid <= 0) {
            pthread_cond_wait(&reclaim_cond, &reclaim_lock);
        }
        pid_t pid = reclaim_worker_pid;
        pthread_mutex_unlock(&reclaim_lock);

        int status = 0;
        int wait_rc = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno == EINTR) {
                continue;
            }
            wait_rc = errno == 0 ? ECHILD : errno;
            break;
        }

        pthread_mutex_lock(&reclaim_lock);
        if (reclaim_worker_pid == pid) {
            reclaim_worker_pid = -1;
        }
        if (reclaim_pending_epoch != 0) {
            uint64_t epoch = reclaim_pending_epoch;
            reclaim_pending_epoch = 0;
            pid_t next = -1;
            int spawn_rc = spawn_reclaim_worker(epoch, &next);
            if (spawn_rc == 0) {
                reclaim_worker_pid = next;
                reclaim_status_state.state = RECLAIM_QUEUED;
                reclaim_status_state.error_number = 0;
                pthread_cond_signal(&reclaim_cond);
            } else {
                reclaim_status_state.state = RECLAIM_ERROR;
                reclaim_status_state.error_number = spawn_rc;
            }
        } else if (reclaim_status_state.state == RECLAIM_QUEUED) {
            if (wait_rc != 0) {
                reclaim_status_state.state = RECLAIM_ERROR;
                reclaim_status_state.error_number = wait_rc;
            } else if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                reclaim_status_state.state = RECLAIM_DONE;
                reclaim_status_state.error_number = 0;
            } else {
                reclaim_status_state.state = RECLAIM_ERROR;
                reclaim_status_state.error_number = WIFEXITED(status) ? WEXITSTATUS(status) : EINTR;
            }
        }
    }
    return NULL;
}

static int start_reclaim_monitor_locked(void) {
    if (reclaim_monitor_started) {
        return 0;
    }
    int rc = pthread_create(&reclaim_monitor_thread, NULL, reclaim_monitor_main, NULL);
    if (rc != 0) {
        return rc;
    }
    pthread_detach(reclaim_monitor_thread);
    reclaim_monitor_started = true;
    return 0;
}

static int submit_reclaim_worker_locked(uint64_t epoch) {
    int rc = start_reclaim_monitor_locked();
    if (rc != 0) {
        return rc;
    }
    if (reclaim_worker_pid > 0) {
        reclaim_pending_epoch = epoch;
        pthread_cond_signal(&reclaim_cond);
        return 0;
    }
    pid_t pid = -1;
    rc = spawn_reclaim_worker(epoch, &pid);
    if (rc != 0) {
        return rc;
    }
    reclaim_worker_pid = pid;
    pthread_cond_signal(&reclaim_cond);
    return 0;
}

static void write_reclaim_submission_response(int client, const char *request) {
    struct reclaim_status snapshot;
    char reason[64];
    extract_reclaim_reason(request, reason, sizeof(reason));
    pthread_mutex_lock(&reclaim_lock);
    reclaim_status_state.epoch++;
    reclaim_status_state.requested_bytes = 0;
    reclaim_status_state.observed_current_drop_bytes = 0;
    reclaim_status_state.error_number = 0;
    reclaim_status_state.state = RECLAIM_QUEUED;
    snprintf(reclaim_status_state.reason, sizeof(reclaim_status_state.reason), "%s", reason);
    int submit_rc = submit_reclaim_worker_locked(reclaim_status_state.epoch);
    if (submit_rc != 0) {
        reclaim_status_state.state = RECLAIM_ERROR;
        reclaim_status_state.error_number = submit_rc;
    }
    snapshot = reclaim_status_state;
    pthread_mutex_unlock(&reclaim_lock);

    char body[512];
    bool accepted = submit_rc == 0;
    reclaim_submission_json(body, sizeof(body), &snapshot, accepted);
    write_http_response(client, accepted ? "202 Accepted" : "503 Service Unavailable", "application/json", body);
}

static void write_reclaim_cancel_response(int client, const char *request) {
    uint64_t cancel_before = extract_query_u64(request, "epoch");
    struct reclaim_status snapshot;

    pthread_mutex_lock(&reclaim_lock);
    if (cancel_before == 0 || reclaim_status_state.epoch < cancel_before) {
        reclaim_pending_epoch = 0;
        if (reclaim_worker_pid > 0) {
            kill(reclaim_worker_pid, SIGTERM);
        }
        reclaim_status_state.epoch = cancel_before > 0 ? cancel_before : reclaim_status_state.epoch + 1;
        reclaim_status_state.state = RECLAIM_CANCELLED;
        reclaim_status_state.requested_bytes = 0;
        reclaim_status_state.observed_current_drop_bytes = 0;
        reclaim_status_state.error_number = 0;
        snprintf(reclaim_status_state.reason, sizeof(reclaim_status_state.reason), "cancelled");
    }
    snapshot = reclaim_status_state;
    pthread_mutex_unlock(&reclaim_lock);

    char body[512];
    reclaim_status_json(body, sizeof(body), &snapshot);
    write_http_response(client, "200 OK", "application/json", body);
}

static bool read_reclaim_status_file(char *body, size_t body_len, uint64_t *epoch) {
    const char *status_path = getenv("CONJET_RECLAIM_STATUS_PATH");
    if (status_path == NULL || status_path[0] == '\0') {
        status_path = "/run/conjet/memory-reclaim.status";
    }
    FILE *f = fopen(status_path, "r");
    if (f == NULL) {
        return false;
    }
    size_t n = fread(body, 1, body_len - 1, f);
    fclose(f);
    body[n] = '\0';
    unsigned long long parsed_epoch = 0;
    if (sscanf(body, "{\"epoch\":%llu", &parsed_epoch) == 1) {
        *epoch = (uint64_t)parsed_epoch;
    } else {
        *epoch = 0;
    }
    return n > 0;
}

static void build_reclaim_status_body(char *body, size_t body_len, uint64_t requested_epoch) {
    struct reclaim_status snapshot;
    pthread_mutex_lock(&reclaim_lock);
    snapshot = reclaim_status_state;
    pthread_mutex_unlock(&reclaim_lock);

    uint64_t file_epoch = 0;
    bool file_available = read_reclaim_status_file(body, body_len, &file_epoch);
    if (!file_available ||
        file_epoch < snapshot.epoch ||
        (requested_epoch != 0 && file_epoch != requested_epoch)) {
        reclaim_status_json(body, body_len, &snapshot);
    }
}

static void write_reclaim_status_response(int client, const char *request) {
    char body[2048];
    build_reclaim_status_body(body, sizeof(body), extract_query_u64(request, "epoch"));
    write_http_response(client, "200 OK", "application/json", body);
}

static void write_memory_hard_drop_response(int client, const char *request) {
    uint64_t bytes = extract_query_u64(request, "bytes");
    struct memory_hard_drop_result result = offline_guest_memory_blocks(bytes);
    char body[16 * 1024];
    memory_hard_drop_json(body, sizeof(body), &result);
    write_http_response(
        client,
        result.accepted ? "200 OK" : "503 Service Unavailable",
        "application/json",
        body
    );
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

static int open_psi_trigger(void) {
    int fd = open("/proc/pressure/memory", O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        return -1;
    }
    const char *trigger = "some 50000 1000000";
    if (write(fd, trigger, strlen(trigger)) < 0) {
        close_fd(fd);
        return -1;
    }
    return fd;
}

static int open_cgroup_inotify(void) {
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    inotify_add_watch(fd, "/sys/fs/cgroup/memory.events", IN_MODIFY | IN_ATTRIB);
    return fd;
}

static void remove_pollfd(struct pollfd *fds, int *nfds, int index) {
    close_fd(fds[index].fd);
    for (int i = index; i < *nfds - 1; i++) {
        fds[i] = fds[i + 1];
    }
    *nfds -= 1;
}

static void drain_inotify_fd(int fd) {
    char scratch[4096];
    while (read(fd, scratch, sizeof(scratch)) > 0) {}
}

static void drain_psi_fd(int fd) {
    char scratch[1024];
    if (lseek(fd, 0, SEEK_SET) < 0) {
        return;
    }
    while (read(fd, scratch, sizeof(scratch)) > 0) {}
    lseek(fd, 0, SEEK_SET);
}

static void stream_memory_events(int client) {
    const char *header =
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n";
    if (write_full(client, header, strlen(header)) != 0) {
        return;
    }

    char body[4096];
    struct memory_metrics initial = collect_metrics();
    metrics_json(&initial, body, sizeof(body));
    if (write_full(client, body, strlen(body)) != 0) {
        return;
    }

    int psi_fd = open_psi_trigger();
    int inotify_fd = open_cgroup_inotify();
    struct pollfd fds[2];
    int nfds = 0;
    if (psi_fd >= 0) {
        fds[nfds].fd = psi_fd;
        fds[nfds].events = POLLPRI | POLLIN;
        nfds++;
    }
    if (inotify_fd >= 0) {
        fds[nfds].fd = inotify_fd;
        fds[nfds].events = POLLIN;
        nfds++;
    }
    if (nfds == 0) {
        return;
    }

    int64_t last_emit_ms = monotonic_millis();
    while (1) {
        int ready = poll(fds, (nfds_t)nfds, -1);
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready <= 0) {
            break;
        }
        bool should_emit = false;
        for (int i = 0; i < nfds;) {
            short revents = fds[i].revents;
            fds[i].revents = 0;
            if (revents == 0) {
                i++;
                continue;
            }
            if ((revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                int closed_fd = fds[i].fd;
                remove_pollfd(fds, &nfds, i);
                if (closed_fd == psi_fd) {
                    psi_fd = -1;
                } else if (closed_fd == inotify_fd) {
                    inotify_fd = -1;
                }
                continue;
            }
            if ((revents & (POLLIN | POLLPRI)) == 0) {
                i++;
                continue;
            }
            if (fds[i].fd == inotify_fd) {
                drain_inotify_fd(inotify_fd);
            } else if (fds[i].fd == psi_fd) {
                drain_psi_fd(psi_fd);
            }
            should_emit = true;
            i++;
        }
        if (nfds == 0) {
            break;
        }
        if (!should_emit) {
            continue;
        }

        int64_t now_ms = monotonic_millis();
        int64_t elapsed_ms = now_ms - last_emit_ms;
        if (elapsed_ms >= 0 && elapsed_ms < MIN_EVENT_INTERVAL_MS) {
            sleep_millis(MIN_EVENT_INTERVAL_MS - elapsed_ms);
        }

        struct memory_metrics metrics = collect_metrics();
        metrics_json(&metrics, body, sizeof(body));
        if (write_full(client, body, strlen(body)) != 0) {
            close_fd(psi_fd);
            close_fd(inotify_fd);
            return;
        }
        last_emit_ms = monotonic_millis();
    }
    close_fd(psi_fd);
    close_fd(inotify_fd);
}

static void handle_client(int client) {
    char first[2048];
    ssize_t n = read(client, first, sizeof(first));
    if (n <= 0) {
        close_fd(client);
        return;
    }
    const char metrics_path[] = "GET /conjet-memory-metrics ";
    const char events_path[] = "GET /conjet-memory-events ";
    const char capabilities_path[] = "GET /conjet-memory-capabilities ";
    const char reclaim_get_path[] = "GET /conjet-memory-reclaim";
    const char reclaim_post_path[] = "POST /conjet-memory-reclaim";
    const char reclaim_cancel_path[] = "POST /conjet-memory-reclaim/cancel-before";
    const char reclaim_status_path[] = "GET /conjet-memory-reclaim/status";
    const char hard_drop_path[] = "POST /conjet-memory-hard-drop";
    if ((size_t)n >= sizeof(metrics_path) - 1 &&
        memcmp(first, metrics_path, sizeof(metrics_path) - 1) == 0) {
        char body[4096];
        struct memory_metrics metrics = collect_metrics();
        metrics_json(&metrics, body, sizeof(body));
        write_http_response(client, "200 OK", "application/json", body);
    } else if ((size_t)n >= sizeof(hard_drop_path) - 1 &&
               memcmp(first, hard_drop_path, sizeof(hard_drop_path) - 1) == 0) {
        write_memory_hard_drop_response(client, first);
    } else if ((size_t)n >= sizeof(reclaim_status_path) - 1 &&
               memcmp(first, reclaim_status_path, sizeof(reclaim_status_path) - 1) == 0) {
        write_reclaim_status_response(client, first);
    } else if ((size_t)n >= sizeof(reclaim_cancel_path) - 1 &&
               memcmp(first, reclaim_cancel_path, sizeof(reclaim_cancel_path) - 1) == 0) {
        write_reclaim_cancel_response(client, first);
    } else if ((size_t)n >= sizeof(reclaim_post_path) - 1 &&
               memcmp(first, reclaim_post_path, sizeof(reclaim_post_path) - 1) == 0) {
        write_reclaim_submission_response(client, first);
    } else if ((size_t)n >= sizeof(reclaim_get_path) - 1 &&
               memcmp(first, reclaim_get_path, sizeof(reclaim_get_path) - 1) == 0) {
        write_reclaim_submission_response(client, first);
    } else if ((size_t)n >= sizeof(events_path) - 1 &&
               memcmp(first, events_path, sizeof(events_path) - 1) == 0) {
        stream_memory_events(client);
    } else if ((size_t)n >= sizeof(capabilities_path) - 1 &&
               memcmp(first, capabilities_path, sizeof(capabilities_path) - 1) == 0) {
        write_http_response(client, "200 OK", "application/json",
            "{\"version\":3,\"dynamic_memory_events\":true,\"cache_reclaim\":true,\"memory_hard_drop\":true,\"source\":\"conjet-memd\"}\n");
    } else {
        write_http_response(client, "404 Not Found", "text/plain", "not found\n");
    }
    close_fd(client);
}

static void *client_thread(void *arg) {
    int client = (int)(intptr_t)arg;
    handle_client(client);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--metrics") == 0) {
        char body[4096];
        struct memory_metrics metrics = collect_metrics();
        metrics_json(&metrics, body, sizeof(body));
        fputs(body, stdout);
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--reclaim") == 0) {
        struct reclaim_status snapshot;
        pthread_mutex_lock(&reclaim_lock);
        reclaim_status_state.epoch++;
        reclaim_status_state.state = RECLAIM_QUEUED;
        reclaim_status_state.error_number = submit_reclaim_worker_locked(reclaim_status_state.epoch);
        if (reclaim_status_state.error_number != 0) {
            reclaim_status_state.state = RECLAIM_ERROR;
        }
        snapshot = reclaim_status_state;
        pthread_mutex_unlock(&reclaim_lock);
        char body[512];
        reclaim_submission_json(body, sizeof(body), &snapshot, snapshot.state == RECLAIM_QUEUED);
        fputs(body, stdout);
        return snapshot.state == RECLAIM_QUEUED ? 0 : 1;
    }
    if (argc > 1 && strcmp(argv[1], "--status") == 0) {
        char body[2048];
        build_reclaim_status_body(body, sizeof(body), 0);
        fputs(body, stdout);
        return 0;
    }
    if (argc > 2 && strcmp(argv[1], "--status-epoch") == 0) {
        char body[2048];
        build_reclaim_status_body(body, sizeof(body), strtoull(argv[2], NULL, 10));
        fputs(body, stdout);
        return 0;
    }
    signal(SIGPIPE, SIG_IGN);
    int server = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (server < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = CONJET_MEMD_PORT;
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close_fd(server);
        return 1;
    }
    if (listen(server, 64) != 0) {
        perror("listen");
        close_fd(server);
        return 1;
    }
    mkdir("/run/conjet", 0755);
    FILE *ready = fopen("/run/conjet/memory-vsock-ready", "w");
    if (ready != NULL) {
        fprintf(ready, "%d\n", CONJET_MEMD_PORT);
        fclose(ready);
    }
    while (1) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, client_thread, (void *)(intptr_t)client) == 0) {
            pthread_detach(thread);
        } else {
            handle_client(client);
        }
    }
    close_fd(server);
    return 0;
}
