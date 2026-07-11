#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#include <signal.h>
#include <time.h>
#include <unistd.h>

#define RECLAIM_CHUNK_BYTES (64ULL * 1024ULL * 1024ULL)
#define BUILD_CAP_BYTES (4ULL * 1024ULL * 1024ULL * 1024ULL)
#define SERVICE_CAP_BYTES (4ULL * 1024ULL * 1024ULL * 1024ULL)
#define DAEMON_CAP_BYTES (512ULL * 1024ULL * 1024ULL)
#define BUILD_RESERVE_BYTES (64ULL * 1024ULL * 1024ULL)
#define SERVICE_RESERVE_BYTES (128ULL * 1024ULL * 1024ULL)
#define DAEMON_RESERVE_BYTES (128ULL * 1024ULL * 1024ULL)
#define DAEMON_IDLE_RESERVE_BYTES (32ULL * 1024ULL * 1024ULL)
#define IDLE_DAEMON_RECLAIM_SETTLE_MILLIS 500L
#define SLAB_CAP_BYTES (256ULL * 1024ULL * 1024ULL)
#define LOW_PROGRESS_BYTES (4ULL * 1024ULL * 1024ULL)
#define NO_PROGRESS_LIMIT 2
#define SYNCFS_DIRTY_THRESHOLD_BYTES (64ULL * 1024ULL * 1024ULL)
#define DEFAULT_BUILD_CGROUP_PATH \
    "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice/conjet-build.slice"

static volatile sig_atomic_t stop_requested = 0;

struct memcg_stat {
    uint64_t memory_current;
    uint64_t inactive_file;
    uint64_t slab_reclaimable;
    uint64_t file_dirty;
    uint64_t file_writeback;
};

struct reclaim_summary {
    uint64_t epoch;
    uint64_t requested_bytes;
    uint64_t observed_current_drop_bytes;
    uint64_t before_current;
    uint64_t after_current;
    uint64_t before_inactive_file;
    uint64_t after_inactive_file;
    uint64_t before_slab_reclaimable;
    uint64_t after_slab_reclaimable;
    uint64_t before_file_dirty;
    uint64_t after_file_dirty;
    uint64_t before_file_writeback;
    uint64_t after_file_writeback;
    uint32_t chunks;
    uint32_t eagain_count;
    bool syncfs_attempted;
    int32_t syncfs_error_number;
    bool drop_caches_attempted;
    int32_t drop_caches_error_number;
    int32_t error_number;
    const char *state;
    const char *scope;
    const char *service_key;
    const char *cgroup_path;
};

struct reclaim_config {
    uint64_t epoch;
    bool service_scoped;
    uint64_t bytes;
    char service_key[96];
    char cgroup_path[4096];
};

static uint64_t min_u64(uint64_t lhs, uint64_t rhs) {
    return lhs < rhs ? lhs : rhs;
}

static uint64_t saturating_add_u64(uint64_t lhs, uint64_t rhs) {
    return UINT64_MAX - lhs < rhs ? UINT64_MAX : lhs + rhs;
}

static uint64_t saturating_sub_u64(uint64_t lhs, uint64_t rhs) {
    return lhs > rhs ? lhs - rhs : 0;
}

static void add_memcg_stat(struct memcg_stat *total, const struct memcg_stat *stat) {
    total->memory_current = saturating_add_u64(total->memory_current, stat->memory_current);
    total->inactive_file = saturating_add_u64(total->inactive_file, stat->inactive_file);
    total->slab_reclaimable =
        saturating_add_u64(total->slab_reclaimable, stat->slab_reclaimable);
    total->file_dirty = saturating_add_u64(total->file_dirty, stat->file_dirty);
    total->file_writeback = saturating_add_u64(total->file_writeback, stat->file_writeback);
}

static void sleep_millis(long millis) {
    struct timespec req = {
        .tv_sec = millis / 1000,
        .tv_nsec = (millis % 1000) * 1000000L,
    };
    while (nanosleep(&req, &req) != 0 && errno == EINTR) {}
}

static void request_stop(int signum) {
    (void)signum;
    stop_requested = 1;
}

static int read_uint_file_at(const char *cgroup, const char *name, uint64_t *value) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s", cgroup, name);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return errno;
    }
    unsigned long long parsed = 0;
    if (fscanf(f, "%llu", &parsed) != 1) {
        int close_rc = fclose(f);
        (void)close_rc;
        return EIO;
    }
    if (fclose(f) != 0) {
        return errno;
    }
    *value = (uint64_t)parsed;
    return 0;
}

static int read_memcg_stat(const char *cgroup, struct memcg_stat *out) {
    memset(out, 0, sizeof(*out));
    int rc = read_uint_file_at(cgroup, "memory.current", &out->memory_current);
    if (rc != 0) {
        return rc;
    }
    char path[4096];
    snprintf(path, sizeof(path), "%s/memory.stat", cgroup);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return errno;
    }
    char key[128];
    unsigned long long value = 0;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        if (strcmp(key, "inactive_file") == 0) {
            out->inactive_file = (uint64_t)value;
        } else if (strcmp(key, "slab_reclaimable") == 0) {
            out->slab_reclaimable = (uint64_t)value;
        } else if (strcmp(key, "file_dirty") == 0) {
            out->file_dirty = (uint64_t)value;
        } else if (strcmp(key, "file_writeback") == 0) {
            out->file_writeback = (uint64_t)value;
        }
    }
    if (ferror(f)) {
        int saved = errno == 0 ? EIO : errno;
        fclose(f);
        return saved;
    }
    if (fclose(f) != 0) {
        return errno;
    }
    return 0;
}

static int read_cgroup_populated(const char *cgroup, bool *populated) {
    if (populated == NULL) {
        return EINVAL;
    }
    // Treat an unreadable event file as active. Reclaiming a stopped service
    // aggressively is safe, but only after the kernel has explicitly reported
    // that the hierarchy is empty.
    *populated = true;
    char path[4096];
    snprintf(path, sizeof(path), "%s/cgroup.events", cgroup);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return errno;
    }
    char key[128];
    unsigned long long value = 0;
    bool found = false;
    while (fscanf(f, "%127s %llu", key, &value) == 2) {
        if (strcmp(key, "populated") == 0) {
            *populated = value != 0;
            found = true;
            break;
        }
    }
    if (ferror(f)) {
        int saved = errno == 0 ? EIO : errno;
        fclose(f);
        return saved;
    }
    if (fclose(f) != 0) {
        return errno;
    }
    return found ? 0 : EIO;
}

static uint64_t service_reclaim_reserve(const char *service_cgroup) {
    bool populated = true;
    if (read_cgroup_populated(service_cgroup, &populated) != 0 || populated) {
        return SERVICE_RESERVE_BYTES;
    }
    // No process remains in this hierarchy. Its inactive file cache and
    // reclaimable slab have no service-latency value, so do not keep the normal
    // hot-service reserve after a Docker stop.
    return 0;
}

static bool cgroup_is_empty_or_absent(const char *cgroup) {
    bool populated = true;
    int rc = read_cgroup_populated(cgroup, &populated);
    return rc == ENOENT || (rc == 0 && !populated);
}

static bool daemon_idle_reclaim_allowed(const char *build_cgroup, const char *service_cgroup) {
    return cgroup_is_empty_or_absent(build_cgroup)
        && cgroup_is_empty_or_absent(service_cgroup);
}

static uint64_t daemon_reclaim_reserve(const char *build_cgroup, const char *service_cgroup) {
    // Docker itself remains active after `docker stop`, but its clean inactive
    // file cache no longer has a service-start latency benefit once both the
    // build and service cgroup hierarchies are empty. Keep a small daemon cache
    // floor for control-plane responsiveness while returning the old hot-cache
    // reserve to the guest immediately.
    if (daemon_idle_reclaim_allowed(build_cgroup, service_cgroup)) {
        return DAEMON_IDLE_RESERVE_BYTES;
    }
    return DAEMON_RESERVE_BYTES;
}

static uint64_t reclaim_candidate(const struct memcg_stat *stat, uint64_t cap, uint64_t reserve) {
    uint64_t dirty = saturating_add_u64(stat->file_dirty, stat->file_writeback);
    uint64_t clean_inactive = saturating_sub_u64(stat->inactive_file, dirty);
    uint64_t slab = min_u64(stat->slab_reclaimable, SLAB_CAP_BYTES);
    uint64_t candidate = saturating_add_u64(clean_inactive, slab);
    candidate = saturating_sub_u64(candidate, reserve);
    return min_u64(candidate, cap);
}

static int write_memory_reclaim(const char *cgroup, uint64_t bytes) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/memory.reclaim", cgroup);
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        return errno;
    }
    char request[96];
    int len = snprintf(request, sizeof(request), "%llu swappiness=0\n", (unsigned long long)bytes);
    ssize_t written = write(fd, request, (size_t)len);
    int saved = written == len ? 0 : (errno == 0 ? EIO : errno);
    if (close(fd) != 0 && saved == 0) {
        saved = errno;
    }
    return saved;
}

static int reclaim_one_cgroup(const char *cgroup,
                              uint64_t cap,
                              uint64_t reserve,
                              struct reclaim_summary *summary) {
    struct memcg_stat before;
    int read_rc = read_memcg_stat(cgroup, &before);
    if (read_rc != 0) {
        return read_rc == ENOENT ? 0 : read_rc;
    }
    uint64_t remaining = reclaim_candidate(&before, cap, reserve);
    unsigned no_progress = 0;
    while (remaining != 0) {
        if (stop_requested) {
            return ECANCELED;
        }
        uint64_t chunk = min_u64(remaining, RECLAIM_CHUNK_BYTES);
        struct memcg_stat pre;
        struct memcg_stat post;
        read_rc = read_memcg_stat(cgroup, &pre);
        if (read_rc != 0) {
            return read_rc;
        }
        int rc = write_memory_reclaim(cgroup, chunk);
        read_rc = read_memcg_stat(cgroup, &post);
        if (read_rc != 0) {
            return read_rc;
        }
        uint64_t progress = saturating_sub_u64(pre.memory_current, post.memory_current);
        summary->requested_bytes = saturating_add_u64(summary->requested_bytes, chunk);
        summary->observed_current_drop_bytes =
            saturating_add_u64(summary->observed_current_drop_bytes, progress);
        summary->chunks++;
        if (rc != 0 && rc == EAGAIN) {
            summary->eagain_count++;
        } else if (rc != 0) {
            return rc;
        }
        if (progress < LOW_PROGRESS_BYTES) {
            if (++no_progress >= NO_PROGRESS_LIMIT) {
                break;
            }
        } else {
            no_progress = 0;
        }
        remaining = saturating_sub_u64(remaining, chunk);
        sleep_millis(10);
    }
    return 0;
}

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

static int cgroup_name_has_prefixed_scope(const char *name, const char *prefix) {
    size_t prefix_len = strlen(prefix);
    return strncmp(name, prefix, prefix_len) == 0 && name[prefix_len] == ':';
}

static int reclaim_cgroup_with_prefixed_siblings(const char *cgroup,
                                                 uint64_t cap,
                                                 uint64_t reserve,
                                                 struct reclaim_summary *summary) {
    int first_error = reclaim_one_cgroup(cgroup, cap, reserve, summary);
    if (first_error != 0) {
        return first_error;
    }

    char parent[4096];
    const char *basename = NULL;
    if (split_parent_basename(cgroup, parent, sizeof(parent), &basename) != 0) {
        return 0;
    }
    DIR *dir = opendir(parent);
    if (dir == NULL) {
        return errno == ENOENT ? 0 : errno;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!cgroup_name_has_prefixed_scope(entry->d_name, basename)) {
            continue;
        }
        char child[4096];
        int written = snprintf(child, sizeof(child), "%s/%s", parent, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(child)) {
            closedir(dir);
            return ENAMETOOLONG;
        }
        struct stat st;
        if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        int rc = reclaim_one_cgroup(child, cap, 0, summary);
        if (rc != 0) {
            closedir(dir);
            return rc;
        }
    }
    closedir(dir);
    return 0;
}

static uint64_t reclaim_requested_delta(uint64_t before, const struct reclaim_summary *summary) {
    return summary->requested_bytes > before ? summary->requested_bytes - before : 0;
}

static int reclaim_cgroup_with_prefixed_siblings_budget(const char *cgroup,
                                                        uint64_t budget,
                                                        struct reclaim_summary *summary) {
    if (budget == 0) {
        return 0;
    }
    uint64_t before_requested = summary->requested_bytes;
    int first_error = reclaim_one_cgroup(cgroup, budget, 0, summary);
    if (first_error != 0) {
        return first_error;
    }
    uint64_t used = reclaim_requested_delta(before_requested, summary);
    uint64_t remaining = saturating_sub_u64(budget, used);
    if (remaining == 0) {
        return 0;
    }

    char parent[4096];
    const char *basename = NULL;
    if (split_parent_basename(cgroup, parent, sizeof(parent), &basename) != 0) {
        return 0;
    }
    DIR *dir = opendir(parent);
    if (dir == NULL) {
        return errno == ENOENT ? 0 : errno;
    }

    struct dirent *entry;
    while (remaining != 0 && (entry = readdir(dir)) != NULL) {
        if (!cgroup_name_has_prefixed_scope(entry->d_name, basename)) {
            continue;
        }
        char child[4096];
        int written = snprintf(child, sizeof(child), "%s/%s", parent, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(child)) {
            closedir(dir);
            return ENAMETOOLONG;
        }
        struct stat st;
        if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        before_requested = summary->requested_bytes;
        int rc = reclaim_one_cgroup(child, remaining, 0, summary);
        if (rc != 0) {
            closedir(dir);
            return rc;
        }
        used = reclaim_requested_delta(before_requested, summary);
        remaining = saturating_sub_u64(remaining, used);
    }
    closedir(dir);
    return 0;
}

static int aggregate_one_cgroup_stat(const char *cgroup, struct memcg_stat *total) {
    struct memcg_stat stat;
    int rc = read_memcg_stat(cgroup, &stat);
    if (rc != 0) {
        return rc == ENOENT ? 0 : rc;
    }
    add_memcg_stat(total, &stat);
    return 0;
}

static int aggregate_cgroup_with_prefixed_siblings_stat(const char *cgroup, struct memcg_stat *total) {
    int rc = aggregate_one_cgroup_stat(cgroup, total);
    if (rc != 0) {
        return rc;
    }

    char parent[4096];
    const char *basename = NULL;
    if (split_parent_basename(cgroup, parent, sizeof(parent), &basename) != 0) {
        return 0;
    }
    DIR *dir = opendir(parent);
    if (dir == NULL) {
        return errno == ENOENT ? 0 : errno;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!cgroup_name_has_prefixed_scope(entry->d_name, basename)) {
            continue;
        }
        char child[4096];
        int written = snprintf(child, sizeof(child), "%s/%s", parent, entry->d_name);
        if (written <= 0 || (size_t)written >= sizeof(child)) {
            closedir(dir);
            return ENAMETOOLONG;
        }
        struct stat st;
        if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        rc = aggregate_one_cgroup_stat(child, total);
        if (rc != 0) {
            closedir(dir);
            return rc;
        }
    }
    closedir(dir);
    return 0;
}

static int aggregate_reclaim_targets_stat(const char *build_cgroup,
                                          const char *daemon_cgroup,
                                          const char *service_cgroup,
                                          struct memcg_stat *total) {
    memset(total, 0, sizeof(*total));
    int rc = aggregate_cgroup_with_prefixed_siblings_stat(build_cgroup, total);
    if (rc != 0) {
        return rc;
    }
    rc = aggregate_cgroup_with_prefixed_siblings_stat(service_cgroup, total);
    if (rc != 0) {
        return rc;
    }
    return aggregate_one_cgroup_stat(daemon_cgroup, total);
}

static int reclaim_all_targets(const char *build_cgroup,
                               const char *daemon_cgroup,
                               const char *service_cgroup,
                               struct reclaim_summary *summary) {
    int rc = reclaim_cgroup_with_prefixed_siblings(
        build_cgroup,
        BUILD_CAP_BYTES,
        BUILD_RESERVE_BYTES,
        summary
    );
    if (rc != 0) {
        return rc;
    }
    rc = reclaim_cgroup_with_prefixed_siblings(
        service_cgroup,
        SERVICE_CAP_BYTES,
        service_reclaim_reserve(service_cgroup),
        summary
    );
    if (rc != 0) {
        return rc;
    }
    uint64_t daemon_reserve = daemon_reclaim_reserve(build_cgroup, service_cgroup);
    bool daemon_idle = daemon_reserve == DAEMON_IDLE_RESERVE_BYTES;
    rc = reclaim_one_cgroup(
        daemon_cgroup,
        DAEMON_CAP_BYTES,
        daemon_reserve,
        summary
    );
    if (rc != 0 || !daemon_idle || stop_requested) {
        return rc;
    }

    // Cgroup page-cache ownership can settle a short time after Docker has
    // stopped the last service. Retry only the daemon's clean-cache reclaim in
    // that confirmed-idle state so a newly charged inactive range cannot keep
    // the host VMM footprint elevated until a later Docker request.
    sleep_millis(IDLE_DAEMON_RECLAIM_SETTLE_MILLIS);
    if (stop_requested) {
        return ECANCELED;
    }
    return reclaim_one_cgroup(
        daemon_cgroup,
        DAEMON_CAP_BYTES,
        DAEMON_IDLE_RESERVE_BYTES,
        summary
    );
}

static void set_summary_before_stat(struct reclaim_summary *summary, const struct memcg_stat *stat) {
    summary->before_current = stat->memory_current;
    summary->before_inactive_file = stat->inactive_file;
    summary->before_slab_reclaimable = stat->slab_reclaimable;
    summary->before_file_dirty = stat->file_dirty;
    summary->before_file_writeback = stat->file_writeback;
}

static void set_summary_after_stat(struct reclaim_summary *summary, const struct memcg_stat *stat) {
    summary->after_current = stat->memory_current;
    summary->after_inactive_file = stat->inactive_file;
    summary->after_slab_reclaimable = stat->slab_reclaimable;
    summary->after_file_dirty = stat->file_dirty;
    summary->after_file_writeback = stat->file_writeback;
}

static uint64_t dirty_writeback_bytes(const struct memcg_stat *stat) {
    return saturating_add_u64(stat->file_dirty, stat->file_writeback);
}

static uint64_t configured_syncfs_threshold(void) {
    const char *raw = getenv("CONJET_RECLAIM_SYNCFS_DIRTY_THRESHOLD_BYTES");
    if (raw == NULL || raw[0] == '\0') {
        return SYNCFS_DIRTY_THRESHOLD_BYTES;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(raw, &end, 10);
    if (errno != 0 || end == raw || *end != '\0') {
        return SYNCFS_DIRTY_THRESHOLD_BYTES;
    }
    return (uint64_t)parsed;
}

static const char *configured_syncfs_path(void) {
    const char *path = getenv("CONJET_RECLAIM_SYNCFS_PATH");
    if (path == NULL) {
        return "/var/lib/docker";
    }
    if (path[0] == '\0' || strcmp(path, "none") == 0 || strcmp(path, "-") == 0) {
        return NULL;
    }
    return path;
}

static bool should_run_syncfs(const struct memcg_stat *stat) {
    const char *path = configured_syncfs_path();
    return path != NULL && dirty_writeback_bytes(stat) >= configured_syncfs_threshold();
}

static int run_syncfs_path(const char *path) {
    if (path == NULL) {
        return 0;
    }
#ifdef __linux__
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
    if (fd < 0) {
        return errno;
    }
    int rc = (int)syscall(SYS_syncfs, fd);
    int saved = rc == 0 ? 0 : (errno == 0 ? EIO : errno);
    if (close(fd) != 0 && saved == 0) {
        saved = errno;
    }
    return saved;
#else
    (void)path;
    return ENOSYS;
#endif
}

static bool string_value_is_disabled(const char *raw) {
    return raw != NULL
        && (strcmp(raw, "0") == 0
            || strcmp(raw, "false") == 0
            || strcmp(raw, "no") == 0
            || strcmp(raw, "none") == 0
            || strcmp(raw, "-") == 0);
}

static bool string_value_is_enabled(const char *raw) {
    return raw != NULL
        && (strcmp(raw, "1") == 0
            || strcmp(raw, "true") == 0
            || strcmp(raw, "yes") == 0
            || strcmp(raw, "on") == 0);
}

static bool configured_drop_caches_enabled(void) {
    const char *raw = getenv("CONJET_RECLAIM_DROP_CACHES");
    if (raw == NULL || raw[0] == '\0') {
        return false;
    }
    return string_value_is_enabled(raw) && !string_value_is_disabled(raw);
}

static const char *configured_drop_caches_path(void) {
    const char *path = getenv("CONJET_RECLAIM_DROP_CACHES_PATH");
    if (path == NULL || path[0] == '\0') {
        return "/proc/sys/vm/drop_caches";
    }
    return path;
}

static int run_drop_caches_path(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return EINVAL;
    }
    sync();
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        return errno;
    }
    const char request[] = "3\n";
    ssize_t written = write(fd, request, sizeof(request) - 1);
    int saved = written == (ssize_t)(sizeof(request) - 1) ? 0 : (errno == 0 ? EIO : errno);
    if (close(fd) != 0 && saved == 0) {
        saved = errno;
    }
    return saved;
}

static void write_status_file(const struct reclaim_summary *summary) {
    mkdir("/run/conjet", 0755);
    const char *path = getenv("CONJET_RECLAIM_STATUS_PATH");
    if (path == NULL || path[0] == '\0') {
        path = "/run/conjet/memory-reclaim.status";
    }
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) {
        return;
    }
    fprintf(f,
        "{\"epoch\":%llu,\"state\":\"%s\","
        "\"requested_bytes\":%llu,\"observed_current_drop_bytes\":%llu,"
        "\"before_current\":%llu,\"after_current\":%llu,"
        "\"before_inactive_file\":%llu,\"after_inactive_file\":%llu,"
        "\"before_slab_reclaimable\":%llu,\"after_slab_reclaimable\":%llu,"
        "\"before_file_dirty\":%llu,\"after_file_dirty\":%llu,"
        "\"before_file_writeback\":%llu,\"after_file_writeback\":%llu,"
        "\"chunks\":%u,\"eagain_count\":%u,"
        "\"syncfs_attempted\":%s,\"syncfs_error_number\":%d,"
        "\"drop_caches_attempted\":%s,\"drop_caches_error_number\":%d,"
        "\"error_number\":%d,"
        "\"scope\":\"%s\",\"service_key\":\"%s\",\"cgroup_path\":\"%s\","
        "\"source\":\"conjet-reclaimd\"}\n",
        (unsigned long long)summary->epoch,
        summary->state,
        (unsigned long long)summary->requested_bytes,
        (unsigned long long)summary->observed_current_drop_bytes,
        (unsigned long long)summary->before_current,
        (unsigned long long)summary->after_current,
        (unsigned long long)summary->before_inactive_file,
        (unsigned long long)summary->after_inactive_file,
        (unsigned long long)summary->before_slab_reclaimable,
        (unsigned long long)summary->after_slab_reclaimable,
        (unsigned long long)summary->before_file_dirty,
        (unsigned long long)summary->after_file_dirty,
        (unsigned long long)summary->before_file_writeback,
        (unsigned long long)summary->after_file_writeback,
        summary->chunks,
        summary->eagain_count,
        summary->syncfs_attempted ? "true" : "false",
        summary->syncfs_error_number,
        summary->drop_caches_attempted ? "true" : "false",
        summary->drop_caches_error_number,
        summary->error_number,
        summary->scope != NULL ? summary->scope : "global",
        summary->service_key != NULL ? summary->service_key : "",
        summary->cgroup_path != NULL ? summary->cgroup_path : "");
    fclose(f);
    rename(tmp, path);
}

static uint64_t parse_epoch(int argc, char **argv) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--epoch") == 0) {
            return strtoull(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

static void parse_reclaim_config(int argc, char **argv, struct reclaim_config *config) {
    memset(config, 0, sizeof(*config));
    config->epoch = parse_epoch(argc, argv);
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--service-key") == 0) {
            snprintf(config->service_key, sizeof(config->service_key), "%s", argv[i + 1]);
            config->service_scoped = true;
        } else if (strcmp(argv[i], "--cgroup") == 0) {
            snprintf(config->cgroup_path, sizeof(config->cgroup_path), "%s", argv[i + 1]);
            config->service_scoped = true;
        } else if (strcmp(argv[i], "--bytes") == 0) {
            config->bytes = strtoull(argv[i + 1], NULL, 10);
            config->service_scoped = true;
        }
    }
}

static bool scoped_reclaim_config_is_valid(const struct reclaim_config *config) {
    return !config->service_scoped ||
        (config->bytes > 0 &&
         config->service_key[0] != '\0' &&
         config->cgroup_path[0] != '\0' &&
         strncmp(config->cgroup_path, "/sys/fs/cgroup/", strlen("/sys/fs/cgroup/")) == 0);
}

int main(int argc, char **argv) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    setpriority(PRIO_PROCESS, 0, 19);
    struct reclaim_config config;
    parse_reclaim_config(argc, argv, &config);
    if (!scoped_reclaim_config_is_valid(&config)) {
        struct reclaim_summary summary;
        memset(&summary, 0, sizeof(summary));
        summary.epoch = config.epoch;
        summary.state = "error";
        summary.scope = config.service_scoped ? "service" : "global";
        summary.service_key = config.service_key;
        summary.cgroup_path = config.cgroup_path;
        summary.error_number = EINVAL;
        write_status_file(&summary);
        return 1;
    }

    const char *build_cgroup = getenv("CONJET_RECLAIM_BUILD_CGROUP");
    const char *daemon_cgroup = getenv("CONJET_RECLAIM_DAEMON_CGROUP");
    const char *service_cgroup = getenv("CONJET_RECLAIM_SERVICE_CGROUP");
    if (build_cgroup == NULL || build_cgroup[0] == '\0') {
        build_cgroup = DEFAULT_BUILD_CGROUP_PATH;
    }
    if (daemon_cgroup == NULL || daemon_cgroup[0] == '\0') {
        daemon_cgroup = "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice";
    }
    if (service_cgroup == NULL || service_cgroup[0] == '\0') {
        service_cgroup = getenv("CONJET_SERVICE_CGROUP");
    }
    if (service_cgroup == NULL || service_cgroup[0] == '\0') {
        service_cgroup = "/sys/fs/cgroup/conjet.slice/conjet-services.slice";
    }
    struct reclaim_summary summary;
    memset(&summary, 0, sizeof(summary));
    summary.epoch = config.epoch;
    summary.state = "running";
    summary.scope = config.service_scoped ? "service" : "global";
    summary.service_key = config.service_scoped ? config.service_key : "";
    summary.cgroup_path = config.service_scoped ? config.cgroup_path : "";

    struct memcg_stat before;
    int rc = config.service_scoped
        ? aggregate_cgroup_with_prefixed_siblings_stat(config.cgroup_path, &before)
        : aggregate_reclaim_targets_stat(build_cgroup, daemon_cgroup, service_cgroup, &before);
    if (rc != 0) {
        summary.error_number = rc;
        summary.state = "error";
        write_status_file(&summary);
        return 1;
    }
    set_summary_before_stat(&summary, &before);
    write_status_file(&summary);

    rc = config.service_scoped
        ? reclaim_cgroup_with_prefixed_siblings_budget(config.cgroup_path, config.bytes, &summary)
        : reclaim_all_targets(build_cgroup, daemon_cgroup, service_cgroup, &summary);

    struct memcg_stat after;
    int stat_rc = config.service_scoped
        ? aggregate_cgroup_with_prefixed_siblings_stat(config.cgroup_path, &after)
        : aggregate_reclaim_targets_stat(build_cgroup, daemon_cgroup, service_cgroup, &after);
    if (stat_rc == 0) {
        set_summary_after_stat(&summary, &after);
    } else if (rc == 0) {
        rc = stat_rc;
    }
    write_status_file(&summary);

    if (rc == 0 && stat_rc == 0 && should_run_syncfs(&after)) {
        const char *syncfs_path = configured_syncfs_path();
        summary.syncfs_attempted = true;
        summary.state = "writeback";
        write_status_file(&summary);

        int sync_rc = run_syncfs_path(syncfs_path);
        summary.syncfs_error_number = sync_rc;
        if (sync_rc == 0) {
            if (stop_requested) {
                rc = ECANCELED;
            } else {
                summary.state = "running";
                write_status_file(&summary);
                rc = config.service_scoped
                    ? reclaim_cgroup_with_prefixed_siblings_budget(config.cgroup_path, config.bytes, &summary)
                    : reclaim_all_targets(build_cgroup, daemon_cgroup, service_cgroup, &summary);
            }
        }
    }

    stat_rc = config.service_scoped
        ? aggregate_cgroup_with_prefixed_siblings_stat(config.cgroup_path, &after)
        : aggregate_reclaim_targets_stat(build_cgroup, daemon_cgroup, service_cgroup, &after);
    if (stat_rc == 0) {
        set_summary_after_stat(&summary, &after);
    } else if (rc == 0) {
        rc = stat_rc;
    }
    if (rc == 0 && !stop_requested && configured_drop_caches_enabled()) {
        summary.drop_caches_attempted = true;
        summary.state = "drop_caches";
        write_status_file(&summary);
        summary.drop_caches_error_number =
            run_drop_caches_path(configured_drop_caches_path());
    }
    summary.error_number = rc;
    summary.state = rc == 0 ? "done" : (rc == ECANCELED ? "cancelled" : "error");
    write_status_file(&summary);
    return rc == 0 ? 0 : 1;
}
