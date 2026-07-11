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

static void require_double_near(const char *name, double actual, double expected) {
    double difference = actual > expected ? actual - expected : expected - actual;
    if (difference > 0.0001) {
        fprintf(stderr, "%s: expected %.4f, got %.4f\n", name, expected, actual);
        exit(1);
    }
}

static void require_contains(const char *name, const char *haystack, const char *needle) {
    if (strstr(haystack, needle) == NULL) {
        fprintf(stderr, "%s: expected JSON to contain %s\n", name, needle);
        exit(1);
    }
}

static void require_not_contains(const char *name, const char *haystack, const char *needle) {
    if (strstr(haystack, needle) != NULL) {
        fprintf(stderr, "%s: expected JSON not to contain %s\n", name, needle);
        exit(1);
    }
}

static void require_ends_with(const char *name, const char *value, const char *suffix) {
    size_t value_len = strlen(value);
    size_t suffix_len = strlen(suffix);
    if (value_len < suffix_len || strcmp(value + value_len - suffix_len, suffix) != 0) {
        fprintf(stderr, "%s: expected value to end with %s\n", name, suffix);
        exit(1);
    }
}

static void test_vsock_peer_requires_host_cid(void) {
    struct sockaddr_vm peer;
    memset(&peer, 0, sizeof(peer));
    peer.svm_family = AF_VSOCK;
    peer.svm_cid = VMADDR_CID_HOST;
    require_int("host vsock peer", is_host_vsock_peer(&peer, sizeof(peer)), 1);

    peer.svm_cid = VMADDR_CID_ANY;
    require_int("non-host vsock peer", is_host_vsock_peer(&peer, sizeof(peer)), 0);
    require_int("short peer address", is_host_vsock_peer(&peer, sizeof(peer) - 1), 0);
}

static void require_string(const char *name, const char *actual, const char *expected) {
    if (strcmp(actual, expected) != 0) {
        fprintf(stderr, "%s: expected %s, got %s\n", name, expected, actual);
        exit(1);
    }
}

static const struct service_slice_stat *find_slice(
    const struct service_slice_set *set,
    const char *key
) {
    for (size_t i = 0; i < set->count; i++) {
        if (strcmp(set->slices[i].key, key) == 0) {
            return &set->slices[i];
        }
    }
    return NULL;
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

static void test_default_build_cgroup_path_tracks_daemon_scoped_build_workers(void) {
    require_string(
        "default build cgroup path",
        DEFAULT_BUILD_CGROUP_PATH,
        "/sys/fs/cgroup/conjet.slice/conjet-daemons.slice/conjet-build.slice"
    );
}

static void test_page_size_and_mglru_helpers_are_fail_closed(void) {
    require_u64("page size", read_page_size_bytes(), (uint64_t)sysconf(_SC_PAGESIZE));

    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-mglru.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root) || mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp for mglru helper: %s\n", strerror(errno));
        exit(1);
    }
    char enabled[4096];
    join_path(enabled, sizeof(enabled), root, "enabled");
    write_file(root, "enabled", "0x0007\n");
    require_int("main mglru bit", read_mglru_enabled_path(enabled), 1);
    write_file(root, "enabled", "0x0006\n");
    require_int("mglru features without main bit", read_mglru_enabled_path(enabled), 0);
    write_file(root, "enabled", "0\n");
    require_int("zero mglru mask", read_mglru_enabled_path(enabled), 0);
    write_file(root, "enabled", "-1\n");
    require_int("signed mglru mask", read_mglru_enabled_path(enabled), 0);
    write_file(root, "enabled", "184467440737095516160\n");
    require_int("overflow mglru mask", read_mglru_enabled_path(enabled), 0);
    write_file(root, "enabled", "not-a-number\n");
    require_int("malformed mglru mask", read_mglru_enabled_path(enabled), 0);
    write_file(root, "enabled", "0x0001\ntrailing-data\n");
    require_int("trailing mglru data", read_mglru_enabled_path(enabled), 0);
    join_path(enabled, sizeof(enabled), root, "missing");
    require_int("missing mglru mask", read_mglru_enabled_path(enabled), 0);

    char capabilities[512];
    capabilities_json(true, capabilities, sizeof(capabilities));
    require_contains("capabilities version", capabilities, "\"version\":5");
    require_contains("service feedback capability", capabilities, "\"service_feedback\":true");
    require_contains("mglru enabled capability", capabilities, "\"mglru_enabled\":true");
}

static void test_global_memory_sources_distinguish_valid_zero_from_invalid(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-global-sources.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root) || mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp for global sources: %s\n", strerror(errno));
        exit(1);
    }
    char meminfo[4096];
    char pressure[4096];
    char swaps[4096];
    char missing[4096];
    join_path(meminfo, sizeof(meminfo), root, "meminfo");
    join_path(pressure, sizeof(pressure), root, "memory.pressure");
    join_path(swaps, sizeof(swaps), root, "swaps");
    join_path(missing, sizeof(missing), root, "missing");

    write_file(
        root,
        "meminfo",
        "MemTotal: 4096 kB\nMemAvailable: 0 kB\nMemFree: 0 kB\n"
        "Buffers: 0 kB\nCached: 0 kB\nSReclaimable: 0 kB\n"
        "SwapTotal: 0 kB\nSwapFree: 0 kB\n"
    );
    write_file(
        root,
        "memory.pressure",
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
        "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    );
    write_file(root, "swaps", "Filename Type Size Used Priority\n");

    struct memory_metrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    read_meminfo_path(meminfo, &metrics);
    read_psi_path(pressure, &metrics);
    read_swaps_path(swaps, &metrics);
    require_int("zero MemAvailable is known", metrics.mem_available_known ? 1 : 0, 1);
    require_u64("zero MemAvailable value", metrics.mem_available, 0);
    require_int("zero swap is complete", metrics.swap_telemetry_complete ? 1 : 0, 1);
    require_u64("zero total swap", metrics.swap_total, 0);
    require_u64("zero free swap", metrics.swap_free, 0);
    require_int("zero PSI is complete", metrics.global_psi_telemetry_complete ? 1 : 0, 1);
    require_double_near("zero PSI some", metrics.psi_some_avg10, 0.0);
    require_double_near("zero PSI full", metrics.psi_full_avg10, 0.0);
    require_int(
        "header-only disk swap is complete",
        metrics.disk_swap_telemetry_complete ? 1 : 0,
        1
    );
    require_u64("zero disk swap total", metrics.disk_swap_total, 0);
    require_u64("zero disk swap free", metrics.disk_swap_free, 0);

    char body[METRICS_JSON_CAPACITY];
    metrics_json(&metrics, body, sizeof(body));
    require_contains("MemAvailable validity JSON", body, "\"mem_available_known\":true");
    require_contains("swap validity JSON", body, "\"swap_telemetry_complete\":true");
    require_contains(
        "disk swap validity JSON",
        body,
        "\"disk_swap_telemetry_complete\":true"
    );
    require_contains(
        "global PSI validity JSON",
        body,
        "\"global_psi_telemetry_complete\":true"
    );

    write_file(
        root,
        "meminfo",
        "MemAvailable: malformed kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"
    );
    read_meminfo_path(meminfo, &metrics);
    require_int("malformed MemAvailable is unknown", metrics.mem_available_known ? 1 : 0, 0);
    require_int(
        "valid zero swap remains complete",
        metrics.swap_telemetry_complete ? 1 : 0,
        1
    );

    write_file(
        root,
        "meminfo",
        "MemAvailable: 0 kB\nSwapTotal: malformed kB\nSwapFree: 0 kB\n"
    );
    read_meminfo_path(meminfo, &metrics);
    require_int("malformed total swap fails closed", metrics.swap_telemetry_complete ? 1 : 0, 0);

    write_file(
        root,
        "meminfo",
        "MemAvailable: 0 kB\nSwapTotal: 0 kB\nSwapFree: 1 kB\n"
    );
    read_meminfo_path(meminfo, &metrics);
    require_int("valid zero MemAvailable remains known", metrics.mem_available_known ? 1 : 0, 1);
    require_int("impossible swap values fail closed", metrics.swap_telemetry_complete ? 1 : 0, 0);

    metrics.mem_available = 123;
    metrics.swap_total = 456;
    read_meminfo_path(missing, &metrics);
    require_int("unreadable MemAvailable is unknown", metrics.mem_available_known ? 1 : 0, 0);
    require_int("unreadable swap is incomplete", metrics.swap_telemetry_complete ? 1 : 0, 0);
    require_u64("unreadable MemAvailable resets value", metrics.mem_available, 0);
    require_u64("unreadable swap resets value", metrics.swap_total, 0);

    write_file(
        root,
        "memory.pressure",
        "some avg10=not-a-number avg60=0.00 avg300=0.00 total=0\n"
        "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
    );
    read_psi_path(pressure, &metrics);
    require_int("malformed PSI fails closed", metrics.global_psi_telemetry_complete ? 1 : 0, 0);
    metrics.psi_some_avg10 = 1.0;
    read_psi_path(missing, &metrics);
    require_int("unreadable PSI fails closed", metrics.global_psi_telemetry_complete ? 1 : 0, 0);
    require_double_near("unreadable PSI resets value", metrics.psi_some_avg10, 0.0);

    write_file(
        root,
        "swaps",
        "Filename Type Size Used Priority\n"
        "/dev/zram0 partition 1024 512 100\n"
        "/dev/vda partition 2048 512 -2\n"
    );
    read_swaps_path(swaps, &metrics);
    require_int("valid disk swap rows are complete", metrics.disk_swap_telemetry_complete ? 1 : 0, 1);
    require_u64("zram excluded from disk swap total", metrics.disk_swap_total, 2048ULL * 1024ULL);
    require_u64("disk swap free", metrics.disk_swap_free, 1536ULL * 1024ULL);

    write_file(
        root,
        "swaps",
        "Filename Type Size Used Priority\n/dev/vda partition malformed 0 -2\n"
    );
    read_swaps_path(swaps, &metrics);
    require_int("malformed disk swap row fails closed", metrics.disk_swap_telemetry_complete ? 1 : 0, 0);

    write_file(
        root,
        "swaps",
        "Filename Type Size Used Priority\n/dev/vda partition 1 2 -2\n"
    );
    read_swaps_path(swaps, &metrics);
    require_int(
        "inconsistent disk swap row fails closed",
        metrics.disk_swap_telemetry_complete ? 1 : 0,
        0
    );
    metrics.disk_swap_total = 123;
    read_swaps_path(missing, &metrics);
    require_int("unreadable disk swap fails closed", metrics.disk_swap_telemetry_complete ? 1 : 0, 0);
    require_u64("unreadable disk swap resets value", metrics.disk_swap_total, 0);
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
    write_file(daemon, "cgroup.events", "populated 1\nfrozen 0\n");
    write_file(
        daemon,
        "memory.stat",
        "anon 101\ninactive_file 77\nslab_reclaimable 11\n"
    );
    write_file(service, "memory.current", "4096\n");
    write_file(service, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(
        service,
        "memory.stat",
        "anon 111\nfile 222\nshmem 12\nsock 13\nkernel 14\nfile_mapped 15\n"
        "inactive_anon 16\nactive_anon 17\ninactive_file 333\nactive_file 444\n"
        "file_dirty 30\nfile_writeback 20\n"
        "slab 555\nslab_reclaimable 66\nslab_unreclaimable 77\n"
        "workingset_refault_file 101\nworkingset_activate_file 102\n"
        "workingset_restore_file 103\npgfault 104\npgmajfault 105\n"
        "pgscan 106\npgsteal 107\n"
        "pgscan_proactive 108\npgsteal_proactive 109\n"
    );
    write_file(
        service,
        "memory.events",
        "low 10\nhigh 20\nmax 30\noom 40\noom_kill 50\noom_group_kill 60\n"
    );
    write_file(
        service,
        "memory.events.local",
        "low 1\nhigh 2\nmax 3\noom 4\noom_kill 5\noom_group_kill 6\n"
    );
    write_file(
        service,
        "memory.pressure",
        "some avg10=0.25 avg60=0.10 avg300=0.05 total=1234\n"
        "full avg10=0.05 avg60=0.02 avg300=0.01 total=567\n"
    );

    setenv("CONJET_RECLAIM_BUILD_CGROUP", build, 1);
    setenv("CONJET_RECLAIM_DAEMON_CGROUP", daemon, 1);
    setenv("CONJET_SERVICE_CGROUP", service, 1);

    struct memory_metrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    read_configured_cgroup_metrics(&metrics);
    require_u64("daemon current", metrics.daemon_cgroup_memory_current, 222);
    require_u64("daemon working set", metrics.daemon_cgroup_working_set, 134);
    require_u64("daemon anon", metrics.daemon_cgroup_anon, 101);
    require_u64("daemon inactive file", metrics.daemon_cgroup_inactive_file, 77);
    require_u64("daemon slab reclaimable", metrics.daemon_cgroup_slab_reclaimable, 11);
    require_int("daemon populated", metrics.daemon_cgroup_populated, 1);
    require_int("daemon population known", metrics.daemon_cgroup_population_known, 1);
    require_u64("service current", metrics.service_cgroup_memory_current, 4096);
    require_u64("service working set", metrics.service_cgroup_working_set, 3697);
    require_int("service populated", metrics.service_cgroup_populated, 0);
    require_int("service population known", metrics.service_cgroup_population_known, 1);
    require_u64("service anon", metrics.service_cgroup_anon, 111);
    require_u64("service file", metrics.service_cgroup_file, 222);
    require_u64("service shmem", metrics.service_cgroup_shmem, 12);
    require_u64("service sock", metrics.service_cgroup_sock, 13);
    require_u64("service kernel", metrics.service_cgroup_kernel, 14);
    require_u64("service mapped file", metrics.service_cgroup_file_mapped, 15);
    require_u64("service inactive anon", metrics.service_cgroup_inactive_anon, 16);
    require_u64("service active anon", metrics.service_cgroup_active_anon, 17);
    require_u64("service inactive_file", metrics.service_cgroup_inactive_file, 333);
    require_u64("service active_file", metrics.service_cgroup_active_file, 444);
    require_u64("service dirty file", metrics.service_cgroup_file_dirty, 30);
    require_u64("service writeback file", metrics.service_cgroup_file_writeback, 20);
    require_u64("service clean inactive file", metrics.service_cgroup_clean_inactive_file, 283);
    require_u64("service slab", metrics.service_cgroup_slab, 555);
    require_u64("service slab reclaimable", metrics.service_cgroup_slab_reclaimable, 66);
    require_u64("service slab unreclaimable", metrics.service_cgroup_slab_unreclaimable, 77);
    require_u64("service refault file", metrics.service_cgroup_workingset_refault_file, 101);
    require_u64("service activate file", metrics.service_cgroup_workingset_activate_file, 102);
    require_u64("service restore file", metrics.service_cgroup_workingset_restore_file, 103);
    require_u64("service pgfault", metrics.service_cgroup_pgfault, 104);
    require_u64("service pgmajfault", metrics.service_cgroup_pgmajfault, 105);
    require_u64("service pgscan", metrics.service_cgroup_pgscan, 106);
    require_u64("service pgsteal", metrics.service_cgroup_pgsteal, 107);
    require_u64("optional service proactive pgscan", metrics.service_cgroup_pgscan_proactive, 108);
    require_u64("optional service proactive pgsteal", metrics.service_cgroup_pgsteal_proactive, 109);
    require_u64("service hierarchical low", metrics.service_cgroup_memory_events_low, 10);
    require_u64("service hierarchical high", metrics.service_cgroup_memory_events_high, 20);
    require_u64("service hierarchical max", metrics.service_cgroup_memory_events_max, 30);
    require_u64("service hierarchical oom", metrics.service_cgroup_memory_events_oom, 40);
    require_u64("service hierarchical oom kill", metrics.service_cgroup_memory_events_oom_kill, 50);
    require_u64(
        "service hierarchical oom group kill",
        metrics.service_cgroup_memory_events_oom_group_kill,
        60
    );
    require_u64("service local low", metrics.service_cgroup_memory_events_local_low, 1);
    require_u64("service local high", metrics.service_cgroup_memory_events_local_high, 2);
    require_u64("service local max", metrics.service_cgroup_memory_events_local_max, 3);
    require_u64("service local oom", metrics.service_cgroup_memory_events_local_oom, 4);
    require_u64("service local oom kill", metrics.service_cgroup_memory_events_local_oom_kill, 5);
    require_u64(
        "service local oom group kill",
        metrics.service_cgroup_memory_events_local_oom_group_kill,
        6
    );
    require_u64("service PSI some total", metrics.service_cgroup_psi_some_total_us, 1234);
    require_u64("service PSI full total", metrics.service_cgroup_psi_full_total_us, 567);
    struct stat service_stat;
    if (stat(service, &service_stat) != 0) {
        fprintf(stderr, "stat(%s): %s\n", service, strerror(errno));
        exit(1);
    }
    require_u64("service cgroup id", metrics.service_cgroup_cgroup_id, service_stat.st_ino);
    require_int("service telemetry complete", metrics.service_cgroup_telemetry_complete, 1);

    metrics.page_size_bytes = read_page_size_bytes();
    char body[METRICS_JSON_CAPACITY];
    metrics_json(&metrics, body, sizeof(body));
    require_ends_with("complete metrics JSON", body, "}\n");
    require_contains("metrics JSON source", body, "\"source\":\"conjet-memd\"");
    require_contains("page size JSON", body, "\"page_size_bytes\":");
    require_contains("daemon working set JSON", body, "\"daemon_cgroup_working_set\":134");
    require_contains("daemon inactive file JSON", body, "\"daemon_cgroup_inactive_file\":77");
    require_contains("daemon populated JSON", body, "\"daemon_cgroup_populated\":true");
    require_contains("service inactive file JSON", body, "\"service_cgroup_inactive_file\":333");
    require_contains("service file JSON", body, "\"service_cgroup_file\":222");
    require_contains("service anon JSON", body, "\"service_cgroup_anon\":111");
    require_contains("service shmem JSON", body, "\"service_cgroup_shmem\":12");
    require_contains("service sock JSON", body, "\"service_cgroup_sock\":13");
    require_contains("service kernel JSON", body, "\"service_cgroup_kernel\":14");
    require_contains(
        "service clean inactive JSON",
        body,
        "\"service_cgroup_clean_inactive_file\":283"
    );
    require_contains(
        "service refault JSON",
        body,
        "\"service_cgroup_workingset_refault_file\":101"
    );
    require_contains(
        "optional service proactive steal JSON",
        body,
        "\"service_cgroup_pgsteal_proactive\":109"
    );
    require_contains(
        "service hierarchical high event JSON",
        body,
        "\"service_cgroup_memory_events_high\":20"
    );
    require_contains(
        "service PSI some total JSON",
        body,
        "\"service_cgroup_psi_some_total_us\":1234"
    );
    require_contains(
        "service telemetry complete JSON",
        body,
        "\"service_cgroup_telemetry_complete\":true"
    );
    require_contains("service slab JSON", body, "\"service_cgroup_slab\":555");
    require_contains("service working set JSON", body, "\"service_cgroup_working_set\":3697");
    require_contains("service populated JSON", body, "\"service_cgroup_populated\":false");
    require_contains("service population known JSON", body, "\"service_cgroup_population_known\":true");

    char pressure_path[4096];
    join_path(pressure_path, sizeof(pressure_path), service, "memory.pressure");
    if (unlink(pressure_path) != 0) {
        fprintf(stderr, "unlink(%s): %s\n", pressure_path, strerror(errno));
        exit(1);
    }
    memset(&metrics, 0, sizeof(metrics));
    read_configured_cgroup_metrics(&metrics);
    require_int("missing service PSI fails telemetry closed", metrics.service_cgroup_telemetry_complete, 0);

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
        "anon 2048\nfile 1536\nshmem 64\nsock 32\nkernel 96\nfile_mapped 128\n"
        "inactive_anon 256\nactive_anon 512\ninactive_file 1024\nactive_file 512\n"
        "file_dirty 128\nfile_writeback 64\n"
        "slab_reclaimable 256\nslab_unreclaimable 128\n"
        "workingset_refault_file 10\nworkingset_activate_file 11\n"
        "workingset_restore_file 12\npgfault 13\npgmajfault 14\n"
        "pgscan 15\npgsteal 16\n"
    );
    write_file(
        worker,
        "memory.events.local",
        "low 1\nhigh 2\nmax 3\noom 4\noom_kill 5\noom_group_kill 6\n"
    );
    write_file(
        worker,
        "memory.pressure",
        "some avg10=0.12 avg60=0.10 avg300=0.05 total=1000\n"
        "full avg10=0.01 avg60=0.01 avg300=0.00 total=100\n"
    );
    write_file(worker_child, "memory.current", "8192\n");
    write_file(worker_child, "cgroup.events", "populated 0\nfrozen 0\n");
    write_file(
        worker_child,
        "memory.stat",
        "anon 4096\nfile 3072\nshmem 128\nsock 64\nkernel 192\nfile_mapped 256\n"
        "inactive_anon 512\nactive_anon 1024\ninactive_file 512\nactive_file 2560\n"
        "file_dirty 256\nfile_writeback 128\n"
        "slab_reclaimable 128\nslab_unreclaimable 64\n"
        "workingset_refault_file 20\nworkingset_activate_file 21\n"
        "workingset_restore_file 22\npgfault 23\npgmajfault 24\n"
        "pgscan 25\npgsteal 26\n"
    );
    write_file(
        worker_child,
        "memory.events.local",
        "low 10\nhigh 20\nmax 30\noom 40\noom_kill 50\noom_group_kill 60\n"
    );
    write_file(
        worker_child,
        "memory.pressure",
        "some avg10=0.34 avg60=0.20 avg300=0.10 total=2000\n"
        "full avg10=0.02 avg60=0.01 avg300=0.00 total=200\n"
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
    require_u64("service slice shmem", set.slices[0].shmem, 192);
    require_u64("service slice socket", set.slices[0].sock, 96);
    require_u64("service slice kernel", set.slices[0].kernel, 288);
    require_u64("service slice mapped file", set.slices[0].file_mapped, 384);
    require_u64("service slice inactive anon", set.slices[0].inactive_anon, 768);
    require_u64("service slice active anon", set.slices[0].active_anon, 1536);
    require_u64("service slice inactive_file", set.slices[0].inactive_file, 1536);
    require_u64("service slice dirty file", set.slices[0].file_dirty, 384);
    require_u64("service slice writeback file", set.slices[0].file_writeback, 192);
    require_u64(
        "service slice clean inactive file",
        service_slice_clean_inactive_file(&set.slices[0]),
        960
    );
    require_u64("service slice slab reclaimable", set.slices[0].slab_reclaimable, 384);
    require_u64("service slice refault file", set.slices[0].workingset_refault_file, 30);
    require_u64("service slice activate file", set.slices[0].workingset_activate_file, 32);
    require_u64("service slice restore file", set.slices[0].workingset_restore_file, 34);
    require_u64("service slice pgfault", set.slices[0].pgfault, 36);
    require_u64("service slice pgmajfault", set.slices[0].pgmajfault, 38);
    require_u64("service slice pgscan", set.slices[0].pgscan, 40);
    require_u64("service slice pgsteal", set.slices[0].pgsteal, 42);
    require_u64("optional service slice proactive pgscan", set.slices[0].pgscan_proactive, 0);
    require_u64("optional service slice proactive pgsteal", set.slices[0].pgsteal_proactive, 0);
    require_u64("service slice local low", set.slices[0].memory_events_local_low, 11);
    require_u64("service slice local high", set.slices[0].memory_events_local_high, 22);
    require_u64("service slice local max", set.slices[0].memory_events_local_max, 33);
    require_u64("service slice local oom", set.slices[0].memory_events_local_oom, 44);
    require_u64("service slice local oom kill", set.slices[0].memory_events_local_oom_kill, 55);
    require_u64(
        "service slice local oom group kill",
        set.slices[0].memory_events_local_oom_group_kill,
        66
    );
    require_u64("service slice PSI some total", set.slices[0].psi_some_total_us, 3000);
    require_u64("service slice PSI full total", set.slices[0].psi_full_total_us, 300);
    require_int("service slice populated", set.slices[0].populated ? 1 : 0, 1);
    require_int("service slice population known", set.slices[0].population_known ? 1 : 0, 1);
    require_int("service slice telemetry complete", set.slices[0].telemetry_complete ? 1 : 0, 1);
    struct stat worker_stat;
    if (stat(worker, &worker_stat) != 0) {
        fprintf(stderr, "stat(%s): %s\n", worker, strerror(errno));
        exit(1);
    }
    require_u64("service slice cgroup id", set.slices[0].cgroup_id, worker_stat.st_ino);
    require_u64("service slice reclaimable", service_slice_reclaimable(&set.slices[0]), 1920);
    require_u64("service slice working set", service_slice_working_set(&set.slices[0]), 10368);

    char body[16384];
    require_int("complete service slice response", service_slices_json(&set, body, sizeof(body)), 0);
    require_contains("service slice version JSON", body, "\"version\":2");
    require_contains("service slice response not truncated", body, "\"truncated\":false");
    require_contains("service slice response telemetry", body, "\"telemetry_complete\":true");
    require_ends_with("complete service slice JSON", body, "}\n");
    require_contains("service slice key JSON", body, "\"key\":\"chum_mem_worker\"");
    require_contains("service slice current JSON", body, "\"memory_current\":12288");
    require_contains("service slice working set JSON", body, "\"working_set\":10368");
    require_contains("service slice reclaimable JSON", body, "\"reclaimable\":1920");
    require_contains("service slice clean inactive JSON", body, "\"clean_inactive_file\":960");
    require_contains("service slice refault JSON", body, "\"workingset_refault_file\":30");
    require_contains("service slice PSI total JSON", body, "\"psi_some_total_us\":3000");
    require_contains("service slice population known JSON", body, "\"population_known\":true");
    require_contains("service slice telemetry JSON", body, "\"telemetry_complete\":true");

    set.truncated = true;
    require_int("scanner-truncated service slice response", service_slices_json(&set, body, sizeof(body)), 1);
    require_contains("scanner truncation marker", body, "\"truncated\":true");
    require_contains(
        "scanner truncation telemetry fails closed",
        body,
        "\"telemetry_complete\":false"
    );
    set.truncated = false;

    char truncated_body[512];
    require_int(
        "truncated service slice response",
        service_slices_json(&set, truncated_body, sizeof(truncated_body)),
        1
    );
    require_contains("truncated response marker", truncated_body, "\"truncated\":true");
    require_contains(
        "truncated response telemetry fails closed",
        truncated_body,
        "\"telemetry_complete\":false"
    );
    require_not_contains(
        "truncated response has no authoritative slice",
        truncated_body,
        "\"telemetry_complete\":true"
    );
    require_ends_with("truncated service slice JSON", truncated_body, "}\n");
}

static void test_service_slice_scanner_adds_root_residual_for_uncovered_service_charge(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-service-residual.XXXXXX", tmpdir);
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
    char docker_child[4096];
    join_path(services, sizeof(services), root, "conjet-services.slice");
    join_path(worker, sizeof(worker), services, "conjet-service-chum_mem_worker.slice");
    join_path(docker_child, sizeof(docker_child), services, "docker-uncovered.scope");
    make_dir(services);
    make_dir(worker);
    make_dir(docker_child);

    write_file(services, "memory.current", "268435456\n");
    write_file(services, "cgroup.events", "populated 1\nfrozen 0\n");
    write_file(
        services,
        "memory.stat",
        "anon 33554432\nfile 234881024\ninactive_file 201326592\nactive_file 33554432\n"
        "slab_reclaimable 16777216\nslab_unreclaimable 8388608\n"
    );
    write_file(worker, "memory.current", "67108864\n");
    write_file(worker, "cgroup.events", "populated 1\nfrozen 0\n");
    write_file(
        worker,
        "memory.stat",
        "anon 16777216\nfile 50331648\ninactive_file 33554432\nactive_file 16777216\n"
        "slab_reclaimable 4194304\nslab_unreclaimable 2097152\n"
    );
    write_file(docker_child, "memory.current", "201326592\n");
    write_file(docker_child, "cgroup.events", "populated 1\nfrozen 0\n");

    struct service_slice_set set;
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(root, 0, &set);
    add_residual_service_root_slice(services, &set);

    require_u64("service residual slice count", (uint64_t)set.count, 2);
    const struct service_slice_stat *residual = find_slice(&set, SERVICE_ROOT_RESIDUAL_KEY);
    if (residual == NULL) {
        fprintf(stderr, "expected residual service root slice\n");
        exit(1);
    }
    require_string("residual path", residual->path, services);
    require_u64("residual current", residual->memory_current, 201326592);
    require_u64("residual inactive_file", residual->inactive_file, 167772160);
    require_u64("residual slab reclaimable", residual->slab_reclaimable, 12582912);
    require_u64("residual reclaimable", service_slice_reclaimable(residual), 180355072);
    require_int("residual populated", residual->populated ? 1 : 0, 1);
    require_int("residual population known", residual->population_known ? 1 : 0, 1);
    require_int("residual telemetry is intentionally incomplete", residual->telemetry_complete ? 1 : 0, 0);

    char body[16384];
    service_slices_json(&set, body, sizeof(body));
    require_contains("residual key JSON", body, "\"key\":\"conjet_services_residual\"");
    require_contains("residual current JSON", body, "\"memory_current\":201326592");
    require_contains("residual telemetry JSON", body, "\"telemetry_complete\":false");
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

static void test_service_slice_scanner_fails_closed_on_unreadable_root(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-scan-errors.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root) || mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp for scanner errors: %s\n", strerror(errno));
        exit(1);
    }

    struct service_slice_set set;
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(root, 0, &set);
    require_int("readable empty service tree is complete", set.truncated ? 1 : 0, 0);

    char missing[4096];
    join_path(missing, sizeof(missing), root, "missing");
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(missing, 0, &set);
    require_int("missing service tree fails closed", set.truncated ? 1 : 0, 1);
    char body[1024];
    require_int("missing service tree response is truncated", service_slices_json(&set, body, sizeof(body)), 1);
    require_contains("missing service tree telemetry fails closed", body, "\"telemetry_complete\":false");

    char broken_service[4096];
    join_path(
        broken_service,
        sizeof(broken_service),
        root,
        "conjet-service-broken.slice"
    );
    make_dir(broken_service);
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(root, 0, &set);
    require_int("unreadable service metrics fail closed", set.truncated ? 1 : 0, 1);

    char long_name[192];
    size_t offset = (size_t)snprintf(long_name, sizeof(long_name), "%s", SERVICE_SLICE_MARKER);
    while (offset + sizeof(".slice") < sizeof(long_name)) {
        long_name[offset++] = 'a';
    }
    snprintf(long_name + offset, sizeof(long_name) - offset, ".slice");
    char long_service[4096];
    join_path(long_service, sizeof(long_service), root, long_name);
    make_dir(long_service);
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(long_service, 0, &set);
    require_int("truncated service key fails closed", set.truncated ? 1 : 0, 1);

    char stat_root[4096];
    char dangling_entry[4096];
    join_path(stat_root, sizeof(stat_root), root, "stat-failure");
    join_path(dangling_entry, sizeof(dangling_entry), stat_root, "dangling");
    make_dir(stat_root);
    if (symlink("missing-target", dangling_entry) != 0) {
        fprintf(stderr, "symlink(%s): %s\n", dangling_entry, strerror(errno));
        exit(1);
    }
    memset(&set, 0, sizeof(set));
    scan_service_slice_cgroups(stat_root, 0, &set);
    require_int("child stat failure fails closed", set.truncated ? 1 : 0, 1);

    memset(&set, 0, sizeof(set));
    add_residual_service_root_slice(missing, &set);
    require_int("missing residual root fails closed", set.truncated ? 1 : 0, 1);

    write_file(root, "memory.current", "1\n");
    memset(&set, 0, sizeof(set));
    set.count = 1;
    set.slices[0].memory_current = 2;
    add_residual_service_root_slice(root, &set);
    require_int("inconsistent residual root fails closed", set.truncated ? 1 : 0, 1);
}

static void test_residual_service_reclaim_request_validation_is_root_scoped(void) {
    struct reclaim_request request;
    memset(&request, 0, sizeof(request));
    request.service_scoped = true;
    request.bytes = 67108864;
    snprintf(request.service_key, sizeof(request.service_key), "%s", SERVICE_ROOT_RESIDUAL_KEY);
    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice"
    );
    unsetenv("CONJET_SERVICE_CGROUP");
    require_int("valid residual service root reclaim", service_reclaim_request_is_valid(&request) ? 1 : 0, 1);

    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice/docker-uncovered.scope"
    );
    require_int("reject residual non-root path", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);

    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice/../conjet-services.slice"
    );
    require_int("reject residual path traversal", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);

    snprintf(request.service_key, sizeof(request.service_key), "%s/../bad", SERVICE_ROOT_RESIDUAL_KEY);
    snprintf(
        request.cgroup_path,
        sizeof(request.cgroup_path),
        "/sys/fs/cgroup/conjet.slice/conjet-services.slice"
    );
    require_int("reject unsafe residual key", service_reclaim_request_is_valid(&request) ? 1 : 0, 0);
}

int main(void) {
    test_vsock_peer_requires_host_cid();
    test_build_snapshot_aggregates_prefixed_sibling_memory_without_false_activity();
    test_default_build_cgroup_path_tracks_daemon_scoped_build_workers();
    test_page_size_and_mglru_helpers_are_fail_closed();
    test_global_memory_sources_distinguish_valid_zero_from_invalid();
    test_service_cgroup_memory_stat_is_exported();
    test_service_slice_scanner_aggregates_working_set_by_service_key();
    test_service_slice_scanner_adds_root_residual_for_uncovered_service_charge();
    test_service_slice_scanner_fails_closed_on_unreadable_root();
    test_service_reclaim_request_validation_matches_slice_key();
    test_residual_service_reclaim_request_validation_is_root_scoped();
    puts("conjet-memd cgroup regression tests passed");
    return 0;
}
