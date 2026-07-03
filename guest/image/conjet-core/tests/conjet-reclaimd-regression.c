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

static void test_drop_caches_gate_defaults_on_and_accepts_disable_values(void) {
    unsetenv("CONJET_RECLAIM_DROP_CACHES");
    require_true("drop caches defaults enabled", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "", 1);
    require_true("empty drop caches setting stays enabled", configured_drop_caches_enabled());

    setenv("CONJET_RECLAIM_DROP_CACHES", "1", 1);
    require_true("explicit enabled drop caches setting", configured_drop_caches_enabled());

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

int main(void) {
    test_reclaim_target_stats_include_prefixed_build_and_service_siblings();
    test_syncfs_gate_uses_dirty_writeback_threshold_and_path();
    test_drop_caches_gate_defaults_on_and_accepts_disable_values();
    puts("conjet-reclaimd regression tests passed");
    return 0;
}
