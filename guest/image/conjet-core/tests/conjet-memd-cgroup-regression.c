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

int main(void) {
    test_build_snapshot_aggregates_prefixed_sibling_memory_without_false_activity();
    puts("conjet-memd cgroup regression tests passed");
    return 0;
}
