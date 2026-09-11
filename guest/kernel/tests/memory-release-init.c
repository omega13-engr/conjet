// Isolated PID 1 fixture for Jetstream's ignored Linux page-reporting test.
// Build statically for Linux ARM64 and place at /init in a gzip newc initramfs.
#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <unistd.h>

int main(void) {
    const size_t released = 64 * 1024 * 1024, retained = 4 * 1024 * 1024;
    unsigned char *allocation = NULL, *canary = NULL;
    assert(mount("proc", "/proc", "proc", 0, NULL) == 0);
    assert(mount("sysfs", "/sys", "sysfs", 0, NULL) == 0);
    FILE *delay = fopen("/sys/module/page_reporting/parameters/report_delay_ms", "r");
    unsigned value = 0;
    assert(delay && fscanf(delay, "%u", &value) == 1 && value == 25);
    fclose(delay);
    int server = socket(AF_VSOCK, SOCK_STREAM, 0);
    assert(server >= 0);
    struct sockaddr_vm address = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = 2376};
    assert(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(server, 4) == 0);
    puts("CONJET_INIT_READY");
    fflush(stdout);
    for (;;) {
        int client = accept(server, NULL, NULL);
        assert(client >= 0);
        char request[512] = {0};
        size_t received = 0;
        while (strstr(request, "\r\n\r\n") == NULL) {
            assert(received < sizeof(request) - 1);
            ssize_t count = read(client, request + received, sizeof(request) - received - 1);
            assert(count > 0);
            received += (size_t)count;
        }
        int exit_requested = strstr(request, "GET /exit ") != NULL;
        if (strstr(request, "GET /allocate ")) {
            assert(allocation == NULL);
            allocation = mmap(NULL, released + retained, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            assert(allocation != MAP_FAILED);
            canary = allocation + released;
            for (size_t i = 0; i < released + retained; i += 4096) allocation[i] = 0x5a;
        } else if (strstr(request, "GET /free ")) {
            assert(allocation != NULL);
            assert(munmap(allocation, released) == 0);
            allocation = NULL;
            int trigger = open("/sys/module/page_reporting/parameters/report_trigger", O_WRONLY);
            assert(trigger >= 0 && write(trigger, "1\n", 2) == 2);
            close(trigger);
        } else if (strstr(request, "GET /verify ")) {
            assert(canary != NULL && allocation == NULL);
            for (size_t i = 0; i < retained; i += 4096) assert(canary[i] == 0x5a);
            unsigned char *reused = mmap(NULL, released, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            assert(reused != MAP_FAILED);
            for (size_t i = 0; i < released; i += 4096) {
                assert(reused[i] == 0);
                reused[i] = 0xa5;
            }
            for (size_t i = 0; i < released; i += 4096) assert(reused[i] == 0xa5);
            assert(munmap(reused, released) == 0);
            puts("CONJET_MEMORY_REUSE_OK");
            fflush(stdout);
        } else {
            assert(exit_requested || strstr(request, "GET /ready "));
        }
        const char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nOK\n";
        size_t sent = 0;
        while (sent < sizeof(response) - 1) {
            ssize_t count = write(client, response + sent, sizeof(response) - 1 - sent);
            assert(count > 0);
            sent += (size_t)count;
        }
        close(client);
        if (exit_requested) {
            sleep(1);
            reboot(RB_POWER_OFF);
        }
    }
}
