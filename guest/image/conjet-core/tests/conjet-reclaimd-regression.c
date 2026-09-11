#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main conjet_reclaimd_test_main
#include "../src/conjet-reclaimd.c"
#undef main

static void require_int(const char *name, int actual, int expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
        exit(1);
    }
}

static void require_u64(const char *name, uint64_t actual, uint64_t expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %llu, got %llu\n",
                name,
                (unsigned long long)expected,
                (unsigned long long)actual);
        exit(1);
    }
}

static void require_string(const char *name, const char *actual, const char *expected) {
    if (strcmp(actual, expected) != 0) {
        fprintf(stderr, "%s: expected %s, got %s\n", name, expected, actual);
        exit(1);
    }
}

static void require_true(const char *name, bool value) {
    if (!value) {
        fprintf(stderr, "%s: expected true\n", name);
        exit(1);
    }
}

static void require_false(const char *name, bool value) {
    if (value) {
        fprintf(stderr, "%s: expected false\n", name);
        exit(1);
    }
}

static void test_join_path(char *out, size_t out_len, const char *lhs, const char *rhs) {
    int written = snprintf(out, out_len, "%s/%s", lhs, rhs);
    if (written <= 0 || (size_t)written >= out_len) {
        fprintf(stderr, "path too long for %s/%s\n", lhs, rhs);
        exit(1);
    }
}

static void test_make_dir(const char *path) {
    if (mkdir(path, 0755) != 0) {
        fprintf(stderr, "mkdir(%s): %s\n", path, strerror(errno));
        exit(1);
    }
}

static void test_write_file(const char *dir, const char *name, const char *body) {
    char path[4096];
    test_join_path(path, sizeof(path), dir, name);
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "fopen(%s): %s\n", path, strerror(errno));
        exit(1);
    }
    if (fputs(body, f) == EOF || fclose(f) != 0) {
        fprintf(stderr, "write(%s): %s\n", path, strerror(errno));
        exit(1);
    }
}

static void write_memcg_files(const char *dir,
                              uint64_t current,
                              uint64_t inactive_file,
                              uint64_t slab_reclaimable,
                              uint64_t file_dirty,
                              uint64_t file_writeback) {
    char body[512];
    snprintf(body, sizeof(body), "%llu\n", (unsigned long long)current);
    test_write_file(dir, "memory.current", body);
    snprintf(body,
             sizeof(body),
             "anon 0\ninactive_file %llu\nslab_reclaimable %llu\n"
             "file_dirty %llu\nfile_writeback %llu\n",
             (unsigned long long)inactive_file,
             (unsigned long long)slab_reclaimable,
             (unsigned long long)file_dirty,
             (unsigned long long)file_writeback);
    test_write_file(dir, "memory.stat", body);
}

static void write_cgroup_events(const char *dir, bool populated) {
    test_write_file(dir, "cgroup.events", populated ? "populated 1\n" : "populated 0\n");
}

static void make_test_root(char *root, size_t root_len, const char *prefix) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    int written = snprintf(root, root_len, "%s/%s.XXXXXX", tmpdir, prefix);
    if (written <= 0 || (size_t)written >= root_len) {
        fprintf(stderr, "test root path too long for %s\n", tmpdir);
        exit(1);
    }
    if (mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp: %s\n", strerror(errno));
        exit(1);
    }
}

static void test_reclaim_target_stats_include_prefixed_build_and_service_siblings(void) {
    char root[4096];
    make_test_root(root, sizeof(root), "conjet-reclaimd-cgroup");

    char build[4096];
    char sibling[4096];
    char service[4096];
    char service_sibling[4096];
    char unrelated[4096];
    char daemon[4096];
    test_join_path(build, sizeof(build), root, "conjet-build.slice");
    test_join_path(sibling, sizeof(sibling), root, "conjet-build.slice:docker:abc");
    test_join_path(service, sizeof(service), root, "conjet-services.slice");
    test_join_path(service_sibling, sizeof(service_sibling), root, "conjet-services.slice:docker:def");
    test_join_path(unrelated, sizeof(unrelated), root, "other.slice:docker:ignored");
    test_join_path(daemon, sizeof(daemon), root, "conjet-daemons.slice");
    test_make_dir(build);
    test_make_dir(sibling);
    test_make_dir(service);
    test_make_dir(service_sibling);
    test_make_dir(unrelated);
    test_make_dir(daemon);

    write_memcg_files(build, 10, 20, 30, 40, 50);
    write_memcg_files(sibling, 100, 200, 300, 400, 500);
    write_memcg_files(service, 1000, 2000, 3000, 4000, 5000);
    write_memcg_files(service_sibling, 2000, 4000, 6000, 8000, 10000);
    write_memcg_files(unrelated, 100000, 200000, 300000, 400000, 500000);
    write_memcg_files(daemon, 10000, 20000, 30000, 40000, 50000);

    struct memcg_stat total;
    int rc = aggregate_reclaim_targets_stat(build, daemon, service, &total);
    require_int("aggregate_reclaim_targets_stat", rc, 0);
    require_u64("memory_current", total.memory_current, 13110);
    require_u64("inactive_file", total.inactive_file, 26220);
    require_u64("slab_reclaimable", total.slab_reclaimable, 39330);
    require_u64("file_dirty", total.file_dirty, 52440);
    require_u64("file_writeback", total.file_writeback, 65550);
}

static void test_default_build_cgroup_path_tracks_daemon_scoped_build_workers(void) {
    require_string(
        "default build cgroup path",
        DEFAULT_BUILD_CGROUP_PATH,
        "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice/conjet-build.slice"
    );
}

static void test_stopped_service_reclaim_releases_hot_cache_reserve(void) {
    char root[4096];
    make_test_root(root, sizeof(root), "conjet-reclaimd-service-stop");

    char service[4096];
    test_join_path(service, sizeof(service), root, "conjet-services.slice");
    test_make_dir(service);

    struct memcg_stat stat;
    memset(&stat, 0, sizeof(stat));
    stat.inactive_file = SERVICE_RESERVE_BYTES + 16ULL * 1024ULL * 1024ULL;

    write_cgroup_events(service, true);
    require_u64(
        "running service reserve",
        service_reclaim_reserve(service),
        SERVICE_RESERVE_BYTES
    );
    require_u64(
        "running service keeps cache reserve",
        reclaim_candidate(&stat, SERVICE_CAP_BYTES, service_reclaim_reserve(service)),
        16ULL * 1024ULL * 1024ULL
    );

    write_cgroup_events(service, false);
    require_u64("stopped service reserve", service_reclaim_reserve(service), 0);
    require_u64(
        "stopped service releases cache reserve",
        reclaim_candidate(&stat, SERVICE_CAP_BYTES, service_reclaim_reserve(service)),
        stat.inactive_file
    );
}

static void test_idle_daemon_reclaim_uses_small_cache_floor(void) {
    char root[4096];
    make_test_root(root, sizeof(root), "conjet-reclaimd-daemon-idle");

    char build[4096];
    char service[4096];
    test_join_path(build, sizeof(build), root, "conjet-build.slice");
    test_join_path(service, sizeof(service), root, "conjet-services.slice");
    test_make_dir(build);
    test_make_dir(service);

    struct memcg_stat stat;
    memset(&stat, 0, sizeof(stat));
    stat.inactive_file = DAEMON_RESERVE_BYTES + 16ULL * 1024ULL * 1024ULL;

    write_cgroup_events(build, true);
    write_cgroup_events(service, false);
    require_false("active build is not idle daemon reclaim", daemon_idle_reclaim_allowed(build, service));
    require_u64(
        "active build keeps daemon reserve",
        daemon_reclaim_reserve(build, service),
        DAEMON_RESERVE_BYTES
    );

    write_cgroup_events(build, false);
    require_true("empty build and service allow idle daemon reclaim", daemon_idle_reclaim_allowed(build, service));
    require_u64(
        "idle daemon reserve",
        daemon_reclaim_reserve(build, service),
        DAEMON_IDLE_RESERVE_BYTES
    );
    require_u64(
        "idle daemon releases old cache reserve",
        reclaim_candidate(&stat, DAEMON_CAP_BYTES, daemon_reclaim_reserve(build, service)),
        stat.inactive_file - DAEMON_IDLE_RESERVE_BYTES
    );

    char build_events[4096];
    test_join_path(build_events, sizeof(build_events), build, "cgroup.events");
    if (unlink(build_events) != 0 || rmdir(build) != 0) {
        fprintf(stderr, "failed to remove idle build cgroup: %s\n", strerror(errno));
        exit(1);
    }
    require_u64(
        "absent idle build cgroup stays idle",
        daemon_reclaim_reserve(build, service),
        DAEMON_IDLE_RESERVE_BYTES
    );
    require_true("absent build keeps idle daemon reclaim", daemon_idle_reclaim_allowed(build, service));
}

static void test_syncfs_gate_uses_dirty_writeback_threshold_and_path(void) {
    struct memcg_stat stat;
    memset(&stat, 0, sizeof(stat));
    stat.file_dirty = SYNCFS_DIRTY_THRESHOLD_BYTES - 1;
    unsetenv("CONJET_RECLAIM_SYNCFS_PATH");
    unsetenv("CONJET_RECLAIM_SYNCFS_DIRTY_THRESHOLD_BYTES");
    require_false("below default syncfs threshold", should_run_syncfs(&stat));

    stat.file_writeback = 1;
    require_true("at default syncfs threshold", should_run_syncfs(&stat));

    setenv("CONJET_RECLAIM_SYNCFS_PATH", "none", 1);
    require_false("disabled syncfs path", should_run_syncfs(&stat));

    setenv("CONJET_RECLAIM_SYNCFS_PATH", "/var/lib/docker", 1);
    setenv("CONJET_RECLAIM_SYNCFS_DIRTY_THRESHOLD_BYTES", "512", 1);
    stat.file_dirty = 511;
    stat.file_writeback = 0;
    require_false("below configured syncfs threshold", should_run_syncfs(&stat));
    stat.file_writeback = 1;
    require_true("at configured syncfs threshold", should_run_syncfs(&stat));
}

static void test_drop_caches_gate_defaults_off_and_accepts_enable_values(void) {
    unsetenv("CONJET_RECLAIM_DROP_CACHES");
    require_false("drop caches defaults disabled", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "", 1);
    require_false("empty drop caches setting stays disabled", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "1", 1);
    require_true("explicit enabled drop caches setting", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "true", 1);
    require_true("true enables drop caches setting", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "yes", 1);
    require_true("yes enables drop caches setting", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "on", 1);
    require_true("on enables drop caches setting", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "0", 1);
    require_false("zero disables drop caches", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "false", 1);
    require_false("false disables drop caches", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "no", 1);
    require_false("no disables drop caches", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "none", 1);
    require_false("none disables drop caches", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "-", 1);
    require_false("dash disables drop caches", configured_drop_caches_enabled());
}

static void test_scoped_reclaim_config_requires_service_path_and_bytes(void) {
    char *valid[] = {
        "conjet-reclaimd",
        "--epoch", "7",
        "--service-key", "chum_mem_worker",
        "--cgroup", "/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_worker.slice",
        "--bytes", "67108864",
        NULL
    };
    struct reclaim_config config;
    parse_reclaim_config(9, valid, &config);
    require_true("valid scoped reclaim config", scoped_reclaim_config_is_valid(&config));
    require_true("valid scoped reclaim is scoped", config.service_scoped);
    require_u64("valid scoped reclaim bytes", config.bytes, 67108864);

    char *missing_bytes[] = {
        "conjet-reclaimd",
        "--epoch", "7",
        "--service-key", "chum_mem_worker",
        "--cgroup", "/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_worker.slice",
        NULL
    };
    parse_reclaim_config(7, missing_bytes, &config);
    require_false("scoped reclaim rejects missing bytes", scoped_reclaim_config_is_valid(&config));

    char *outside_cgroup[] = {
        "conjet-reclaimd",
        "--epoch", "7",
        "--service-key", "chum_mem_worker",
        "--cgroup", "/tmp/conjet-service-chum_mem_worker.slice",
        "--bytes", "67108864",
        NULL
    };
    parse_reclaim_config(9, outside_cgroup, &config);
    require_false("scoped reclaim rejects non-cgroup path", scoped_reclaim_config_is_valid(&config));
}

static void test_generic_reclaim_skips_live_scopes_and_shares_budget(void) {
    char root[4096], service[4096], sibling[4096];
    make_test_root(root, sizeof(root), "conjet-reclaimd-guard");
    test_join_path(service, sizeof(service), root, "services");
    test_join_path(sibling, sizeof(sibling), root, "services:docker:one");
    test_make_dir(service);
    test_make_dir(sibling);
    const uint64_t mib = 1024 * 1024;
    write_memcg_files(service, 256 * mib, 256 * mib, 0, 0, 0);
    write_memcg_files(sibling, 256 * mib, 256 * mib, 0, 0, 0);
    test_write_file(service, "memory.reclaim", "");
    test_write_file(sibling, "memory.reclaim", "");
    write_cgroup_events(service, true);
    write_cgroup_events(sibling, true);
    struct reclaim_summary summary = {0};
    require_int("populated generic reclaim", reclaim_cgroup_with_prefixed_siblings(service, 64 * mib, 0, &summary), 0);
    require_u64("live scopes preserved", summary.requested_bytes, 0);
    require_false("populated sibling blocks daemon idle", cgroup_and_siblings_empty(service));

    write_cgroup_events(service, false);
    require_false("empty parent does not hide populated sibling", cgroup_and_siblings_empty(service));
    write_cgroup_events(sibling, false);
    require_true("all scopes empty", cgroup_and_siblings_empty(service));
    require_int("bounded empty reclaim", reclaim_cgroup_with_prefixed_siblings(service, 64 * mib, 0, &summary), 0);
    require_u64("one budget across siblings", summary.requested_bytes, 64 * mib);
    require_u64("one reclaim chunk", summary.chunks, 1);

    test_write_file(service, "cgroup.events", "invalid\n");
    summary = (struct reclaim_summary){0};
    require_int("unknown population", reclaim_one_cgroup_guarded(service, 64 * mib, 0, true, &summary), 0);
    require_u64("unknown population preserves cache", summary.requested_bytes, 0);
}

int main(void) {
    test_generic_reclaim_skips_live_scopes_and_shares_budget();
    test_reclaim_target_stats_include_prefixed_build_and_service_siblings();
    test_default_build_cgroup_path_tracks_daemon_scoped_build_workers();
    test_stopped_service_reclaim_releases_hot_cache_reserve();
    test_idle_daemon_reclaim_uses_small_cache_floor();
    test_syncfs_gate_uses_dirty_writeback_threshold_and_path();
    test_drop_caches_gate_defaults_off_and_accepts_enable_values();
    test_scoped_reclaim_config_requires_service_path_and_bytes();
    puts("conjet-reclaimd regression tests passed");
    return 0;
}
