#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main conjet_memd_test_main
#include "../src/conjet-memd.c"
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

static void require_contains(const char *name, const char *haystack, const char *needle) {
    if (strstr(haystack, needle) == NULL) {
        fprintf(stderr, "%s: expected JSON to contain %s\n", name, needle);
        exit(1);
    }
}

static void require_string(const char *name, const char *actual, const char *expected) {
    if (strcmp(actual, expected) != 0) {
        fprintf(stderr, "%s: expected %s, got %s\n", name, expected, actual);
        exit(1);
    }
}

static void write_file(const char *dir, const char *name, const char *body) {
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/%s", dir, name);
    if (written <= 0 || (size_t)written >= sizeof(path)) {
        fprintf(stderr, "path too long for %s/%s\n", dir, name);
        exit(1);
    }
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

static void make_dir(const char *path) {
    if (mkdir(path, 0755) != 0) {
        fprintf(stderr, "mkdir(%s): %s\n", path, strerror(errno));
        exit(1);
    }
}

static void join_path(char *out, size_t out_len, const char *lhs, const char *rhs) {
    int written = snprintf(out, out_len, "%s/%s", lhs, rhs);
    if (written <= 0 || (size_t)written >= out_len) {
        fprintf(stderr, "path too long for %s/%s\n", lhs, rhs);
        exit(1);
    }
}

static void test_build_snapshot_aggregates_prefixed_sibling_memory_without_false_activity(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-cgroup.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root)) {
        fprintf(stderr, "test root path too long for %s\n", tmpdir);
        exit(1);
    }
    if (mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp: %s\n", strerror(errno));
        exit(1);
    }

    char base[4096];
    char sibling[4096];
    char unrelated[4096];
    join_path(base, sizeof(base), root, "conjet-build.slice");
    join_path(sibling, sizeof(sibling), root, "conjet-build.slice:docker:abc");
    join_path(unrelated, sizeof(unrelated), root, "conjet-services.slice:docker:def");
    make_dir(base);
    make_dir(sibling);
    make_dir(unrelated);

    write_file(base, "memory.current", "4096\n");
    write_file(base, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(sibling, "memory.current", "8192\n");
    write_file(sibling, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(unrelated, "memory.current", "1048576\n");
    write_file(unrelated, "cgroup.events", "populated 1\nfrozen 0\n");

    struct build_cgroup_snapshot snapshot = read_build_cgroup_snapshot(base);
    require_u64("inactive build memory", snapshot.memory_current, 12288);
    require_int("inactive build populated", snapshot.populated, 0);

    write_file(sibling, "cgroup.events", "populated 1\nfrozen 0\n");
    snapshot = read_build_cgroup_snapshot(base);
    require_u64("active build memory", snapshot.memory_current, 12288);
    require_int("active build populated", snapshot.populated, 1);
}

static void test_service_cgroup_memory_stat_is_exported(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-service-stat.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root)) {
        fprintf(stderr, "test root path too long for %s\n", tmpdir);
        exit(1);
    }
    if (mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp: %s\n", strerror(errno));
        exit(1);
    }

    char build[4096];
    char daemon[4096];
    char service[4096];
    join_path(build, sizeof(build), root, "conjet-build.slice");
    join_path(daemon, sizeof(daemon), root, "conjet-daemons.slice");
    join_path(service, sizeof(service), root, "conjet-services.slice");
    make_dir(build);
    make_dir(daemon);
    make_dir(service);

    write_file(build, "memory.current", "0\n");
    write_file(build, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(daemon, "memory.current", "222\n");
    write_file(service, "memory.current", "4096\n");
    write_file(
        service,
        "memory.stat",
        "anon 111\nfile 222\ninactive_file 333\nactive_file 444\n"
        "slab 555\nslab_reclaimable 66\nslab_unreclaimable 77\n"
    );

    setenv("CONJET_RECLAIM_BUILD_CGROUP", build, 1);
    setenv("CONJET_RECLAIM_DAEMON_CGROUP", daemon, 1);
    setenv("CONJET_SERVICE_CGROUP", service, 1);

    struct memory_metrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    read_configured_cgroup_metrics(&metrics);
    require_u64("daemon current", metrics.daemon_cgroup_memory_current, 222);
    require_u64("service current", metrics.service_cgroup_memory_current, 4096);
    require_u64("service anon", metrics.service_cgroup_anon, 111);
    require_u64("service file", metrics.service_cgroup_file, 222);
    require_u64("service inactive_file", metrics.service_cgroup_inactive_file, 333);
    require_u64("service active_file", metrics.service_cgroup_active_file, 444);
    require_u64("service slab", metrics.service_cgroup_slab, 555);
    require_u64("service slab reclaimable", metrics.service_cgroup_slab_reclaimable, 66);
    require_u64("service slab unreclaimable", metrics.service_cgroup_slab_unreclaimable, 77);

    char body[4096];
    metrics_json(&metrics, body, sizeof(body));
    require_contains("service inactive file JSON", body, "\"service_cgroup_inactive_file\":333");
    require_contains("service file JSON", body, "\"service_cgroup_file\":222");
    require_contains("service anon JSON", body, "\"service_cgroup_anon\":111");
    require_contains("service slab JSON", body, "\"service_cgroup_slab\":555");

    unsetenv("CONJET_RECLAIM_BUILD_CGROUP");
    unsetenv("CONJET_RECLAIM_DAEMON_CGROUP");
    unsetenv("CONJET_SERVICE_CGROUP");
}

static void test_service_slice_scanner_aggregates_working_set_by_service_key(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-service-slices.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root)) {
        fprintf(stderr, "test root path too long for %s\n", tmpdir);
        exit(1);
    }
    if (mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp: %s\n", strerror(errno));
        exit(1);
    }

    char services[4096];
    char worker[4096];
    char worker_child[4096];
    char unrelated[4096];
    join_path(services, sizeof(services), root, "conjet-services.slice");
    join_path(worker, sizeof(worker), services, "conjet-service-chum_mem_worker.slice");
    join_path(worker_child, sizeof(worker_child), services, "conjet-service-chum_mem_worker.slice:docker:abc");
    join_path(unrelated, sizeof(unrelated), services, "docker-ignored.scope");
    make_dir(services);
    make_dir(worker);
    make_dir(worker_child);
    make_dir(unrelated);

    write_file(worker, "memory.current", "4096\n");
    write_file(worker, "cgroup.events", "populated 1\nfrozen 0\n");
    write_file(
        worker,
        "memory.stat",
        "anon 2048\nfile 1536\ninactive_file 1024\nactive_file 512\n"
        "slab_reclaimable 256\nslab_unreclaimable 128\n"
    );
    write_file(worker_child, "memory.current", "8192\n");
    write_file(worker_child, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(
        worker_child,
        "memory.stat",
        "anon 4096\nfile 3072\ninactive_file 512\nactive_file 2560\n"
        "slab_reclaimable 128\nslab_unreclaimable 64\n"
    );
    write_file(unrelated, "memory.current", "1048576\n");
    write_file(unrelated, "cgroup.events", "populated 1\nfrozen 0\n");

    struct service_slice_set set;
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(root, 0, &set);

    require_u64("service slice count", (uint64_t)set.count, 1);
    require_string("service slice key", set.slices[0].key, "chum_mem_worker");
    require_u64("service slice current", set.slices[0].memory_current, 12288);
    require_u64("service slice anon", set.slices[0].anon, 6144);
    require_u64("service slice inactive_file", set.slices[0].inactive_file, 1536);
    require_u64("service slice slab reclaimable", set.slices[0].slab_reclaimable, 384);
    require_int("service slice populated", set.slices[0].populated ? 1 : 0, 1);
    require_u64("service slice reclaimable", service_slice_reclaimable(&set.slices[0]), 1920);
    require_u64("service slice working set", service_slice_working_set(&set.slices[0]), 10368);

    char body[8192];
    service_slices_json(&set, body, sizeof(body));
    require_contains("service slice key JSON", body, "\"key\":\"chum_mem_worker\"");
    require_contains("service slice current JSON", body, "\"memory_current\":12288");
    require_contains("service slice working set JSON", body, "\"working_set\":10368");
    require_contains("service slice reclaimable JSON", body, "\"reclaimable\":1920");
}

static void test_service_reclaim_request_validation_matches_slice_key(void) {
    struct reclaim_request request;
    memset(&request, 0, sizeof(request));
    request.service_scoped = true;
    request.bytes = 67108864;
    snprintf(request.service_key, sizeof(request.service_key), "chum_mem_worker");
    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice/conjet-service-chum_mem_worker.slice"
    );
    require_int("valid service reclaim request", service_reclaim_request_is_valid(&request) ? 1 : 0, 1);

    snprintf(request.service_key, sizeof(request.service_key), "chum_mem_api");
    require_int("reject mismatched service key", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);

    snprintf(request.service_key, sizeof(request.service_key), "chum_mem_worker");
    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/tmp/conjet-service-chum_mem_worker.slice"
    );
    require_int("reject service path outside cgroup fs", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);

    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/../conjet-service-chum_mem_worker.slice"
    );
    require_int("reject service path traversal", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);
}

int main(void) {
    test_build_snapshot_aggregates_prefixed_sibling_memory_without_false_activity();
    test_service_cgroup_memory_stat_is_exported();
    test_service_slice_scanner_aggregates_working_set_by_service_key();
    test_service_reclaim_request_validation_matches_slice_key();
    puts("conjet-memd cgroup regression tests passed");
    return 0;
}
