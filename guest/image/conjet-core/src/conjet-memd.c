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
#ifndef VMADDR_CID_HOST
#define VMADDR_CID_HOST 2U
#endif

#define CONJET_MEMD_PORT 2376
#define MAX_CGROUP_DEPTH 8
#define MIN_EVENT_INTERVAL_MS 1000
#define METRICS_JSON_CAPACITY (16U * 1024U)
#define SERVICE_SLICES_JSON_CAPACITY (256U * 1024U)
#define SERVICE_SLICE_JSON_ITEM_CAPACITY (32U * 1024U)
#define DEFAULT_BUILD_CGROUP_PATH \
    "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice/conjet-build.slice"

#define SERVICE_SLICE_MARKER "conjet-service-"
#define SERVICE_ROOT_RESIDUAL_KEY "conjet_services_residual"
#define SERVICE_SLICE_RESIDUAL_MIN_BYTES (64ULL * 1024ULL * 1024ULL)

struct memory_metrics {
    uint64_t page_size_bytes;
    uint64_t mem_total;
    uint64_t mem_available;
    bool mem_available_known;
    uint64_t mem_free;
    uint64_t page_cache_bytes;
    uint64_t sreclaimable_bytes;
    uint64_t swap_total;
    uint64_t swap_free;
    bool swap_telemetry_complete;
    uint64_t disk_swap_total;
    uint64_t disk_swap_free;
    bool disk_swap_telemetry_complete;
    uint64_t zram_orig_data_size;
    uint64_t zram_compr_data_size;
    uint64_t zram_mem_used_total;
    bool mglru_enabled;
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
    uint64_t daemon_cgroup_working_set;
    uint64_t daemon_cgroup_anon;
    uint64_t daemon_cgroup_inactive_file;
    uint64_t daemon_cgroup_slab_reclaimable;
    bool daemon_cgroup_populated;
    bool daemon_cgroup_population_known;
    uint64_t service_cgroup_memory_current;
    uint64_t service_cgroup_working_set;
    uint64_t service_cgroup_anon;
    uint64_t service_cgroup_file;
    uint64_t service_cgroup_shmem;
    uint64_t service_cgroup_sock;
    uint64_t service_cgroup_kernel;
    uint64_t service_cgroup_file_mapped;
    uint64_t service_cgroup_inactive_anon;
    uint64_t service_cgroup_active_anon;
    uint64_t service_cgroup_inactive_file;
    uint64_t service_cgroup_active_file;
    uint64_t service_cgroup_file_dirty;
    uint64_t service_cgroup_file_writeback;
    uint64_t service_cgroup_clean_inactive_file;
    uint64_t service_cgroup_slab;
    uint64_t service_cgroup_slab_reclaimable;
    uint64_t service_cgroup_slab_unreclaimable;
    uint64_t service_cgroup_workingset_refault_file;
    uint64_t service_cgroup_workingset_activate_file;
    uint64_t service_cgroup_workingset_restore_file;
    uint64_t service_cgroup_pgfault;
    uint64_t service_cgroup_pgmajfault;
    uint64_t service_cgroup_pgscan;
    uint64_t service_cgroup_pgsteal;
    uint64_t service_cgroup_pgscan_proactive;
    uint64_t service_cgroup_pgsteal_proactive;
    uint64_t service_cgroup_memory_events_low;
    uint64_t service_cgroup_memory_events_high;
    uint64_t service_cgroup_memory_events_max;
    uint64_t service_cgroup_memory_events_oom;
    uint64_t service_cgroup_memory_events_oom_kill;
    uint64_t service_cgroup_memory_events_oom_group_kill;
    uint64_t service_cgroup_memory_events_local_low;
    uint64_t service_cgroup_memory_events_local_high;
    uint64_t service_cgroup_memory_events_local_max;
    uint64_t service_cgroup_memory_events_local_oom;
    uint64_t service_cgroup_memory_events_local_oom_kill;
    uint64_t service_cgroup_memory_events_local_oom_group_kill;
    double service_cgroup_psi_some_avg10;
    uint64_t service_cgroup_psi_some_total_us;
    double service_cgroup_psi_full_avg10;
    uint64_t service_cgroup_psi_full_total_us;
    uint64_t service_cgroup_cgroup_id;
    bool service_cgroup_telemetry_complete;
    bool service_cgroup_populated;
    bool service_cgroup_population_known;
    double psi_some_avg10;
    double psi_full_avg10;
    bool global_psi_telemetry_complete;
    int active_workloads;
    bool build_workload_detected;
};

#define MAX_SERVICE_SLICES 128

struct service_slice_stat {
    char key[96];
    char path[4096];
    uint64_t cgroup_id;
    uint64_t memory_current;
    uint64_t anon;
    uint64_t file;
    uint64_t shmem;
    uint64_t sock;
    uint64_t kernel;
    uint64_t file_mapped;
    uint64_t inactive_anon;
    uint64_t active_anon;
    uint64_t inactive_file;
    uint64_t active_file;
    uint64_t file_dirty;
    uint64_t file_writeback;
    uint64_t slab_reclaimable;
    uint64_t slab_unreclaimable;
    uint64_t workingset_refault_file;
    uint64_t workingset_activate_file;
    uint64_t workingset_restore_file;
    uint64_t pgfault;
    uint64_t pgmajfault;
    uint64_t pgscan;
    uint64_t pgsteal;
    uint64_t pgscan_proactive;
    uint64_t pgsteal_proactive;
    uint64_t memory_events_local_low;
    uint64_t memory_events_local_high;
    uint64_t memory_events_local_max;
    uint64_t memory_events_local_oom;
    uint64_t memory_events_local_oom_kill;
    uint64_t memory_events_local_oom_group_kill;
    double psi_some_avg10;
    uint64_t psi_some_total_us;
    double psi_full_avg10;
    uint64_t psi_full_total_us;
    bool populated;
    bool population_known;
    bool telemetry_complete;
    size_t member_count;
};

struct service_slice_set {
    struct service_slice_stat slices[MAX_SERVICE_SLICES];
    size_t count;
    bool truncated;
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

struct reclaim_request {
    uint64_t epoch;
    uint64_t bytes;
    bool service_scoped;
    char reason[64];
    char service_key[96];
    char cgroup_path[4096];
};

static pthread_mutex_t reclaim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t reclaim_cond = PTHREAD_COND_INITIALIZER;
static pid_t reclaim_worker_pid = -1;
static struct reclaim_request reclaim_pending_request;
static bool reclaim_pending_request_available = false;
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

static bool is_host_vsock_peer(const struct sockaddr_vm *peer, socklen_t peer_len) {
    return peer_len >= sizeof(*peer) &&
           peer->svm_family == AF_VSOCK &&
           peer->svm_cid == VMADDR_CID_HOST;
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

static bool read_uint_file_known(const char *path, uint64_t *value_out) {
    if (value_out != NULL) {
        *value_out = 0;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    unsigned long long value = 0;
    bool known = fscanf(f, "%llu", &value) == 1;
    fclose(f);
    if (known && value_out != NULL) {
        *value_out = (uint64_t)value;
    }
    return known;
}

static uint64_t read_uint_file(const char *path) {
    uint64_t value = 0;
    (void)read_uint_file_known(path, &value);
    return value;
}

static bool read_mglru_enabled_path(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    char value[64];
    bool enabled = false;
    if (fgets(value, sizeof(value), f) != NULL) {
        char *start = value;
        while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n') {
            start++;
        }
        char *end = NULL;
        errno = 0;
        unsigned long long parsed = strtoull(start, &end, 0);
        if (*start != '+' && *start != '-' && end != start && errno != ERANGE) {
            while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') {
                end++;
            }
            enabled = *end == '\0' && (parsed & 0x1U) != 0;
        }
        int trailing = 0;
        while (enabled && (trailing = fgetc(f)) != EOF) {
            if (trailing != ' ' && trailing != '\t' && trailing != '\r' && trailing != '\n') {
                enabled = false;
            }
        }
        if (ferror(f)) {
            enabled = false;
        }
    }
    fclose(f);
    return enabled;
}

static bool read_mglru_enabled(void) {
    return read_mglru_enabled_path("/sys/kernel/mm/lru_gen/enabled");
}

static uint64_t read_page_size_bytes(void) {
    long page_size = sysconf(_SC_PAGESIZE);
    return page_size > 0 ? (uint64_t)page_size : 0;
}

struct cgroup_memory_stat {
    uint64_t anon;
    uint64_t file;
    uint64_t shmem;
    uint64_t sock;
    uint64_t kernel;
    uint64_t file_mapped;
    uint64_t inactive_anon;
    uint64_t active_anon;
    uint64_t inactive_file;
    uint64_t active_file;
    uint64_t file_dirty;
    uint64_t file_writeback;
    uint64_t slab;
    uint64_t slab_reclaimable;
    uint64_t slab_unreclaimable;
    uint64_t workingset_refault_file;
    uint64_t workingset_activate_file;
    uint64_t workingset_restore_file;
    uint64_t pgfault;
    uint64_t pgmajfault;
    uint64_t pgscan;
    uint64_t pgsteal;
    uint64_t pgscan_proactive;
    uint64_t pgsteal_proactive;
};

enum cgroup_memory_stat_field {
    CGROUP_STAT_ANON = 1ULL << 0,
    CGROUP_STAT_FILE = 1ULL << 1,
    CGROUP_STAT_SHMEM = 1ULL << 2,
    CGROUP_STAT_SOCK = 1ULL << 3,
    CGROUP_STAT_KERNEL = 1ULL << 4,
    CGROUP_STAT_FILE_MAPPED = 1ULL << 5,
    CGROUP_STAT_INACTIVE_ANON = 1ULL << 6,
    CGROUP_STAT_ACTIVE_ANON = 1ULL << 7,
    CGROUP_STAT_INACTIVE_FILE = 1ULL << 8,
    CGROUP_STAT_ACTIVE_FILE = 1ULL << 9,
    CGROUP_STAT_FILE_DIRTY = 1ULL << 10,
    CGROUP_STAT_FILE_WRITEBACK = 1ULL << 11,
    CGROUP_STAT_SLAB_RECLAIMABLE = 1ULL << 12,
    CGROUP_STAT_SLAB_UNRECLAIMABLE = 1ULL << 13,
    CGROUP_STAT_WORKINGSET_REFAULT_FILE = 1ULL << 14,
    CGROUP_STAT_WORKINGSET_ACTIVATE_FILE = 1ULL << 15,
    CGROUP_STAT_WORKINGSET_RESTORE_FILE = 1ULL << 16,
    CGROUP_STAT_PGFAULT = 1ULL << 17,
    CGROUP_STAT_PGMAJFAULT = 1ULL << 18,
    CGROUP_STAT_PGSCAN = 1ULL << 19,
    CGROUP_STAT_PGSTEAL = 1ULL << 20,
    CGROUP_STAT_PGSCAN_PROACTIVE = 1ULL << 21,
    CGROUP_STAT_PGSTEAL_PROACTIVE = 1ULL << 22,
};

// Linux 6.12 exports pgscan/pgsteal but not the proactive split. Preserve the
// optional counters when a newer kernel provides them without making their
// absence invalidate the service snapshot.
#define CGROUP_MEMORY_STAT_REQUIRED_MASK ( \
    CGROUP_STAT_ANON | CGROUP_STAT_FILE | CGROUP_STAT_SHMEM | \
    CGROUP_STAT_SOCK | CGROUP_STAT_KERNEL | CGROUP_STAT_FILE_MAPPED | \
    CGROUP_STAT_INACTIVE_ANON | CGROUP_STAT_ACTIVE_ANON | \
    CGROUP_STAT_INACTIVE_FILE | CGROUP_STAT_ACTIVE_FILE | \
    CGROUP_STAT_FILE_DIRTY | CGROUP_STAT_FILE_WRITEBACK | \
    CGROUP_STAT_SLAB_RECLAIMABLE | CGROUP_STAT_SLAB_UNRECLAIMABLE | \
    CGROUP_STAT_WORKINGSET_REFAULT_FILE | \
    CGROUP_STAT_WORKINGSET_ACTIVATE_FILE | \
    CGROUP_STAT_WORKINGSET_RESTORE_FILE | CGROUP_STAT_PGFAULT | \
    CGROUP_STAT_PGMAJFAULT | CGROUP_STAT_PGSCAN | CGROUP_STAT_PGSTEAL)

static bool read_cgroup_memory_stat_file(
    const char *cgroup,
    struct cgroup_memory_stat *stat_out
) {
    memset(stat_out, 0, sizeof(*stat_out));
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/memory.stat", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return false;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    uint64_t present = 0;
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        uint64_t parsed = (uint64_t)value;
        if (strcmp(key, "anon") == 0) {
            stat_out->anon = parsed;
            present |= CGROUP_STAT_ANON;
        } else if (strcmp(key, "file") == 0) {
            stat_out->file = parsed;
            present |= CGROUP_STAT_FILE;
        } else if (strcmp(key, "shmem") == 0) {
            stat_out->shmem = parsed;
            present |= CGROUP_STAT_SHMEM;
        } else if (strcmp(key, "sock") == 0) {
            stat_out->sock = parsed;
            present |= CGROUP_STAT_SOCK;
        } else if (strcmp(key, "kernel") == 0) {
            stat_out->kernel = parsed;
            present |= CGROUP_STAT_KERNEL;
        } else if (strcmp(key, "file_mapped") == 0) {
            stat_out->file_mapped = parsed;
            present |= CGROUP_STAT_FILE_MAPPED;
        } else if (strcmp(key, "inactive_anon") == 0) {
            stat_out->inactive_anon = parsed;
            present |= CGROUP_STAT_INACTIVE_ANON;
        } else if (strcmp(key, "active_anon") == 0) {
            stat_out->active_anon = parsed;
            present |= CGROUP_STAT_ACTIVE_ANON;
        } else if (strcmp(key, "inactive_file") == 0) {
            stat_out->inactive_file = parsed;
            present |= CGROUP_STAT_INACTIVE_FILE;
        } else if (strcmp(key, "active_file") == 0) {
            stat_out->active_file = parsed;
            present |= CGROUP_STAT_ACTIVE_FILE;
        } else if (strcmp(key, "file_dirty") == 0) {
            stat_out->file_dirty = parsed;
            present |= CGROUP_STAT_FILE_DIRTY;
        } else if (strcmp(key, "file_writeback") == 0) {
            stat_out->file_writeback = parsed;
            present |= CGROUP_STAT_FILE_WRITEBACK;
        } else if (strcmp(key, "slab") == 0) {
            stat_out->slab = parsed;
        } else if (strcmp(key, "slab_reclaimable") == 0) {
            stat_out->slab_reclaimable = parsed;
            present |= CGROUP_STAT_SLAB_RECLAIMABLE;
        } else if (strcmp(key, "slab_unreclaimable") == 0) {
            stat_out->slab_unreclaimable = parsed;
            present |= CGROUP_STAT_SLAB_UNRECLAIMABLE;
        } else if (strcmp(key, "workingset_refault_file") == 0) {
            stat_out->workingset_refault_file = parsed;
            present |= CGROUP_STAT_WORKINGSET_REFAULT_FILE;
        } else if (strcmp(key, "workingset_activate_file") == 0) {
            stat_out->workingset_activate_file = parsed;
            present |= CGROUP_STAT_WORKINGSET_ACTIVATE_FILE;
        } else if (strcmp(key, "workingset_restore_file") == 0) {
            stat_out->workingset_restore_file = parsed;
            present |= CGROUP_STAT_WORKINGSET_RESTORE_FILE;
        } else if (strcmp(key, "pgfault") == 0) {
            stat_out->pgfault = parsed;
            present |= CGROUP_STAT_PGFAULT;
        } else if (strcmp(key, "pgmajfault") == 0) {
            stat_out->pgmajfault = parsed;
            present |= CGROUP_STAT_PGMAJFAULT;
        } else if (strcmp(key, "pgscan") == 0) {
            stat_out->pgscan = parsed;
            present |= CGROUP_STAT_PGSCAN;
        } else if (strcmp(key, "pgsteal") == 0) {
            stat_out->pgsteal = parsed;
            present |= CGROUP_STAT_PGSTEAL;
        } else if (strcmp(key, "pgscan_proactive") == 0) {
            stat_out->pgscan_proactive = parsed;
            present |= CGROUP_STAT_PGSCAN_PROACTIVE;
        } else if (strcmp(key, "pgsteal_proactive") == 0) {
            stat_out->pgsteal_proactive = parsed;
            present |= CGROUP_STAT_PGSTEAL_PROACTIVE;
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    return read_ok && (present & CGROUP_MEMORY_STAT_REQUIRED_MASK) ==
        CGROUP_MEMORY_STAT_REQUIRED_MASK;
}

struct cgroup_memory_events_local {
    uint64_t low;
    uint64_t high;
    uint64_t max;
    uint64_t oom;
    uint64_t oom_kill;
    uint64_t oom_group_kill;
};

static bool read_cgroup_memory_events_file(
    const char *cgroup,
    const char *file_name,
    struct cgroup_memory_events_local *events_out
) {
    memset(events_out, 0, sizeof(*events_out));
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/%s", cgroup, file_name);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return false;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    enum {
        EVENT_LOW = 1U << 0,
        EVENT_HIGH = 1U << 1,
        EVENT_MAX = 1U << 2,
        EVENT_OOM = 1U << 3,
        EVENT_OOM_KILL = 1U << 4,
        EVENT_OOM_GROUP_KILL = 1U << 5,
    };
    unsigned int present = 0;
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        if (strcmp(key, "low") == 0) {
            events_out->low = (uint64_t)value;
            present |= EVENT_LOW;
        } else if (strcmp(key, "high") == 0) {
            events_out->high = (uint64_t)value;
            present |= EVENT_HIGH;
        } else if (strcmp(key, "max") == 0) {
            events_out->max = (uint64_t)value;
            present |= EVENT_MAX;
        } else if (strcmp(key, "oom") == 0) {
            events_out->oom = (uint64_t)value;
            present |= EVENT_OOM;
        } else if (strcmp(key, "oom_kill") == 0) {
            events_out->oom_kill = (uint64_t)value;
            present |= EVENT_OOM_KILL;
        } else if (strcmp(key, "oom_group_kill") == 0) {
            events_out->oom_group_kill = (uint64_t)value;
            present |= EVENT_OOM_GROUP_KILL;
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    return read_ok && present == ((1U << 6) - 1U);
}

static bool read_cgroup_memory_events_local(
    const char *cgroup,
    struct cgroup_memory_events_local *events_out
) {
    return read_cgroup_memory_events_file(cgroup, "memory.events.local", events_out);
}

static bool read_cgroup_memory_events(
    const char *cgroup,
    struct cgroup_memory_events_local *events_out
) {
    return read_cgroup_memory_events_file(cgroup, "memory.events", events_out);
}

struct cgroup_memory_psi {
    double some_avg10;
    uint64_t some_total_us;
    double full_avg10;
    uint64_t full_total_us;
};

static bool is_ascii_whitespace(char value) {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

static bool only_ascii_whitespace(const char *value) {
    while (*value != '\0') {
        if (!is_ascii_whitespace(*value)) {
            return false;
        }
        value++;
    }
    return true;
}

static const char *find_pressure_field(const char *line, const char *field) {
    const char *cursor = line;
    while ((cursor = strstr(cursor, field)) != NULL) {
        if (cursor == line || is_ascii_whitespace(cursor[-1])) {
            return cursor + strlen(field);
        }
        cursor++;
    }
    return NULL;
}

static bool parse_pressure_line(const char *line, double *avg10_out, uint64_t *total_us_out) {
    const char *avg10 = find_pressure_field(line, "avg10=");
    const char *total = find_pressure_field(line, "total=");
    if (avg10 == NULL || total == NULL || *avg10 < '0' || *avg10 > '9' ||
        *total < '0' || *total > '9') {
        return false;
    }
    errno = 0;
    char *avg10_end = NULL;
    double parsed_avg10 = strtod(avg10, &avg10_end);
    if (avg10_end == avg10 || errno == ERANGE || parsed_avg10 < 0.0 ||
        parsed_avg10 > 100.0 ||
        (*avg10_end != '\0' && !is_ascii_whitespace(*avg10_end))) {
        return false;
    }
    errno = 0;
    char *total_end = NULL;
    unsigned long long parsed_total = strtoull(total, &total_end, 10);
    if (total_end == total || errno == ERANGE || !only_ascii_whitespace(total_end)) {
        return false;
    }
    *avg10_out = parsed_avg10;
    *total_us_out = (uint64_t)parsed_total;
    return true;
}

static bool read_cgroup_memory_psi(const char *cgroup, struct cgroup_memory_psi *psi_out) {
    memset(psi_out, 0, sizeof(*psi_out));
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/memory.pressure", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return false;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return false;
    }
    bool some_known = false;
    bool full_known = false;
    char line[512];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "some ", 5) == 0) {
            some_known = parse_pressure_line(
                line,
                &psi_out->some_avg10,
                &psi_out->some_total_us
            );
        } else if (strncmp(line, "full ", 5) == 0) {
            full_known = parse_pressure_line(
                line,
                &psi_out->full_avg10,
                &psi_out->full_total_us
            );
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    return read_ok && some_known && full_known;
}

static bool read_cgroup_id(const char *cgroup, uint64_t *cgroup_id_out) {
    if (cgroup_id_out != NULL) {
        *cgroup_id_out = 0;
    }
    struct stat st;
    if (stat(cgroup, &st) != 0) {
        return false;
    }
    if (cgroup_id_out != NULL) {
        *cgroup_id_out = (uint64_t)st.st_ino;
    }
    return true;
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

static bool read_cgroup_current_known(const char *cgroup, uint64_t *current_out) {
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/memory.current", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        if (current_out != NULL) {
            *current_out = 0;
        }
        return false;
    }
    return read_uint_file_known(path, current_out);
}

static uint64_t read_cgroup_current(const char *cgroup) {
    uint64_t current = 0;
    (void)read_cgroup_current_known(cgroup, &current);
    return current;
}

static bool read_cgroup_populated_known(const char *cgroup, bool *known);

static bool add_service_cgroup_memory_stat(const char *cgroup, struct memory_metrics *metrics) {
    struct cgroup_memory_stat stat;
    bool complete = read_cgroup_memory_stat_file(cgroup, &stat);
    metrics->service_cgroup_anon = stat.anon;
    metrics->service_cgroup_file = stat.file;
    metrics->service_cgroup_shmem = stat.shmem;
    metrics->service_cgroup_sock = stat.sock;
    metrics->service_cgroup_kernel = stat.kernel;
    metrics->service_cgroup_file_mapped = stat.file_mapped;
    metrics->service_cgroup_inactive_anon = stat.inactive_anon;
    metrics->service_cgroup_active_anon = stat.active_anon;
    metrics->service_cgroup_inactive_file = stat.inactive_file;
    metrics->service_cgroup_active_file = stat.active_file;
    metrics->service_cgroup_file_dirty = stat.file_dirty;
    metrics->service_cgroup_file_writeback = stat.file_writeback;
    metrics->service_cgroup_slab = stat.slab;
    metrics->service_cgroup_slab_reclaimable = stat.slab_reclaimable;
    metrics->service_cgroup_slab_unreclaimable = stat.slab_unreclaimable;
    metrics->service_cgroup_workingset_refault_file = stat.workingset_refault_file;
    metrics->service_cgroup_workingset_activate_file = stat.workingset_activate_file;
    metrics->service_cgroup_workingset_restore_file = stat.workingset_restore_file;
    metrics->service_cgroup_pgfault = stat.pgfault;
    metrics->service_cgroup_pgmajfault = stat.pgmajfault;
    metrics->service_cgroup_pgscan = stat.pgscan;
    metrics->service_cgroup_pgsteal = stat.pgsteal;
    metrics->service_cgroup_pgscan_proactive = stat.pgscan_proactive;
    metrics->service_cgroup_pgsteal_proactive = stat.pgsteal_proactive;
    if (metrics->service_cgroup_slab == 0) {
        metrics->service_cgroup_slab =
            metrics->service_cgroup_slab_reclaimable +
            metrics->service_cgroup_slab_unreclaimable;
    }
    return complete;
}

static void add_daemon_cgroup_memory_stat(const char *cgroup, struct memory_metrics *metrics) {
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/memory.stat", cgroup);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        return;
    }
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        uint64_t bytes = (uint64_t)value;
        if (strcmp(key, "anon") == 0) {
            metrics->daemon_cgroup_anon += bytes;
        } else if (strcmp(key, "inactive_file") == 0) {
            metrics->daemon_cgroup_inactive_file += bytes;
        } else if (strcmp(key, "slab_reclaimable") == 0) {
            metrics->daemon_cgroup_slab_reclaimable += bytes;
        }
    }
    fclose(f);
}

static bool read_cgroup_populated_known(const char *cgroup, bool *known) {
    if (known != NULL) {
        *known = false;
    }
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
            if (known != NULL) {
                *known = true;
            }
            break;
        }
    }
    fclose(f);
    return populated;
}

static bool read_cgroup_populated(const char *cgroup) {
    return read_cgroup_populated_known(cgroup, NULL);
}

static uint64_t saturating_add_u64(uint64_t lhs, uint64_t rhs);
static uint64_t saturating_sub_u64(uint64_t lhs, uint64_t rhs);

static bool extract_service_slice_key(const char *path, char *key, size_t key_len) {
    const char *start = strstr(path, SERVICE_SLICE_MARKER);
    if (start == NULL || key_len == 0) {
        return false;
    }
    start += sizeof(SERVICE_SLICE_MARKER) - 1;
    const char *end = strstr(start, ".slice");
    if (end == NULL || end <= start) {
        return false;
    }
    size_t raw_len = (size_t)(end - start);
    size_t out = 0;
    for (size_t i = 0; i < raw_len; i++) {
        if (out + 1 >= key_len) {
            key[0] = '\0';
            return false;
        }
        char ch = start[i];
        if ((ch >= 'a' && ch <= 'z') ||
            (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') ||
            ch == '_') {
            key[out++] = ch;
        } else {
            key[out++] = '_';
        }
    }
    while (out > 0 && key[out - 1] == '_') {
        out--;
    }
    key[out] = '\0';
    return out > 0;
}

static bool add_service_slice_stat_file(const char *cgroup, struct service_slice_stat *slice) {
    struct cgroup_memory_stat stat;
    bool complete = read_cgroup_memory_stat_file(cgroup, &stat);
    slice->anon = saturating_add_u64(slice->anon, stat.anon);
    slice->file = saturating_add_u64(slice->file, stat.file);
    slice->shmem = saturating_add_u64(slice->shmem, stat.shmem);
    slice->sock = saturating_add_u64(slice->sock, stat.sock);
    slice->kernel = saturating_add_u64(slice->kernel, stat.kernel);
    slice->file_mapped = saturating_add_u64(slice->file_mapped, stat.file_mapped);
    slice->inactive_anon = saturating_add_u64(slice->inactive_anon, stat.inactive_anon);
    slice->active_anon = saturating_add_u64(slice->active_anon, stat.active_anon);
    slice->inactive_file = saturating_add_u64(slice->inactive_file, stat.inactive_file);
    slice->active_file = saturating_add_u64(slice->active_file, stat.active_file);
    slice->file_dirty = saturating_add_u64(slice->file_dirty, stat.file_dirty);
    slice->file_writeback = saturating_add_u64(slice->file_writeback, stat.file_writeback);
    slice->slab_reclaimable = saturating_add_u64(
        slice->slab_reclaimable,
        stat.slab_reclaimable
    );
    slice->slab_unreclaimable = saturating_add_u64(
        slice->slab_unreclaimable,
        stat.slab_unreclaimable
    );
    slice->workingset_refault_file = saturating_add_u64(
        slice->workingset_refault_file,
        stat.workingset_refault_file
    );
    slice->workingset_activate_file = saturating_add_u64(
        slice->workingset_activate_file,
        stat.workingset_activate_file
    );
    slice->workingset_restore_file = saturating_add_u64(
        slice->workingset_restore_file,
        stat.workingset_restore_file
    );
    slice->pgfault = saturating_add_u64(slice->pgfault, stat.pgfault);
    slice->pgmajfault = saturating_add_u64(slice->pgmajfault, stat.pgmajfault);
    slice->pgscan = saturating_add_u64(slice->pgscan, stat.pgscan);
    slice->pgsteal = saturating_add_u64(slice->pgsteal, stat.pgsteal);
    slice->pgscan_proactive = saturating_add_u64(
        slice->pgscan_proactive,
        stat.pgscan_proactive
    );
    slice->pgsteal_proactive = saturating_add_u64(
        slice->pgsteal_proactive,
        stat.pgsteal_proactive
    );
    return complete;
}

static bool add_service_slice_events_local(const char *cgroup, struct service_slice_stat *slice) {
    struct cgroup_memory_events_local events;
    bool complete = read_cgroup_memory_events_local(cgroup, &events);
    slice->memory_events_local_low = saturating_add_u64(
        slice->memory_events_local_low,
        events.low
    );
    slice->memory_events_local_high = saturating_add_u64(
        slice->memory_events_local_high,
        events.high
    );
    slice->memory_events_local_max = saturating_add_u64(
        slice->memory_events_local_max,
        events.max
    );
    slice->memory_events_local_oom = saturating_add_u64(
        slice->memory_events_local_oom,
        events.oom
    );
    slice->memory_events_local_oom_kill = saturating_add_u64(
        slice->memory_events_local_oom_kill,
        events.oom_kill
    );
    slice->memory_events_local_oom_group_kill = saturating_add_u64(
        slice->memory_events_local_oom_group_kill,
        events.oom_group_kill
    );
    return complete;
}

static bool add_service_slice_psi(const char *cgroup, struct service_slice_stat *slice) {
    struct cgroup_memory_psi psi;
    bool complete = read_cgroup_memory_psi(cgroup, &psi);
    if (psi.some_avg10 > slice->psi_some_avg10) {
        slice->psi_some_avg10 = psi.some_avg10;
    }
    if (psi.full_avg10 > slice->psi_full_avg10) {
        slice->psi_full_avg10 = psi.full_avg10;
    }
    slice->psi_some_total_us = saturating_add_u64(
        slice->psi_some_total_us,
        psi.some_total_us
    );
    slice->psi_full_total_us = saturating_add_u64(
        slice->psi_full_total_us,
        psi.full_total_us
    );
    return complete;
}

static uint64_t service_slice_clean_inactive_file(const struct service_slice_stat *slice) {
    uint64_t dirty_and_writeback = saturating_add_u64(
        slice->file_dirty,
        slice->file_writeback
    );
    return saturating_sub_u64(slice->inactive_file, dirty_and_writeback);
}

static uint64_t service_slice_reclaimable(const struct service_slice_stat *slice) {
    uint64_t reclaimable = saturating_add_u64(slice->inactive_file, slice->slab_reclaimable);
    return reclaimable > slice->memory_current ? slice->memory_current : reclaimable;
}

static uint64_t service_slice_working_set(const struct service_slice_stat *slice) {
    uint64_t reclaimable = service_slice_reclaimable(slice);
    return slice->memory_current > reclaimable ? slice->memory_current - reclaimable : 0;
}

static struct service_slice_stat *find_or_add_service_slice(
    struct service_slice_set *set,
    const char *key,
    const char *path
) {
    for (size_t i = 0; i < set->count; i++) {
        if (strcmp(set->slices[i].key, key) == 0) {
            return &set->slices[i];
        }
    }
    if (set->count >= MAX_SERVICE_SLICES) {
        set->truncated = true;
        return NULL;
    }
    struct service_slice_stat *slice = &set->slices[set->count++];
    memset(slice, 0, sizeof(*slice));
    snprintf(slice->key, sizeof(slice->key), "%s", key);
    snprintf(slice->path, sizeof(slice->path), "%s", path);
    return slice;
}

static bool add_service_slice_cgroup(const char *cgroup, struct service_slice_set *set) {
    char key[96];
    if (!extract_service_slice_key(cgroup, key, sizeof(key))) {
        if (strstr(cgroup, SERVICE_SLICE_MARKER) != NULL) {
            set->truncated = true;
        }
        return false;
    }
    uint64_t current = 0;
    bool current_known = read_cgroup_current_known(cgroup, &current);
    if (!current_known) {
        set->truncated = true;
        return false;
    }
    if (current == 0) {
        return false;
    }
    struct service_slice_stat *slice = find_or_add_service_slice(set, key, cgroup);
    if (slice == NULL) {
        return true;
    }
    bool first_member = slice->member_count == 0;
    bool population_known = false;
    bool populated = read_cgroup_populated_known(cgroup, &population_known);
    uint64_t cgroup_id = 0;
    bool cgroup_id_known = read_cgroup_id(cgroup, &cgroup_id);
    bool stat_complete = add_service_slice_stat_file(cgroup, slice);
    bool events_complete = add_service_slice_events_local(cgroup, slice);
    bool psi_complete = add_service_slice_psi(cgroup, slice);
    bool member_complete = current_known && population_known && cgroup_id_known &&
        stat_complete && events_complete && psi_complete;

    slice->memory_current = saturating_add_u64(slice->memory_current, current);
    slice->populated = slice->populated || populated;
    slice->population_known = first_member ? population_known :
        slice->population_known && population_known;
    slice->telemetry_complete = first_member ? member_complete :
        slice->telemetry_complete && member_complete;
    slice->member_count++;
    if (first_member || slice->path[0] == '\0' || strstr(cgroup, ":docker:") == NULL) {
        snprintf(slice->path, sizeof(slice->path), "%s", cgroup);
        slice->cgroup_id = cgroup_id_known ? cgroup_id : 0;
    }
    return true;
}

static void scan_service_slice_cgroups(const char *dir, int depth, struct service_slice_set *set) {
    if (depth > MAX_CGROUP_DEPTH || set->count >= MAX_SERVICE_SLICES) {
        set->truncated = true;
        return;
    }
    if (add_service_slice_cgroup(dir, set)) {
        return;
    }
    DIR *d = opendir(dir);
    if (d == NULL) {
        set->truncated = true;
        return;
    }
    while (1) {
        errno = 0;
        struct dirent *entry = readdir(d);
        if (entry == NULL) {
            if (errno != 0) {
                set->truncated = true;
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char child[4096];
        int written = snprintf(child, sizeof(child), "%s/%s", dir, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(child)) {
            set->truncated = true;
            continue;
        }
        struct stat st;
        if (stat(child, &st) != 0) {
            set->truncated = true;
        } else if (S_ISDIR(st.st_mode)) {
            scan_service_slice_cgroups(child, depth + 1, set);
        }
    }
    closedir(d);
}

static void accumulate_service_slice_totals(
    const struct service_slice_set *set,
    struct service_slice_stat *totals
) {
    memset(totals, 0, sizeof(*totals));
    for (size_t i = 0; i < set->count; i++) {
        totals->memory_current = saturating_add_u64(totals->memory_current, set->slices[i].memory_current);
        totals->anon = saturating_add_u64(totals->anon, set->slices[i].anon);
        totals->file = saturating_add_u64(totals->file, set->slices[i].file);
        totals->shmem = saturating_add_u64(totals->shmem, set->slices[i].shmem);
        totals->sock = saturating_add_u64(totals->sock, set->slices[i].sock);
        totals->kernel = saturating_add_u64(totals->kernel, set->slices[i].kernel);
        totals->file_mapped = saturating_add_u64(
            totals->file_mapped,
            set->slices[i].file_mapped
        );
        totals->inactive_anon = saturating_add_u64(
            totals->inactive_anon,
            set->slices[i].inactive_anon
        );
        totals->active_anon = saturating_add_u64(
            totals->active_anon,
            set->slices[i].active_anon
        );
        totals->inactive_file = saturating_add_u64(totals->inactive_file, set->slices[i].inactive_file);
        totals->active_file = saturating_add_u64(totals->active_file, set->slices[i].active_file);
        totals->file_dirty = saturating_add_u64(
            totals->file_dirty,
            set->slices[i].file_dirty
        );
        totals->file_writeback = saturating_add_u64(
            totals->file_writeback,
            set->slices[i].file_writeback
        );
        totals->slab_reclaimable = saturating_add_u64(totals->slab_reclaimable, set->slices[i].slab_reclaimable);
        totals->slab_unreclaimable = saturating_add_u64(totals->slab_unreclaimable, set->slices[i].slab_unreclaimable);
        totals->workingset_refault_file = saturating_add_u64(
            totals->workingset_refault_file,
            set->slices[i].workingset_refault_file
        );
        totals->workingset_activate_file = saturating_add_u64(
            totals->workingset_activate_file,
            set->slices[i].workingset_activate_file
        );
        totals->workingset_restore_file = saturating_add_u64(
            totals->workingset_restore_file,
            set->slices[i].workingset_restore_file
        );
        totals->pgfault = saturating_add_u64(totals->pgfault, set->slices[i].pgfault);
        totals->pgmajfault = saturating_add_u64(
            totals->pgmajfault,
            set->slices[i].pgmajfault
        );
        totals->pgscan = saturating_add_u64(totals->pgscan, set->slices[i].pgscan);
        totals->pgsteal = saturating_add_u64(totals->pgsteal, set->slices[i].pgsteal);
        totals->pgscan_proactive = saturating_add_u64(
            totals->pgscan_proactive,
            set->slices[i].pgscan_proactive
        );
        totals->pgsteal_proactive = saturating_add_u64(
            totals->pgsteal_proactive,
            set->slices[i].pgsteal_proactive
        );
        totals->memory_events_local_low = saturating_add_u64(
            totals->memory_events_local_low,
            set->slices[i].memory_events_local_low
        );
        totals->memory_events_local_high = saturating_add_u64(
            totals->memory_events_local_high,
            set->slices[i].memory_events_local_high
        );
        totals->memory_events_local_max = saturating_add_u64(
            totals->memory_events_local_max,
            set->slices[i].memory_events_local_max
        );
        totals->memory_events_local_oom = saturating_add_u64(
            totals->memory_events_local_oom,
            set->slices[i].memory_events_local_oom
        );
        totals->memory_events_local_oom_kill = saturating_add_u64(
            totals->memory_events_local_oom_kill,
            set->slices[i].memory_events_local_oom_kill
        );
        totals->memory_events_local_oom_group_kill = saturating_add_u64(
            totals->memory_events_local_oom_group_kill,
            set->slices[i].memory_events_local_oom_group_kill
        );
        totals->populated = totals->populated || set->slices[i].populated;
    }
}

static void add_residual_service_root_slice(const char *service_cgroup, struct service_slice_set *set) {
    if (service_cgroup == NULL || service_cgroup[0] == '\0') {
        return;
    }
    struct service_slice_stat covered;
    accumulate_service_slice_totals(set, &covered);

    struct service_slice_stat aggregate;
    memset(&aggregate, 0, sizeof(aggregate));
    if (!read_cgroup_current_known(service_cgroup, &aggregate.memory_current)) {
        set->truncated = true;
        return;
    }
    if (aggregate.memory_current < covered.memory_current) {
        set->truncated = true;
        return;
    }
    if (aggregate.memory_current == 0 ||
        aggregate.memory_current == covered.memory_current ||
        aggregate.memory_current - covered.memory_current < SERVICE_SLICE_RESIDUAL_MIN_BYTES) {
        return;
    }
    snprintf(aggregate.key, sizeof(aggregate.key), "%s", SERVICE_ROOT_RESIDUAL_KEY);
    snprintf(aggregate.path, sizeof(aggregate.path), "%s", service_cgroup);
    aggregate.populated = read_cgroup_populated_known(
        service_cgroup,
        &aggregate.population_known
    );
    (void)read_cgroup_id(service_cgroup, &aggregate.cgroup_id);
    (void)add_service_slice_stat_file(service_cgroup, &aggregate);
    (void)add_service_slice_events_local(service_cgroup, &aggregate);
    (void)add_service_slice_psi(service_cgroup, &aggregate);

    struct service_slice_stat *residual =
        find_or_add_service_slice(set, SERVICE_ROOT_RESIDUAL_KEY, service_cgroup);
    if (residual == NULL) {
        return;
    }
    residual->memory_current = saturating_sub_u64(aggregate.memory_current, covered.memory_current);
    residual->anon = saturating_sub_u64(aggregate.anon, covered.anon);
    residual->file = saturating_sub_u64(aggregate.file, covered.file);
    residual->shmem = saturating_sub_u64(aggregate.shmem, covered.shmem);
    residual->sock = saturating_sub_u64(aggregate.sock, covered.sock);
    residual->kernel = saturating_sub_u64(aggregate.kernel, covered.kernel);
    residual->file_mapped = saturating_sub_u64(aggregate.file_mapped, covered.file_mapped);
    residual->inactive_anon = saturating_sub_u64(
        aggregate.inactive_anon,
        covered.inactive_anon
    );
    residual->active_anon = saturating_sub_u64(aggregate.active_anon, covered.active_anon);
    residual->inactive_file = saturating_sub_u64(aggregate.inactive_file, covered.inactive_file);
    residual->active_file = saturating_sub_u64(aggregate.active_file, covered.active_file);
    residual->file_dirty = saturating_sub_u64(aggregate.file_dirty, covered.file_dirty);
    residual->file_writeback = saturating_sub_u64(
        aggregate.file_writeback,
        covered.file_writeback
    );
    residual->slab_reclaimable = saturating_sub_u64(aggregate.slab_reclaimable, covered.slab_reclaimable);
    residual->slab_unreclaimable = saturating_sub_u64(aggregate.slab_unreclaimable, covered.slab_unreclaimable);
    residual->workingset_refault_file = saturating_sub_u64(
        aggregate.workingset_refault_file,
        covered.workingset_refault_file
    );
    residual->workingset_activate_file = saturating_sub_u64(
        aggregate.workingset_activate_file,
        covered.workingset_activate_file
    );
    residual->workingset_restore_file = saturating_sub_u64(
        aggregate.workingset_restore_file,
        covered.workingset_restore_file
    );
    residual->pgfault = saturating_sub_u64(aggregate.pgfault, covered.pgfault);
    residual->pgmajfault = saturating_sub_u64(aggregate.pgmajfault, covered.pgmajfault);
    residual->pgscan = saturating_sub_u64(aggregate.pgscan, covered.pgscan);
    residual->pgsteal = saturating_sub_u64(aggregate.pgsteal, covered.pgsteal);
    residual->pgscan_proactive = saturating_sub_u64(
        aggregate.pgscan_proactive,
        covered.pgscan_proactive
    );
    residual->pgsteal_proactive = saturating_sub_u64(
        aggregate.pgsteal_proactive,
        covered.pgsteal_proactive
    );
    residual->memory_events_local_low = saturating_sub_u64(
        aggregate.memory_events_local_low,
        covered.memory_events_local_low
    );
    residual->memory_events_local_high = saturating_sub_u64(
        aggregate.memory_events_local_high,
        covered.memory_events_local_high
    );
    residual->memory_events_local_max = saturating_sub_u64(
        aggregate.memory_events_local_max,
        covered.memory_events_local_max
    );
    residual->memory_events_local_oom = saturating_sub_u64(
        aggregate.memory_events_local_oom,
        covered.memory_events_local_oom
    );
    residual->memory_events_local_oom_kill = saturating_sub_u64(
        aggregate.memory_events_local_oom_kill,
        covered.memory_events_local_oom_kill
    );
    residual->memory_events_local_oom_group_kill = saturating_sub_u64(
        aggregate.memory_events_local_oom_group_kill,
        covered.memory_events_local_oom_group_kill
    );
    residual->cgroup_id = aggregate.cgroup_id;
    residual->populated = aggregate.populated;
    residual->population_known = aggregate.population_known;
    residual->telemetry_complete = false;
    residual->member_count = 1;
}

static uint64_t saturating_add_u64(uint64_t lhs, uint64_t rhs) {
    return UINT64_MAX - lhs < rhs ? UINT64_MAX : lhs + rhs;
}

static uint64_t saturating_sub_u64(uint64_t lhs, uint64_t rhs) {
    return lhs > rhs ? lhs - rhs : 0;
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
        DEFAULT_BUILD_CGROUP_PATH
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
    add_daemon_cgroup_memory_stat(daemon_cgroup, metrics);
    metrics->daemon_cgroup_populated = read_cgroup_populated_known(
        daemon_cgroup,
        &metrics->daemon_cgroup_population_known
    );
    uint64_t daemon_reclaimable = saturating_add_u64(
        metrics->daemon_cgroup_inactive_file,
        metrics->daemon_cgroup_slab_reclaimable
    );
    if (daemon_reclaimable > metrics->daemon_cgroup_memory_current) {
        daemon_reclaimable = metrics->daemon_cgroup_memory_current;
    }
    metrics->daemon_cgroup_working_set =
        saturating_sub_u64(metrics->daemon_cgroup_memory_current, daemon_reclaimable);
    bool service_current_known = read_cgroup_current_known(
        service_cgroup,
        &metrics->service_cgroup_memory_current
    );
    bool service_stat_complete = add_service_cgroup_memory_stat(service_cgroup, metrics);
    metrics->service_cgroup_populated = read_cgroup_populated_known(
        service_cgroup,
        &metrics->service_cgroup_population_known
    );
    bool service_cgroup_id_known = read_cgroup_id(
        service_cgroup,
        &metrics->service_cgroup_cgroup_id
    );
    struct cgroup_memory_events_local service_events;
    bool service_events_complete = read_cgroup_memory_events(
        service_cgroup,
        &service_events
    );
    metrics->service_cgroup_memory_events_low = service_events.low;
    metrics->service_cgroup_memory_events_high = service_events.high;
    metrics->service_cgroup_memory_events_max = service_events.max;
    metrics->service_cgroup_memory_events_oom = service_events.oom;
    metrics->service_cgroup_memory_events_oom_kill = service_events.oom_kill;
    metrics->service_cgroup_memory_events_oom_group_kill = service_events.oom_group_kill;
    struct cgroup_memory_events_local service_events_local;
    bool service_events_local_complete = read_cgroup_memory_events_local(
        service_cgroup,
        &service_events_local
    );
    metrics->service_cgroup_memory_events_local_low = service_events_local.low;
    metrics->service_cgroup_memory_events_local_high = service_events_local.high;
    metrics->service_cgroup_memory_events_local_max = service_events_local.max;
    metrics->service_cgroup_memory_events_local_oom = service_events_local.oom;
    metrics->service_cgroup_memory_events_local_oom_kill = service_events_local.oom_kill;
    metrics->service_cgroup_memory_events_local_oom_group_kill = service_events_local.oom_group_kill;
    struct cgroup_memory_psi service_psi;
    bool service_psi_complete = read_cgroup_memory_psi(service_cgroup, &service_psi);
    metrics->service_cgroup_psi_some_avg10 = service_psi.some_avg10;
    metrics->service_cgroup_psi_some_total_us = service_psi.some_total_us;
    metrics->service_cgroup_psi_full_avg10 = service_psi.full_avg10;
    metrics->service_cgroup_psi_full_total_us = service_psi.full_total_us;
    metrics->service_cgroup_telemetry_complete = service_current_known &&
        service_stat_complete && metrics->service_cgroup_population_known &&
        service_cgroup_id_known && service_events_complete &&
        service_events_local_complete && service_psi_complete;
    uint64_t dirty_and_writeback = saturating_add_u64(
        metrics->service_cgroup_file_dirty,
        metrics->service_cgroup_file_writeback
    );
    metrics->service_cgroup_clean_inactive_file = saturating_sub_u64(
        metrics->service_cgroup_inactive_file,
        dirty_and_writeback
    );
    uint64_t reclaimable = saturating_add_u64(
        metrics->service_cgroup_inactive_file,
        metrics->service_cgroup_slab_reclaimable
    );
    if (reclaimable > metrics->service_cgroup_memory_current) {
        reclaimable = metrics->service_cgroup_memory_current;
    }
    metrics->service_cgroup_working_set =
        saturating_sub_u64(metrics->service_cgroup_memory_current, reclaimable);
}

static bool parse_meminfo_kib_value(
    const char *line,
    const char *expected_key,
    uint64_t *bytes_out
) {
    size_t key_len = strlen(expected_key);
    if (strncmp(line, expected_key, key_len) != 0 || line[key_len] != ':') {
        return false;
    }
    const char *cursor = line + key_len + 1;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    if (*cursor == '+' || *cursor == '-') {
        return false;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long value_kib = strtoull(cursor, &end, 10);
    if (end == cursor || errno == ERANGE || value_kib > UINT64_MAX / 1024ULL) {
        return false;
    }
    cursor = end;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    if (strncmp(cursor, "kB", 2) != 0) {
        return false;
    }
    cursor += 2;
    if (!only_ascii_whitespace(cursor)) {
        return false;
    }
    *bytes_out = (uint64_t)value_kib * 1024ULL;
    return true;
}

static void read_meminfo_path(const char *path, struct memory_metrics *metrics) {
    metrics->mem_total = 0;
    metrics->mem_available = 0;
    metrics->mem_available_known = false;
    metrics->mem_free = 0;
    metrics->page_cache_bytes = 0;
    metrics->sreclaimable_bytes = 0;
    metrics->swap_total = 0;
    metrics->swap_free = 0;
    metrics->swap_telemetry_complete = false;

    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    bool mem_available_seen = false;
    bool swap_total_seen = false;
    bool swap_free_seen = false;
    char line[512];
    while (fgets(line, sizeof(line), f) != NULL) {
        uint64_t bytes = 0;
        if (parse_meminfo_kib_value(line, "MemTotal", &bytes)) {
            metrics->mem_total = bytes;
        } else if (parse_meminfo_kib_value(line, "MemAvailable", &bytes)) {
            metrics->mem_available = bytes;
            mem_available_seen = true;
        } else if (parse_meminfo_kib_value(line, "MemFree", &bytes)) {
            metrics->mem_free = bytes;
        } else if (parse_meminfo_kib_value(line, "Cached", &bytes) ||
                   parse_meminfo_kib_value(line, "Buffers", &bytes)) {
            metrics->page_cache_bytes = saturating_add_u64(
                metrics->page_cache_bytes,
                bytes
            );
        } else if (parse_meminfo_kib_value(line, "SReclaimable", &bytes)) {
            metrics->sreclaimable_bytes = bytes;
            metrics->page_cache_bytes = saturating_add_u64(
                metrics->page_cache_bytes,
                bytes
            );
        } else if (parse_meminfo_kib_value(line, "SwapTotal", &bytes)) {
            metrics->swap_total = bytes;
            swap_total_seen = true;
        } else if (parse_meminfo_kib_value(line, "SwapFree", &bytes)) {
            metrics->swap_free = bytes;
            swap_free_seen = true;
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    metrics->mem_available_known = read_ok && mem_available_seen;
    metrics->swap_telemetry_complete = read_ok && swap_total_seen &&
        swap_free_seen && metrics->swap_free <= metrics->swap_total;
}

static void read_meminfo(struct memory_metrics *metrics) {
    read_meminfo_path("/proc/meminfo", metrics);
}

static void read_psi_path(const char *path, struct memory_metrics *metrics) {
    metrics->psi_some_avg10 = 0.0;
    metrics->psi_full_avg10 = 0.0;
    metrics->global_psi_telemetry_complete = false;

    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    bool some_known = false;
    bool full_known = false;
    char line[512];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "some ", 5) == 0) {
            struct cgroup_memory_psi parsed;
            memset(&parsed, 0, sizeof(parsed));
            some_known = parse_pressure_line(
                line,
                &parsed.some_avg10,
                &parsed.some_total_us
            );
            if (some_known) {
                metrics->psi_some_avg10 = parsed.some_avg10;
            }
        } else if (strncmp(line, "full ", 5) == 0) {
            struct cgroup_memory_psi parsed;
            memset(&parsed, 0, sizeof(parsed));
            full_known = parse_pressure_line(
                line,
                &parsed.full_avg10,
                &parsed.full_total_us
            );
            if (full_known) {
                metrics->psi_full_avg10 = parsed.full_avg10;
            }
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    metrics->global_psi_telemetry_complete = read_ok && some_known && full_known;
}

static void read_psi(struct memory_metrics *metrics) {
    read_psi_path("/proc/pressure/memory", metrics);
}

static bool parse_u64_decimal_token(const char *token, uint64_t *value_out) {
    if (token[0] == '\0' || token[0] == '+' || token[0] == '-') {
        return false;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(token, &end, 10);
    if (end == token || *end != '\0' || errno == ERANGE) {
        return false;
    }
    *value_out = (uint64_t)parsed;
    return true;
}

static bool is_signed_decimal_token(const char *token) {
    if (token[0] == '\0') {
        return false;
    }
    errno = 0;
    char *end = NULL;
    (void)strtoll(token, &end, 10);
    return end != token && *end == '\0' && errno != ERANGE;
}

static bool swap_filename_is_zram(const char *filename) {
    const char *basename = strrchr(filename, '/');
    basename = basename == NULL ? filename : basename + 1;
    if (strncmp(basename, "zram", 4) != 0 || basename[4] < '0' || basename[4] > '9') {
        return false;
    }
    for (const char *cursor = basename + 5; *cursor != '\0'; cursor++) {
        if (*cursor < '0' || *cursor > '9') {
            return false;
        }
    }
    return true;
}

static bool parse_swap_columns(
    const char *line,
    char *first,
    size_t first_len,
    char *second,
    size_t second_len,
    char *third,
    size_t third_len,
    char *fourth,
    size_t fourth_len,
    char *fifth,
    size_t fifth_len
) {
    if (first_len < 256 || second_len < 64 || third_len < 64 ||
        fourth_len < 64 || fifth_len < 64) {
        return false;
    }
    int consumed = 0;
    int matched = sscanf(
        line,
        "%255s %63s %63s %63s %63s %n",
        first,
        second,
        third,
        fourth,
        fifth,
        &consumed
    );
    return matched == 5 && consumed > 0 && only_ascii_whitespace(line + consumed);
}

static void read_swaps_path(const char *path, struct memory_metrics *metrics) {
    metrics->disk_swap_total = 0;
    metrics->disk_swap_free = 0;
    metrics->disk_swap_telemetry_complete = false;

    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return;
    }
    char line[512];
    if (fgets(line, sizeof(line), f) == NULL) {
        fclose(f);
        return;
    }
    char filename[256];
    char type[64];
    char size_text[64];
    char used_text[64];
    char priority_text[64];
    bool header_valid = parse_swap_columns(
        line,
        filename,
        sizeof(filename),
        type,
        sizeof(type),
        size_text,
        sizeof(size_text),
        used_text,
        sizeof(used_text),
        priority_text,
        sizeof(priority_text)
    ) && strcmp(filename, "Filename") == 0 && strcmp(type, "Type") == 0 &&
        strcmp(size_text, "Size") == 0 && strcmp(used_text, "Used") == 0 &&
        strcmp(priority_text, "Priority") == 0;
    bool rows_valid = true;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (only_ascii_whitespace(line)) {
            continue;
        }
        char filename[256];
        char type[64];
        char size_text[64];
        char used_text[64];
        char priority_text[64];
        if (!parse_swap_columns(
                line,
                filename,
                sizeof(filename),
                type,
                sizeof(type),
                size_text,
                sizeof(size_text),
                used_text,
                sizeof(used_text),
                priority_text,
                sizeof(priority_text))) {
            rows_valid = false;
            continue;
        }
        uint64_t size_kib = 0;
        uint64_t used_kib = 0;
        if (!parse_u64_decimal_token(size_text, &size_kib) ||
            !parse_u64_decimal_token(used_text, &used_kib) ||
            !is_signed_decimal_token(priority_text) || used_kib > size_kib ||
            size_kib > UINT64_MAX / 1024ULL || used_kib > UINT64_MAX / 1024ULL) {
            rows_valid = false;
            continue;
        }
        uint64_t total = size_kib * 1024ULL;
        uint64_t used = used_kib * 1024ULL;
        uint64_t free_bytes = total - used;
        if (!swap_filename_is_zram(filename)) {
            if (UINT64_MAX - metrics->disk_swap_total < total ||
                UINT64_MAX - metrics->disk_swap_free < free_bytes) {
                rows_valid = false;
                continue;
            }
            metrics->disk_swap_total += total;
            metrics->disk_swap_free += free_bytes;
        }
    }
    bool read_ok = !ferror(f);
    fclose(f);
    metrics->disk_swap_telemetry_complete = read_ok && header_valid && rows_valid;
}

static void read_swaps(struct memory_metrics *metrics) {
    read_swaps_path("/proc/swaps", metrics);
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
    metrics.page_size_bytes = read_page_size_bytes();
    metrics.mglru_enabled = read_mglru_enabled();
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
        "{\"page_size_bytes\":%llu,"
        "\"mem_total\":%llu,\"mem_available\":%llu,"
        "\"mem_available_known\":%s,\"mem_free\":%llu,"
        "\"page_cache_bytes\":%llu,\"sreclaimable_bytes\":%llu,"
        "\"swap_total\":%llu,\"swap_free\":%llu,"
        "\"swap_telemetry_complete\":%s,"
        "\"disk_swap_total\":%llu,\"disk_swap_free\":%llu,"
        "\"disk_swap_telemetry_complete\":%s,"
        "\"zram_orig_data_size\":%llu,\"zram_compr_data_size\":%llu,"
        "\"zram_mem_used_total\":%llu,"
        "\"mglru_enabled\":%s,"
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
        "\"daemon_cgroup_working_set\":%llu,"
        "\"daemon_cgroup_anon\":%llu,"
        "\"daemon_cgroup_inactive_file\":%llu,"
        "\"daemon_cgroup_slab_reclaimable\":%llu,"
        "\"daemon_cgroup_populated\":%s,"
        "\"daemon_cgroup_population_known\":%s,"
        "\"service_cgroup_memory_current\":%llu,"
        "\"service_cgroup_working_set\":%llu,"
        "\"service_cgroup_anon\":%llu,\"service_cgroup_file\":%llu,"
        "\"service_cgroup_shmem\":%llu,\"service_cgroup_sock\":%llu,"
        "\"service_cgroup_kernel\":%llu,\"service_cgroup_file_mapped\":%llu,"
        "\"service_cgroup_inactive_anon\":%llu,\"service_cgroup_active_anon\":%llu,"
        "\"service_cgroup_inactive_file\":%llu,\"service_cgroup_active_file\":%llu,"
        "\"service_cgroup_file_dirty\":%llu,\"service_cgroup_file_writeback\":%llu,"
        "\"service_cgroup_clean_inactive_file\":%llu,"
        "\"service_cgroup_slab\":%llu,"
        "\"service_cgroup_slab_reclaimable\":%llu,"
        "\"service_cgroup_slab_unreclaimable\":%llu,"
        "\"service_cgroup_workingset_refault_file\":%llu,"
        "\"service_cgroup_workingset_activate_file\":%llu,"
        "\"service_cgroup_workingset_restore_file\":%llu,"
        "\"service_cgroup_pgfault\":%llu,\"service_cgroup_pgmajfault\":%llu,"
        "\"service_cgroup_pgscan\":%llu,\"service_cgroup_pgsteal\":%llu,"
        "\"service_cgroup_pgscan_proactive\":%llu,"
        "\"service_cgroup_pgsteal_proactive\":%llu,"
        "\"service_cgroup_memory_events_low\":%llu,"
        "\"service_cgroup_memory_events_high\":%llu,"
        "\"service_cgroup_memory_events_max\":%llu,"
        "\"service_cgroup_memory_events_oom\":%llu,"
        "\"service_cgroup_memory_events_oom_kill\":%llu,"
        "\"service_cgroup_memory_events_oom_group_kill\":%llu,"
        "\"service_cgroup_memory_events_local_low\":%llu,"
        "\"service_cgroup_memory_events_local_high\":%llu,"
        "\"service_cgroup_memory_events_local_max\":%llu,"
        "\"service_cgroup_memory_events_local_oom\":%llu,"
        "\"service_cgroup_memory_events_local_oom_kill\":%llu,"
        "\"service_cgroup_memory_events_local_oom_group_kill\":%llu,"
        "\"service_cgroup_psi_some_avg10\":%.2f,"
        "\"service_cgroup_psi_some_total_us\":%llu,"
        "\"service_cgroup_psi_full_avg10\":%.2f,"
        "\"service_cgroup_psi_full_total_us\":%llu,"
        "\"service_cgroup_cgroup_id\":%llu,"
        "\"service_cgroup_telemetry_complete\":%s,"
        "\"service_cgroup_populated\":%s,"
        "\"service_cgroup_population_known\":%s,"
        "\"psi_some_avg10\":%.2f,\"psi_full_avg10\":%.2f,"
        "\"global_psi_telemetry_complete\":%s,"
        "\"active_workloads\":%d,\"build_workload_detected\":%s,"
        "\"source\":\"conjet-memd\"}\n",
        (unsigned long long)metrics->page_size_bytes,
        (unsigned long long)metrics->mem_total,
        (unsigned long long)metrics->mem_available,
        metrics->mem_available_known ? "true" : "false",
        (unsigned long long)metrics->mem_free,
        (unsigned long long)metrics->page_cache_bytes,
        (unsigned long long)metrics->sreclaimable_bytes,
        (unsigned long long)metrics->swap_total,
        (unsigned long long)metrics->swap_free,
        metrics->swap_telemetry_complete ? "true" : "false",
        (unsigned long long)metrics->disk_swap_total,
        (unsigned long long)metrics->disk_swap_free,
        metrics->disk_swap_telemetry_complete ? "true" : "false",
        (unsigned long long)metrics->zram_orig_data_size,
        (unsigned long long)metrics->zram_compr_data_size,
        (unsigned long long)metrics->zram_mem_used_total,
        metrics->mglru_enabled ? "true" : "false",
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
        (unsigned long long)metrics->daemon_cgroup_working_set,
        (unsigned long long)metrics->daemon_cgroup_anon,
        (unsigned long long)metrics->daemon_cgroup_inactive_file,
        (unsigned long long)metrics->daemon_cgroup_slab_reclaimable,
        metrics->daemon_cgroup_populated ? "true" : "false",
        metrics->daemon_cgroup_population_known ? "true" : "false",
        (unsigned long long)metrics->service_cgroup_memory_current,
        (unsigned long long)metrics->service_cgroup_working_set,
        (unsigned long long)metrics->service_cgroup_anon,
        (unsigned long long)metrics->service_cgroup_file,
        (unsigned long long)metrics->service_cgroup_shmem,
        (unsigned long long)metrics->service_cgroup_sock,
        (unsigned long long)metrics->service_cgroup_kernel,
        (unsigned long long)metrics->service_cgroup_file_mapped,
        (unsigned long long)metrics->service_cgroup_inactive_anon,
        (unsigned long long)metrics->service_cgroup_active_anon,
        (unsigned long long)metrics->service_cgroup_inactive_file,
        (unsigned long long)metrics->service_cgroup_active_file,
        (unsigned long long)metrics->service_cgroup_file_dirty,
        (unsigned long long)metrics->service_cgroup_file_writeback,
        (unsigned long long)metrics->service_cgroup_clean_inactive_file,
        (unsigned long long)metrics->service_cgroup_slab,
        (unsigned long long)metrics->service_cgroup_slab_reclaimable,
        (unsigned long long)metrics->service_cgroup_slab_unreclaimable,
        (unsigned long long)metrics->service_cgroup_workingset_refault_file,
        (unsigned long long)metrics->service_cgroup_workingset_activate_file,
        (unsigned long long)metrics->service_cgroup_workingset_restore_file,
        (unsigned long long)metrics->service_cgroup_pgfault,
        (unsigned long long)metrics->service_cgroup_pgmajfault,
        (unsigned long long)metrics->service_cgroup_pgscan,
        (unsigned long long)metrics->service_cgroup_pgsteal,
        (unsigned long long)metrics->service_cgroup_pgscan_proactive,
        (unsigned long long)metrics->service_cgroup_pgsteal_proactive,
        (unsigned long long)metrics->service_cgroup_memory_events_low,
        (unsigned long long)metrics->service_cgroup_memory_events_high,
        (unsigned long long)metrics->service_cgroup_memory_events_max,
        (unsigned long long)metrics->service_cgroup_memory_events_oom,
        (unsigned long long)metrics->service_cgroup_memory_events_oom_kill,
        (unsigned long long)metrics->service_cgroup_memory_events_oom_group_kill,
        (unsigned long long)metrics->service_cgroup_memory_events_local_low,
        (unsigned long long)metrics->service_cgroup_memory_events_local_high,
        (unsigned long long)metrics->service_cgroup_memory_events_local_max,
        (unsigned long long)metrics->service_cgroup_memory_events_local_oom,
        (unsigned long long)metrics->service_cgroup_memory_events_local_oom_kill,
        (unsigned long long)metrics->service_cgroup_memory_events_local_oom_group_kill,
        metrics->service_cgroup_psi_some_avg10,
        (unsigned long long)metrics->service_cgroup_psi_some_total_us,
        metrics->service_cgroup_psi_full_avg10,
        (unsigned long long)metrics->service_cgroup_psi_full_total_us,
        (unsigned long long)metrics->service_cgroup_cgroup_id,
        metrics->service_cgroup_telemetry_complete ? "true" : "false",
        metrics->service_cgroup_populated ? "true" : "false",
        metrics->service_cgroup_population_known ? "true" : "false",
        metrics->psi_some_avg10,
        metrics->psi_full_avg10,
        metrics->global_psi_telemetry_complete ? "true" : "false",
        metrics->active_workloads,
        metrics->build_workload_detected ? "true" : "false");
}

static void write_http_response(int fd, const char *status, const char *content_type, const char *body);

static size_t append_json_escaped(char *body, size_t body_len, size_t offset, const char *value) {
    static const char hex[] = "0123456789abcdef";
    if (offset + 2 > body_len) {
        return SIZE_MAX;
    }
    body[offset++] = '"';
    body[offset] = '\0';
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        unsigned char ch = (unsigned char)*cursor;
        if (ch == '"' || ch == '\\') {
            if (offset + 3 > body_len) {
                return SIZE_MAX;
            }
            body[offset++] = '\\';
            body[offset++] = (char)ch;
        } else if (ch < 0x20) {
            if (offset + 7 > body_len) {
                return SIZE_MAX;
            }
            body[offset++] = '\\';
            body[offset++] = 'u';
            body[offset++] = '0';
            body[offset++] = '0';
            body[offset++] = hex[ch >> 4];
            body[offset++] = hex[ch & 0x0f];
        } else {
            if (offset + 2 > body_len) {
                return SIZE_MAX;
            }
            body[offset++] = (char)ch;
        }
        body[offset] = '\0';
    }
    if (offset + 2 > body_len) {
        return SIZE_MAX;
    }
    body[offset++] = '"';
    body[offset] = '\0';
    return offset;
}

static size_t service_slice_json_item(
    const struct service_slice_stat *slice,
    bool telemetry_authoritative,
    char *body,
    size_t body_len
) {
    size_t offset = 0;
    int n = snprintf(body, body_len, "{\"key\":");
    if (n < 0 || (size_t)n >= body_len) {
        return SIZE_MAX;
    }
    offset = (size_t)n;
    offset = append_json_escaped(body, body_len, offset, slice->key);
    if (offset == SIZE_MAX) {
        return SIZE_MAX;
    }
    n = snprintf(body + offset, body_len - offset, ",\"path\":");
    if (n < 0 || (size_t)n >= body_len - offset) {
        return SIZE_MAX;
    }
    offset += (size_t)n;
    offset = append_json_escaped(body, body_len, offset, slice->path);
    if (offset == SIZE_MAX) {
        return SIZE_MAX;
    }

    uint64_t reclaimable = service_slice_reclaimable(slice);
    uint64_t working_set = service_slice_working_set(slice);
    uint64_t clean_inactive_file = service_slice_clean_inactive_file(slice);
    n = snprintf(body + offset, body_len - offset,
        ",\"cgroup_id\":%llu,\"memory_current\":%llu,"
        "\"anon\":%llu,\"file\":%llu,\"shmem\":%llu,\"sock\":%llu,"
        "\"kernel\":%llu,\"file_mapped\":%llu,"
        "\"inactive_anon\":%llu,\"active_anon\":%llu,"
        "\"inactive_file\":%llu,\"active_file\":%llu,"
        "\"file_dirty\":%llu,\"file_writeback\":%llu,"
        "\"clean_inactive_file\":%llu,"
        "\"slab_reclaimable\":%llu,\"slab_unreclaimable\":%llu,"
        "\"workingset_refault_file\":%llu,"
        "\"workingset_activate_file\":%llu,"
        "\"workingset_restore_file\":%llu,"
        "\"pgfault\":%llu,\"pgmajfault\":%llu,"
        "\"pgscan\":%llu,\"pgsteal\":%llu,"
        "\"pgscan_proactive\":%llu,\"pgsteal_proactive\":%llu,"
        "\"memory_events_local_low\":%llu,"
        "\"memory_events_local_high\":%llu,"
        "\"memory_events_local_max\":%llu,"
        "\"memory_events_local_oom\":%llu,"
        "\"memory_events_local_oom_kill\":%llu,"
        "\"memory_events_local_oom_group_kill\":%llu,"
        "\"psi_some_avg10\":%.2f,\"psi_some_total_us\":%llu,"
        "\"psi_full_avg10\":%.2f,\"psi_full_total_us\":%llu,"
        "\"working_set\":%llu,\"reclaimable\":%llu,"
        "\"populated\":%s,\"population_known\":%s,"
        "\"telemetry_complete\":%s}",
        (unsigned long long)slice->cgroup_id,
        (unsigned long long)slice->memory_current,
        (unsigned long long)slice->anon,
        (unsigned long long)slice->file,
        (unsigned long long)slice->shmem,
        (unsigned long long)slice->sock,
        (unsigned long long)slice->kernel,
        (unsigned long long)slice->file_mapped,
        (unsigned long long)slice->inactive_anon,
        (unsigned long long)slice->active_anon,
        (unsigned long long)slice->inactive_file,
        (unsigned long long)slice->active_file,
        (unsigned long long)slice->file_dirty,
        (unsigned long long)slice->file_writeback,
        (unsigned long long)clean_inactive_file,
        (unsigned long long)slice->slab_reclaimable,
        (unsigned long long)slice->slab_unreclaimable,
        (unsigned long long)slice->workingset_refault_file,
        (unsigned long long)slice->workingset_activate_file,
        (unsigned long long)slice->workingset_restore_file,
        (unsigned long long)slice->pgfault,
        (unsigned long long)slice->pgmajfault,
        (unsigned long long)slice->pgscan,
        (unsigned long long)slice->pgsteal,
        (unsigned long long)slice->pgscan_proactive,
        (unsigned long long)slice->pgsteal_proactive,
        (unsigned long long)slice->memory_events_local_low,
        (unsigned long long)slice->memory_events_local_high,
        (unsigned long long)slice->memory_events_local_max,
        (unsigned long long)slice->memory_events_local_oom,
        (unsigned long long)slice->memory_events_local_oom_kill,
        (unsigned long long)slice->memory_events_local_oom_group_kill,
        slice->psi_some_avg10,
        (unsigned long long)slice->psi_some_total_us,
        slice->psi_full_avg10,
        (unsigned long long)slice->psi_full_total_us,
        (unsigned long long)working_set,
        (unsigned long long)reclaimable,
        slice->populated ? "true" : "false",
        slice->population_known ? "true" : "false",
        telemetry_authoritative && slice->telemetry_complete ? "true" : "false");
    if (n < 0 || (size_t)n >= body_len - offset) {
        return SIZE_MAX;
    }
    return offset + (size_t)n;
}

static bool service_slices_json(
    const struct service_slice_set *set,
    char *body,
    size_t body_len
) {
    const char prefix[] = "{\"version\":2,\"slices\":[";
    const char complete_suffix[] =
        "],\"truncated\":false,\"telemetry_complete\":true,"
        "\"source\":\"conjet-memd\"}\n";
    const char incomplete_suffix[] =
        "],\"truncated\":false,\"telemetry_complete\":false,"
        "\"source\":\"conjet-memd\"}\n";
    const char truncated_suffix[] =
        "],\"truncated\":true,\"telemetry_complete\":false,"
        "\"source\":\"conjet-memd\"}\n";
    size_t suffix_reserve = sizeof(complete_suffix);
    if (sizeof(incomplete_suffix) > suffix_reserve) {
        suffix_reserve = sizeof(incomplete_suffix);
    }
    if (sizeof(truncated_suffix) > suffix_reserve) {
        suffix_reserve = sizeof(truncated_suffix);
    }
    if (body_len < sizeof(prefix) + suffix_reserve) {
        if (body_len > 0) {
            body[0] = '\0';
        }
        return true;
    }

    char item[SERVICE_SLICE_JSON_ITEM_CAPACITY];
    size_t required = sizeof(prefix) - 1 + suffix_reserve;
    bool telemetry_complete = !set->truncated;
    for (size_t i = 0; i < set->count; i++) {
        telemetry_complete = telemetry_complete && set->slices[i].telemetry_complete;
    }
    bool truncated = set->truncated;
    for (size_t i = 0; i < set->count; i++) {
        size_t item_len = service_slice_json_item(
            &set->slices[i],
            false,
            item,
            sizeof(item)
        );
        size_t separator_len = i == 0 ? 0 : 1;
        if (item_len == SIZE_MAX || item_len > SIZE_MAX - required - separator_len) {
            truncated = true;
            break;
        }
        required += separator_len + item_len;
        if (required > body_len) {
            truncated = true;
            break;
        }
    }

    memcpy(body, prefix, sizeof(prefix) - 1);
    size_t offset = sizeof(prefix) - 1;
    size_t emitted = 0;
    const char *suffix = truncated ? truncated_suffix :
        (telemetry_complete ? complete_suffix : incomplete_suffix);
    size_t suffix_len = strlen(suffix);
    for (size_t i = 0; i < set->count; i++) {
        size_t item_len = service_slice_json_item(
            &set->slices[i],
            !truncated,
            item,
            sizeof(item)
        );
        size_t separator_len = emitted == 0 ? 0 : 1;
        size_t suffix_storage = suffix_reserve;
        if (item_len == SIZE_MAX ||
            suffix_storage > body_len ||
            separator_len > body_len - suffix_storage ||
            offset > body_len - suffix_storage - separator_len ||
            item_len > body_len - suffix_storage - separator_len - offset) {
            truncated = true;
            suffix = truncated_suffix;
            suffix_len = strlen(suffix);
            break;
        }
        if (separator_len != 0) {
            body[offset++] = ',';
        }
        memcpy(body + offset, item, item_len);
        offset += item_len;
        emitted++;
    }
    memcpy(body + offset, suffix, suffix_len + 1);
    return truncated;
}

static void write_service_slices_response(int client) {
    struct service_slice_set set;
    memset(&set, 0, sizeof(set));
    const char *root = configured_cgroup_path(
        "CONJET_SERVICE_SLICE_SCAN_ROOT",
        "/sys/fs/cgroup/conjet.slice"
    );
    scan_service_slice_cgroups(root, 0, &set);
    const char *service_cgroup = configured_cgroup_path(
        "CONJET_SERVICE_CGROUP",
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice"
    );
    add_residual_service_root_slice(service_cgroup, &set);
    const size_t body_len = SERVICE_SLICES_JSON_CAPACITY;
    char *body = calloc(1, body_len);
    if (body == NULL) {
        write_http_response(client, "503 Service Unavailable", "text/plain", "out of memory\n");
        return;
    }
    service_slices_json(&set, body, body_len);
    write_http_response(client, "200 OK", "application/json", body);
    free(body);
}

static void capabilities_json(bool mglru_enabled, char *body, size_t body_len) {
    snprintf(
        body,
        body_len,
        "{\"version\":5,\"dynamic_memory_events\":true,"
        "\"cache_reclaim\":true,\"service_slices\":true,"
        "\"service_reclaim\":true,\"service_feedback\":true,"
        "\"mglru_enabled\":%s,\"source\":\"conjet-memd\"}\n",
        mglru_enabled ? "true" : "false"
    );
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

static int hex_value(char ch) {
    if (ch >= '0' && ch <= '9') {
        return ch - '0';
    }
    if (ch >= 'a' && ch <= 'f') {
        return ch - 'a' + 10;
    }
    if (ch >= 'A' && ch <= 'F') {
        return ch - 'A' + 10;
    }
    return -1;
}

static void extract_query_string(const char *request, const char *name, char *out, size_t out_len) {
    if (out_len == 0) {
        return;
    }
    out[0] = '\0';
    char needle[128];
    snprintf(needle, sizeof(needle), "%s=", name);
    const char *cursor = strstr(request, needle);
    if (cursor == NULL) {
        return;
    }
    cursor += strlen(needle);
    size_t offset = 0;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '&' && offset + 1 < out_len) {
        if (*cursor == '%' && cursor[1] != '\0' && cursor[2] != '\0') {
            int high = hex_value(cursor[1]);
            int low = hex_value(cursor[2]);
            if (high >= 0 && low >= 0) {
                out[offset++] = (char)((high << 4) | low);
                cursor += 3;
                continue;
            }
        }
        out[offset++] = *cursor == '+' ? ' ' : *cursor;
        cursor++;
    }
    out[offset] = '\0';
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

static bool string_contains_control_or_parent_ref(const char *value) {
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        unsigned char ch = (unsigned char)*cursor;
        if (ch < 0x20 || ch == 0x7f) {
            return true;
        }
    }
    return strstr(value, "/../") != NULL ||
           strstr(value, "/..") != NULL ||
           strstr(value, "../") != NULL;
}

static bool residual_service_reclaim_request_is_valid(const struct reclaim_request *request) {
    if (strcmp(request->service_key, SERVICE_ROOT_RESIDUAL_KEY) != 0) {
        return false;
    }
    const char *service_cgroup = configured_cgroup_path(
        "CONJET_SERVICE_CGROUP",
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice"
    );
    return strcmp(request->cgroup_path, service_cgroup) == 0;
}

static bool service_reclaim_request_is_valid(const struct reclaim_request *request) {
    if (!request->service_scoped ||
        request->bytes == 0 ||
        request->service_key[0] == '\0' ||
        request->cgroup_path[0] == '\0') {
        return false;
    }
    if (strncmp(request->cgroup_path, "/sys/fs/cgroup/", strlen("/sys/fs/cgroup/")) != 0) {
        return false;
    }
    if (string_contains_control_or_parent_ref(request->service_key) ||
        string_contains_control_or_parent_ref(request->cgroup_path)) {
        return false;
    }
    if (strcmp(request->service_key, SERVICE_ROOT_RESIDUAL_KEY) == 0) {
        return residual_service_reclaim_request_is_valid(request);
    }
    char extracted_key[96];
    if (!extract_service_slice_key(request->cgroup_path, extracted_key, sizeof(extracted_key))) {
        return false;
    }
    return strcmp(extracted_key, request->service_key) == 0;
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

static int spawn_reclaim_worker(const struct reclaim_request *request, pid_t *pid_out) {
    char epoch_arg[32];
    char bytes_arg[32];
    const char *worker_path = getenv("CONJET_RECLAIMD_PATH");
    if (worker_path == NULL || worker_path[0] == '\0') {
        worker_path = "/usr/local/sbin/conjet-reclaimd";
    }
    snprintf(epoch_arg, sizeof(epoch_arg), "%llu", (unsigned long long)request->epoch);
    snprintf(bytes_arg, sizeof(bytes_arg), "%llu", (unsigned long long)request->bytes);
    char *argv[12];
    size_t argc = 0;
    argv[argc++] = "conjet-reclaimd";
    argv[argc++] = "--epoch";
    argv[argc++] = epoch_arg;
    if (request->service_scoped) {
        argv[argc++] = "--service-key";
        argv[argc++] = (char *)request->service_key;
        argv[argc++] = "--cgroup";
        argv[argc++] = (char *)request->cgroup_path;
        argv[argc++] = "--bytes";
        argv[argc++] = bytes_arg;
    }
    argv[argc] = NULL;
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
        if (reclaim_pending_request_available) {
            struct reclaim_request request = reclaim_pending_request;
            reclaim_pending_request_available = false;
            pid_t next = -1;
            int spawn_rc = spawn_reclaim_worker(&request, &next);
            if (spawn_rc == 0) {
                reclaim_worker_pid = next;
                reclaim_status_state.epoch = request.epoch;
                reclaim_status_state.requested_bytes = request.bytes;
                reclaim_status_state.state = RECLAIM_QUEUED;
                reclaim_status_state.error_number = 0;
                snprintf(reclaim_status_state.reason, sizeof(reclaim_status_state.reason), "%s", request.reason);
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

static int submit_reclaim_worker_locked(const struct reclaim_request *request) {
    int rc = start_reclaim_monitor_locked();
    if (rc != 0) {
        return rc;
    }
    if (reclaim_worker_pid > 0) {
        reclaim_pending_request = *request;
        reclaim_pending_request_available = true;
        pthread_cond_signal(&reclaim_cond);
        return 0;
    }
    pid_t pid = -1;
    rc = spawn_reclaim_worker(request, &pid);
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
    struct reclaim_request reclaim_request;
    memset(&reclaim_request, 0, sizeof(reclaim_request));
    reclaim_request.epoch = reclaim_status_state.epoch;
    snprintf(reclaim_request.reason, sizeof(reclaim_request.reason), "%s", reason);
    reclaim_status_state.requested_bytes = 0;
    reclaim_status_state.observed_current_drop_bytes = 0;
    reclaim_status_state.error_number = 0;
    reclaim_status_state.state = RECLAIM_QUEUED;
    snprintf(reclaim_status_state.reason, sizeof(reclaim_status_state.reason), "%s", reason);
    int submit_rc = submit_reclaim_worker_locked(&reclaim_request);
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

static void write_service_reclaim_submission_response(int client, const char *request) {
    struct reclaim_status snapshot;
    char reason[64];
    extract_reclaim_reason(request, reason, sizeof(reason));

    struct reclaim_request reclaim_request;
    memset(&reclaim_request, 0, sizeof(reclaim_request));
    reclaim_request.service_scoped = true;
    reclaim_request.bytes = extract_query_u64(request, "bytes");
    snprintf(reclaim_request.reason, sizeof(reclaim_request.reason), "%s", reason);
    extract_query_string(request, "key", reclaim_request.service_key, sizeof(reclaim_request.service_key));
    extract_query_string(request, "path", reclaim_request.cgroup_path, sizeof(reclaim_request.cgroup_path));

    if (!service_reclaim_request_is_valid(&reclaim_request)) {
        write_http_response(client, "400 Bad Request", "application/json",
            "{\"accepted\":false,\"epoch\":0,\"state\":\"error\",\"error_number\":22,\"source\":\"conjet-memd\"}\n");
        return;
    }

    pthread_mutex_lock(&reclaim_lock);
    reclaim_status_state.epoch++;
    reclaim_request.epoch = reclaim_status_state.epoch;
    reclaim_status_state.requested_bytes = reclaim_request.bytes;
    reclaim_status_state.observed_current_drop_bytes = 0;
    reclaim_status_state.error_number = 0;
    reclaim_status_state.state = RECLAIM_QUEUED;
    snprintf(reclaim_status_state.reason, sizeof(reclaim_status_state.reason), "%s", reason);
    int submit_rc = submit_reclaim_worker_locked(&reclaim_request);
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
        reclaim_pending_request_available = false;
        memset(&reclaim_pending_request, 0, sizeof(reclaim_pending_request));
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

    char body[METRICS_JSON_CAPACITY];
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
    const char service_slices_path[] = "GET /conjet-memory-service-slices ";
    const char events_path[] = "GET /conjet-memory-events ";
    const char capabilities_path[] = "GET /conjet-memory-capabilities ";
    const char reclaim_get_path[] = "GET /conjet-memory-reclaim";
    const char reclaim_post_path[] = "POST /conjet-memory-reclaim";
    const char service_reclaim_post_path[] = "POST /conjet-memory-reclaim/service";
    const char reclaim_cancel_path[] = "POST /conjet-memory-reclaim/cancel-before";
    const char reclaim_status_path[] = "GET /conjet-memory-reclaim/status";
    if ((size_t)n >= sizeof(metrics_path) - 1 &&
        memcmp(first, metrics_path, sizeof(metrics_path) - 1) == 0) {
        char body[METRICS_JSON_CAPACITY];
        struct memory_metrics metrics = collect_metrics();
        metrics_json(&metrics, body, sizeof(body));
        write_http_response(client, "200 OK", "application/json", body);
    } else if ((size_t)n >= sizeof(service_slices_path) - 1 &&
               memcmp(first, service_slices_path, sizeof(service_slices_path) - 1) == 0) {
        write_service_slices_response(client);
    } else if ((size_t)n >= sizeof(reclaim_status_path) - 1 &&
               memcmp(first, reclaim_status_path, sizeof(reclaim_status_path) - 1) == 0) {
        write_reclaim_status_response(client, first);
    } else if ((size_t)n >= sizeof(reclaim_cancel_path) - 1 &&
               memcmp(first, reclaim_cancel_path, sizeof(reclaim_cancel_path) - 1) == 0) {
        write_reclaim_cancel_response(client, first);
    } else if ((size_t)n >= sizeof(service_reclaim_post_path) - 1 &&
               memcmp(first, service_reclaim_post_path, sizeof(service_reclaim_post_path) - 1) == 0) {
        write_service_reclaim_submission_response(client, first);
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
        char body[512];
        capabilities_json(read_mglru_enabled(), body, sizeof(body));
        write_http_response(client, "200 OK", "application/json", body);
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
        char body[METRICS_JSON_CAPACITY];
        struct memory_metrics metrics = collect_metrics();
        metrics_json(&metrics, body, sizeof(body));
        fputs(body, stdout);
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--reclaim") == 0) {
        struct reclaim_status snapshot;
        pthread_mutex_lock(&reclaim_lock);
        reclaim_status_state.epoch++;
        struct reclaim_request reclaim_request;
        memset(&reclaim_request, 0, sizeof(reclaim_request));
        reclaim_request.epoch = reclaim_status_state.epoch;
        snprintf(reclaim_request.reason, sizeof(reclaim_request.reason), "cli");
        reclaim_status_state.state = RECLAIM_QUEUED;
        reclaim_status_state.error_number = submit_reclaim_worker_locked(&reclaim_request);
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
        struct sockaddr_vm peer;
        socklen_t peer_len = sizeof(peer);
        memset(&peer, 0, sizeof(peer));
        int client = accept(server, (struct sockaddr *)&peer, &peer_len);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (!is_host_vsock_peer(&peer, peer_len)) {
            close_fd(client);
            continue;
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
