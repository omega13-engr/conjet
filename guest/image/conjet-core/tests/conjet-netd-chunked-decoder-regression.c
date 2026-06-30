#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define CONJET_NETD_UNIT_TEST 1
#define main conjet_netd_test_main
#include "../src/conjet-netd.c"
#undef main

static void require_int(const char *name, int actual, int expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", name, expected, actual);
        exit(1);
    }
}

static void require_size(const char *name, size_t actual, size_t expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %zu, got %zu\n", name, expected, actual);
        exit(1);
    }
}

static void require_body(const char *name, const char *actual, size_t actual_len, const char *expected) {
    size_t expected_len = strlen(expected);
    require_size(name, actual_len, expected_len);
    if (memcmp(actual, expected, expected_len) != 0) {
        fprintf(stderr, "%s: decoded body mismatch\n", name);
        exit(1);
    }
}

static void require_contains(const char *name, const char *haystack, size_t haystack_len, const char *needle) {
    if (memmem(haystack, haystack_len, needle, strlen(needle)) == NULL) {
        fprintf(stderr, "%s: missing expected substring: %s\n", name, needle);
        exit(1);
    }
}

struct proxy_thread_args {
    int client;
    const uint8_t *first;
    size_t first_len;
};

struct fake_docker_server_args {
    int listen_fd;
    const char *response;
    const char *expected_request_substring;
    char request[8192];
    size_t request_len;
    int reject_client_eof_before_response;
    int result;
};

static void *proxy_thread_main(void *raw) {
    struct proxy_thread_args *args = raw;
    handle_docker_proxy(args->client, args->first, args->first_len);
    free(args);
    return NULL;
}

static void *fake_docker_server_main(void *raw) {
    struct fake_docker_server_args *args = raw;
    int fd = accept(args->listen_fd, NULL, NULL);
    if (fd < 0) {
        args->result = errno == 0 ? -1 : -errno;
        return NULL;
    }

    while (args->request_len < sizeof(args->request)) {
        ssize_t n = read(fd, args->request + args->request_len, sizeof(args->request) - args->request_len);
        if (n > 0) {
            args->request_len += (size_t)n;
            if (docker_http_request_is_complete((const uint8_t *)args->request, args->request_len)) {
                break;
            }
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        break;
    }

    if (args->expected_request_substring != NULL &&
        memmem(args->request, args->request_len, args->expected_request_substring, strlen(args->expected_request_substring)) == NULL) {
        args->result = -100;
    } else if (args->reject_client_eof_before_response) {
        struct timeval timeout = {.tv_sec = 0, .tv_usec = 200000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        char probe;
        ssize_t n = read(fd, &probe, 1);
        if (n == 0) {
            args->result = -102;
        } else if (n > 0) {
            args->result = -103;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            args->result = -104;
        }
    }

    if (args->result == 0 && args->response != NULL && write_full(fd, args->response, strlen(args->response)) != 0) {
        args->result = -101;
    }

    close(fd);
    return NULL;
}

static int make_fake_docker_listener(char *path, size_t path_len) {
    const char *tmpdir = getenv("TMPDIR");
    if (tmpdir == NULL || tmpdir[0] == '\0') {
        tmpdir = "/tmp";
    }
    int written = snprintf(path, path_len, "%s/conjet-netd-test-%ld.sock", tmpdir, (long)getpid());
    if (written <= 0 || (size_t)written >= path_len) {
        return -1;
    }
    unlink(path);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(fd, 1) != 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    return fd;
}

static void read_client_response(int fd, char *out, size_t out_len, size_t *used) {
    *used = 0;
    while (*used < out_len) {
        ssize_t n = read(fd, out + *used, out_len - *used);
        if (n > 0) {
            *used += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
}

static void run_proxy_fixture(
    const char *test_name,
    const char *first,
    const char *client_remainder,
    const char *expected_upstream_substring,
    const char *server_response,
    const char *expected_client_substring,
    int half_close_client,
    int reject_client_eof_before_response
) {
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int listen_fd = make_fake_docker_listener(socket_path, sizeof(socket_path));
    if (listen_fd < 0) {
        perror("fake Docker listener");
        exit(1);
    }
    g_conjet_netd_test_docker_socket_path = socket_path;

    struct fake_docker_server_args server_args = {
        .listen_fd = listen_fd,
        .response = server_response,
        .expected_request_substring = expected_upstream_substring,
        .request_len = 0,
        .reject_client_eof_before_response = reject_client_eof_before_response,
        .result = 0
    };
    pthread_t server_thread;
    if (pthread_create(&server_thread, NULL, fake_docker_server_main, &server_args) != 0) {
        perror("pthread_create server");
        exit(1);
    }

    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        perror("socketpair");
        exit(1);
    }

    if (client_remainder != NULL && client_remainder[0] != '\0' &&
        write_full(pair[1], client_remainder, strlen(client_remainder)) != 0) {
        perror("write client remainder");
        exit(1);
    }
    if (half_close_client) {
        shutdown(pair[1], SHUT_WR);
    }

    struct proxy_thread_args *proxy_args = calloc(1, sizeof(*proxy_args));
    if (proxy_args == NULL) {
        perror("calloc proxy args");
        exit(1);
    }
    proxy_args->client = pair[0];
    proxy_args->first = (const uint8_t *)first;
    proxy_args->first_len = strlen(first);

    pthread_t proxy_thread;
    if (pthread_create(&proxy_thread, NULL, proxy_thread_main, proxy_args) != 0) {
        perror("pthread_create proxy");
        exit(1);
    }

    char response[8192];
    size_t response_len = 0;
    read_client_response(pair[1], response, sizeof(response), &response_len);
    close(pair[1]);

    pthread_join(proxy_thread, NULL);
    pthread_join(server_thread, NULL);
    close(listen_fd);
    unlink(socket_path);
    g_conjet_netd_test_docker_socket_path = NULL;

    if (server_args.result != 0) {
        fprintf(stderr, "%s: fake Docker server failed: %d\n", test_name, server_args.result);
        exit(1);
    }
    require_contains(test_name, response, response_len, expected_client_substring);
}

static void require_not_contains(const char *name, const char *haystack, size_t haystack_len, const char *needle) {
    if (memmem(haystack, haystack_len, needle, strlen(needle)) != NULL) {
        fprintf(stderr, "%s: unexpected substring: %s\n", name, needle);
        exit(1);
    }
}

static void test_decodes_single_chunk(void) {
    char body[] = "b\r\nHello World\r\n0\r\n\r\n";
    size_t body_len = sizeof(body) - 1;

    require_int("single chunk status", decode_http_chunked_body_in_place(body, &body_len), 0);
    require_body("single chunk body", body, body_len, "Hello World");
}

static void test_decodes_multiple_chunks(void) {
    char body[] = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n";
    size_t body_len = sizeof(body) - 1;

    require_int("multiple chunks status", decode_http_chunked_body_in_place(body, &body_len), 0);
    require_body("multiple chunks body", body, body_len, "Hello World");
}

static void test_rejects_truncated_chunk(void) {
    char body[] = "c\r\nHello World\r\n0\r\n\r\n";
    size_t body_len = sizeof(body) - 1;

    require_int("truncated chunk status", decode_http_chunked_body_in_place(body, &body_len), -1);
}

static void test_rejects_wrapping_chunk_length(void) {
    char body[] = "ffffffffffffffff\r\nHello World\r\n";
    size_t body_len = sizeof(body) - 1;

    require_int("wrapping chunk status", decode_http_chunked_body_in_place(body, &body_len), -1);
}

static void test_response_chunk_parser_accepts_split_terminal_chunk(void) {
    struct chunked_response_parser parser;
    chunked_response_parser_init(&parser);

    require_int("split chunk data", chunked_response_parser_feed(&parser, "b\r\nHello World\r\n", 16), 0);
    require_int("split terminal chunk prefix", chunked_response_parser_feed(&parser, "0\r", 2), 0);
    require_int("split terminal chunk suffix", chunked_response_parser_feed(&parser, "\n\r\n", 3), 1);
}

static void test_response_chunk_parser_accepts_trailers(void) {
    struct chunked_response_parser parser;
    chunked_response_parser_init(&parser);

    require_int(
        "chunked with trailers",
        chunked_response_parser_feed(
            &parser,
            "1\r\na\r\n0\r\nDocker-Trailer: ok\r\n\r\n",
            strlen("1\r\na\r\n0\r\nDocker-Trailer: ok\r\n\r\n")
        ),
        1
    );
}

static void test_response_status_classifies_no_body_responses(void) {
    const char start_response[] = "HTTP/1.1 204 No Content\r\nApi-Version: 1.52\r\n\r\n";
    const char inspect_response[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";

    require_int(
        "204 response status",
        parse_http_response_status_code(start_response, strlen(start_response)),
        204
    );
    require_int("204 has no body", http_status_has_no_response_body(204), 1);
    require_int(
        "200 response status",
        parse_http_response_status_code(inspect_response, strlen(inspect_response)),
        200
    );
    require_int("200 has body", http_status_has_no_response_body(200), 0);
}

static void test_docker_event_filter_accepts_target_changes(void) {
    const char start_event[] = "{\"Type\":\"container\",\"Action\":\"start\",\"Actor\":{\"ID\":\"abc\"}}\n";
    const char network_event[] = "{\"Type\":\"network\",\"Action\":\"connect\",\"Actor\":{\"Attributes\":{\"container\":\"abc\"}}}\n";

    require_int(
        "container start event",
        docker_event_line_should_refresh_targets(start_event, strlen(start_event)),
        1
    );
    require_int(
        "network connect event",
        docker_event_line_should_refresh_targets(network_event, strlen(network_event)),
        1
    );
}

static void test_docker_event_filter_ignores_noisy_events(void) {
    const char top_event[] = "{\"Type\":\"container\",\"Action\":\"top\",\"Actor\":{\"ID\":\"abc\"}}\n";
    const char exec_event[] = "{\"Type\":\"container\",\"Action\":\"exec_start\",\"Actor\":{\"ID\":\"abc\"}}\n";
    const char health_event[] = "{\"Type\":\"container\",\"status\":\"health_status: healthy\",\"id\":\"abc\"}\n";

    require_int("container top event", docker_event_line_should_refresh_targets(top_event, strlen(top_event)), 0);
    require_int("container exec event", docker_event_line_should_refresh_targets(exec_event, strlen(exec_event)), 0);
    require_int("container health event", docker_event_line_should_refresh_targets(health_event, strlen(health_event)), 0);
}

static void test_container_create_rewrite_inserts_service_cgroup_for_empty_host_config(void) {
    const char body[] = "{\"Image\":\"alpine\",\"HostConfig\":{}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "empty HostConfig rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_body(
        "empty HostConfig body",
        (const char *)rewritten,
        rewritten_len,
        "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\"}}"
    );
    free(rewritten);
}

static void test_container_create_rewrite_inserts_service_cgroup_for_populated_host_config(void) {
    const char body[] = "{\"Image\":\"alpine\",\"HostConfig\":{\"AutoRemove\":true}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "populated HostConfig rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_body(
        "populated HostConfig body",
        (const char *)rewritten,
        rewritten_len,
        "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\",\"AutoRemove\":true}}"
    );
    free(rewritten);
}

static void test_container_create_rewrite_adds_host_config_when_missing(void) {
    const char body[] = "{\"Image\":\"alpine\"}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "missing HostConfig rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_body(
        "missing HostConfig body",
        (const char *)rewritten,
        rewritten_len,
        "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\"}}"
    );
    free(rewritten);
}

static void test_container_create_rewrite_preserves_empty_body_syntax(void) {
    const char body[] = "{}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "empty body rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_body(
        "empty body",
        (const char *)rewritten,
        rewritten_len,
        "{\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\"}}"
    );
    free(rewritten);
}

static void test_container_create_request_rewrites_content_length(void) {
    const char request[] =
        "POST /v1.44/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 18\r\n"
        "\r\n"
        "{\"Image\":\"alpine\"}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "container create request rewrite",
        rewrite_container_create_request((const uint8_t *)request, strlen(request), &rewritten, &rewritten_len),
        1
    );
    require_contains(
        "rewritten request",
        (const char *)rewritten,
        rewritten_len,
        "Content-Length: 72\r\n\r\n"
    );
    require_contains(
        "rewritten request body",
        (const char *)rewritten,
        rewritten_len,
        "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\"}}"
    );
    free(rewritten);
}

static void test_container_create_rewrite_routes_buildkit_to_build_cgroup(void) {
    const char body[] = "{\"Image\":\"alpine\",\"Labels\":{\"moby.buildkit.worker.executor\":\"oci\"}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "BuildKit body rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_contains(
        "BuildKit body cgroup",
        (const char *)rewritten,
        rewritten_len,
        "\"CgroupParent\":\"conjet-build.slice\""
    );
    free(rewritten);
}

static void test_container_create_rewrite_routes_buildkit_image_to_build_cgroup(void) {
    const char body[] = "{\"Image\":\"moby/buildkit:buildx-stable-1\",\"HostConfig\":{}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "BuildKit image rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_contains(
        "BuildKit image cgroup",
        (const char *)rewritten,
        rewritten_len,
        "\"CgroupParent\":\"conjet-build.slice\""
    );
    free(rewritten);
}

static void test_container_create_rewrite_skips_existing_cgroup_parent(void) {
    const char body[] = "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"custom.slice\"}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "existing CgroupParent rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        0
    );
    require_int("existing CgroupParent output", rewritten == NULL, 1);
    require_size("existing CgroupParent output length", rewritten_len, 0);
}

static void test_container_create_rewrite_replaces_empty_cgroup_parent(void) {
    const char body[] = "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"\",\"AutoRemove\":true}}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "empty CgroupParent rewrite",
        rewrite_container_create_body((const uint8_t *)body, strlen(body), &rewritten, &rewritten_len),
        1
    );
    require_body(
        "empty CgroupParent body",
        (const char *)rewritten,
        rewritten_len,
        "{\"Image\":\"alpine\",\"HostConfig\":{\"CgroupParent\":\"conjet-services.slice\",\"AutoRemove\":true}}"
    );
    free(rewritten);
}

static void test_container_create_rewrite_skips_chunked_request(void) {
    const char request[] =
        "POST /v1.44/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "12\r\n{\"Image\":\"alpine\"}\r\n0\r\n\r\n";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "chunked container create request rewrite",
        rewrite_container_create_request((const uint8_t *)request, strlen(request), &rewritten, &rewritten_len),
        0
    );
    require_not_contains("chunked request", request, strlen(request), "CgroupParent");
    require_int("chunked request output", rewritten == NULL, 1);
    require_size("chunked request output length", rewritten_len, 0);
}

static void test_build_request_rewrite_adds_cgroup_parent(void) {
    const char request[] =
        "POST /v1.52/build?t=chum-mem-api&nocache=1 HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "build request cgroup rewrite status",
        rewrite_docker_build_request_cgroup_parent((const uint8_t *)request, strlen(request), &rewritten, &rewritten_len),
        1
    );
    require_contains(
        "build request cgroup rewrite",
        (const char *)rewritten,
        rewritten_len,
        "POST /v1.52/build?t=chum-mem-api&nocache=1&cgroupparent=/conjet.slice/conjet-build.slice HTTP/1.1"
    );
    free(rewritten);
}

static void test_build_request_rewrite_skips_existing_cgroup_parent(void) {
    const char request[] =
        "POST /build?cgroupparent=custom.slice&t=chum-mem-api HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "build request existing cgroup rewrite status",
        rewrite_docker_build_request_cgroup_parent((const uint8_t *)request, strlen(request), &rewritten, &rewritten_len),
        0
    );
    require_int("build request existing cgroup output", rewritten == NULL, 1);
    require_size("build request existing cgroup output length", rewritten_len, 0);
}

static void test_docker_http_request_extent_detects_complete_requests(void) {
    const char get_request[] =
        "GET /v1.52/containers/json HTTP/1.1\r\n"
        "Host: docker\r\n"
        "\r\n";
    const char post_request[] =
        "POST /v1.52/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 2\r\n"
        "\r\n"
        "{}";
    const char partial_post_request[] =
        "POST /v1.52/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 4\r\n"
        "\r\n"
        "{}";
    const char chunked_request[] =
        "POST /v1.52/build HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n";
    size_t needed = 0;

    require_int(
        "GET extent status",
        docker_http_request_extent((const uint8_t *)get_request, strlen(get_request), &needed),
        1
    );
    require_size("GET extent needed", needed, strlen(get_request));
    require_int(
        "GET complete",
        docker_http_request_is_complete((const uint8_t *)get_request, strlen(get_request)),
        1
    );
    require_int(
        "POST complete",
        docker_http_request_is_complete((const uint8_t *)post_request, strlen(post_request)),
        1
    );
    require_int(
        "partial POST incomplete",
        docker_http_request_is_complete((const uint8_t *)partial_post_request, strlen(partial_post_request)),
        0
    );
    require_int(
        "chunked extent status",
        docker_http_request_extent((const uint8_t *)chunked_request, strlen(chunked_request), &needed),
        0
    );
}

static void test_rewrite_http_request_connection_close_replaces_keepalive(void) {
    const char request[] =
        "POST /v1.52/containers/abc/wait HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Connection: keep-alive\r\n"
        "Content-Length: 2\r\n"
        "\r\n"
        "{}";
    uint8_t *rewritten = NULL;
    size_t rewritten_len = 0;

    require_int(
        "connection close rewrite status",
        rewrite_http_request_connection_close((const uint8_t *)request, strlen(request), &rewritten, &rewritten_len),
        1
    );
    require_contains("connection close inserted", (const char *)rewritten, rewritten_len, "\r\nConnection: close\r\n\r\n{}");
    require_not_contains("keep-alive removed", (const char *)rewritten, rewritten_len, "Connection: keep-alive");
    free(rewritten);
}

static void test_docker_upgraded_requests_use_bidirectional_pump(void) {
    const char events_request[] =
        "GET /v1.52/events?filters=%7B%7D HTTP/1.1\r\n"
        "Host: docker\r\n"
        "\r\n";
    const char wait_request[] =
        "POST /v1.52/containers/abc/wait HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    const char attach_request[] =
        "POST /v1.52/containers/abc/attach?stdout=1&stream=1 HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: tcp\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    const char inspect_request[] =
        "GET /v1.52/containers/abc/json HTTP/1.1\r\n"
        "Host: docker\r\n"
        "\r\n";

    require_int(
        "events request is ordinary HTTP stream",
        docker_request_is_upgraded_stream((const uint8_t *)events_request, strlen(events_request)),
        0
    );
    require_int(
        "events request uses streaming HTTP pump",
        docker_request_is_streaming_http((const uint8_t *)events_request, strlen(events_request)),
        1
    );
    require_int(
        "wait request is ordinary HTTP long poll",
        docker_request_is_upgraded_stream((const uint8_t *)wait_request, strlen(wait_request)),
        0
    );
    require_int(
        "wait request uses finite response pump",
        docker_request_is_streaming_http((const uint8_t *)wait_request, strlen(wait_request)),
        0
    );
    require_int(
        "attach upgrade uses bidirectional pump",
        docker_request_is_upgraded_stream((const uint8_t *)attach_request, strlen(attach_request)),
        1
    );
    require_int(
        "inspect request is one-shot",
        docker_request_is_upgraded_stream((const uint8_t *)inspect_request, strlen(inspect_request)),
        0
    );
}

static void test_handle_docker_proxy_rewrites_fragmented_container_create(void) {
    const char first[] =
        "POST /v1.52/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 18\r\n"
        "\r\n"
        "{\"Image\"";
    const char remainder[] = ":\"alpine\"}";
    const char response[] =
        "HTTP/1.1 201 Created\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 12\r\n"
        "\r\n"
        "{\"Id\":\"abc\"}";

    run_proxy_fixture(
        "fragmented container create proxy",
        first,
        remainder,
        "\"CgroupParent\":\"conjet-services.slice\"",
        response,
        "{\"Id\":\"abc\"}",
        0,
        0
    );
}

static void test_handle_docker_proxy_rewrites_fragmented_build_request(void) {
    const char first[] =
        "POST /v1.52/bui";
    const char remainder[] =
        "ld?t=chum-mem-api&nocache=1 HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    const char response[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 11\r\n"
        "\r\n"
        "{\"ok\":true}";

    run_proxy_fixture(
        "fragmented build request proxy",
        first,
        remainder,
        "cgroupparent=/conjet.slice/conjet-build.slice",
        response,
        "{\"ok\":true}",
        0,
        0
    );
}

static void test_handle_docker_proxy_relays_informational_response_before_final(void) {
    const char request[] =
        "POST /v1.52/containers/create HTTP/1.1\r\n"
        "Host: docker\r\n"
        "Content-Length: 18\r\n"
        "\r\n"
        "{\"Image\":\"alpine\"}";
    const char response[] =
        "HTTP/1.1 100 Continue\r\n"
        "\r\n"
        "HTTP/1.1 201 Created\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 12\r\n"
        "\r\n"
        "{\"Id\":\"abc\"}";

    run_proxy_fixture(
        "informational response proxy",
        request,
        "",
        "\"CgroupParent\":\"conjet-services.slice\"",
        response,
        "{\"Id\":\"abc\"}",
        0,
        0
    );
}

static void test_handle_docker_proxy_relays_chunked_stream_after_half_close(void) {
    const char request[] =
        "GET /v1.52/events?filters=%7B%7D HTTP/1.1\r\n"
        "Host: docker\r\n"
        "\r\n";
    const char response[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "10\r\n{\"status\":\"ok\"}\n\r\n"
        "0\r\n\r\n";

    run_proxy_fixture(
        "chunked event stream proxy",
        request,
        "",
        "GET /v1.52/events",
        response,
        "{\"status\":\"ok\"}",
        1,
        0
    );
}

static void test_handle_docker_proxy_keeps_streaming_logs_upstream_open_after_client_half_close(void) {
    const char request[] =
        "GET /v1.52/containers/abcdef/logs?follow=1&stdout=1&stderr=1&tail=10 HTTP/1.1\r\n"
        "Host: docker\r\n"
        "\r\n";
    const char response[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/vnd.docker.multiplexed-stream\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "10\r\nsmoke listening\n\r\n"
        "0\r\n\r\n";

    run_proxy_fixture(
        "streaming logs proxy keeps upstream open",
        request,
        "",
        "GET /v1.52/containers/abcdef/logs?follow=1",
        response,
        "smoke listening",
        1,
        1
    );
}

int main(void) {
    test_decodes_single_chunk();
    test_decodes_multiple_chunks();
    test_rejects_truncated_chunk();
    test_rejects_wrapping_chunk_length();
    test_response_chunk_parser_accepts_split_terminal_chunk();
    test_response_chunk_parser_accepts_trailers();
    test_response_status_classifies_no_body_responses();
    test_docker_event_filter_accepts_target_changes();
    test_docker_event_filter_ignores_noisy_events();
    test_container_create_rewrite_inserts_service_cgroup_for_empty_host_config();
    test_container_create_rewrite_inserts_service_cgroup_for_populated_host_config();
    test_container_create_rewrite_adds_host_config_when_missing();
    test_container_create_rewrite_preserves_empty_body_syntax();
    test_container_create_request_rewrites_content_length();
    test_container_create_rewrite_routes_buildkit_to_build_cgroup();
    test_container_create_rewrite_routes_buildkit_image_to_build_cgroup();
    test_container_create_rewrite_skips_existing_cgroup_parent();
    test_container_create_rewrite_replaces_empty_cgroup_parent();
    test_container_create_rewrite_skips_chunked_request();
    test_build_request_rewrite_adds_cgroup_parent();
    test_build_request_rewrite_skips_existing_cgroup_parent();
    test_docker_http_request_extent_detects_complete_requests();
    test_rewrite_http_request_connection_close_replaces_keepalive();
    test_docker_upgraded_requests_use_bidirectional_pump();
    test_handle_docker_proxy_rewrites_fragmented_container_create();
    test_handle_docker_proxy_rewrites_fragmented_build_request();
    test_handle_docker_proxy_relays_informational_response_before_final();
    test_handle_docker_proxy_relays_chunked_stream_after_half_close();
    test_handle_docker_proxy_keeps_streaming_logs_upstream_open_after_client_half_close();
    puts("conjet-netd chunked decoder regression tests passed");
    return 0;
}
