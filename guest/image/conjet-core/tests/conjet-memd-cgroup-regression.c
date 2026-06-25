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

static void require_true(const char *name, int value) {
    if (!value) {
        fprintf(stderr, "%s: expected true\n", name);
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

static void read_file(const char *dir, const char *name, char *out, size_t out_len) {
    char path[4096];
    join_path(path, sizeof(path), dir, name);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        fprintf(stderr, "fopen(%s): %s\n", path, strerror(errno));
        exit(1);
    }
    size_t n = fread(out, 1, out_len - 1, f);
    fclose(f);
    out[n] = '\0';
}

static void make_memory_block(const char *root, const char *name, const char *state, const char *removable, const char *phys_index) {
    char block[4096];
    join_path(block, sizeof(block), root, name);
    make_dir(block);
    write_file(block, "state", state);
    write_file(block, "removable", removable);
    write_file(block, "phys_index", phys_index);
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

static void test_memory_hard_drop_offlines_only_removable_online_blocks(void) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    char root[4096];
    int written = snprintf(root, sizeof(root), "%s/conjet-memd-memory.XXXXXX", tmpdir);
    if (written <= 0 || (size_t)written >= sizeof(root)) {
        fprintf(stderr, "test root path too long for %s\n", tmpdir);
        exit(1);
    }
    if (mkdtemp(root) == NULL) {
        fprintf(stderr, "mkdtemp: %s\n", strerror(errno));
        exit(1);
    }

    write_file(root, "block_size_bytes", "0x40000000\n");
    make_memory_block(root, "memory0", "online\n", "0\n", "0x0\n");
    make_memory_block(root, "memory1", "online\n", "1\n", "0x1\n");
    make_memory_block(root, "memory2", "online\n", "1\n", "0x2\n");
    make_memory_block(root, "memory3", "offline\n", "1\n", "0x3\n");

    setenv("CONJET_MEMORY_SYSFS_ROOT", root, 1);
    struct memory_hard_drop_result result = offline_guest_memory_blocks(1536ULL * 1024ULL * 1024ULL);
    require_true("hard drop accepted", result.accepted);
    require_u64("hard drop requested", result.requested_bytes, 1536ULL * 1024ULL * 1024ULL);
    require_u64("hard drop offlined", result.offlined_bytes, 2048ULL * 1024ULL * 1024ULL);
    require_int("hard drop candidate count", (int)result.candidate_count, 2);
    require_int("hard drop range count", (int)result.range_count, 2);
    require_int("hard drop failed count", (int)result.failed_count, 0);
    require_u64("first range is highest removable block", result.ranges[0].start, 0x80000000ULL);
    require_u64("second range is next removable block", result.ranges[1].start, 0x40000000ULL);

    char state[64];
    char block0[4096];
    char block1[4096];
    char block2[4096];
    join_path(block0, sizeof(block0), root, "memory0");
    join_path(block1, sizeof(block1), root, "memory1");
    join_path(block2, sizeof(block2), root, "memory2");
    read_file(block0, "state", state, sizeof(state));
    require_true("non-removable block remains online", strstr(state, "online") != NULL);
    read_file(block1, "state", state, sizeof(state));
    require_true("removable block 1 was offlined", strstr(state, "offline") != NULL);
    read_file(block2, "state", state, sizeof(state));
    require_true("removable block 2 was offlined", strstr(state, "offline") != NULL);

    char json[4096];
    memory_hard_drop_json(json, sizeof(json), &result);
    require_true("hard drop json contains candidate count", strstr(json, "\"candidate_count\":2") != NULL);
    require_true("hard drop json contains failed count", strstr(json, "\"failed_count\":0") != NULL);
    require_true("hard drop json contains ranges", strstr(json, "\"ranges\":[") != NULL);
    require_true("hard drop json contains source", strstr(json, "\"source\":\"conjet-memd\"") != NULL);
    unsetenv("CONJET_MEMORY_SYSFS_ROOT");
}

int main(void) {
    test_build_snapshot_aggregates_prefixed_sibling_memory_without_false_activity();
    test_memory_hard_drop_offlines_only_removable_online_blocks();
    puts("conjet-memd cgroup regression tests passed");
    return 0;
}
