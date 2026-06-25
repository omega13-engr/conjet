#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <vmnet/vmnet.h>
#include <xpc/xpc.h>

struct js_vmnet_packet {
    void *data;
    size_t len;
};

void *js_vmnet_start_shared(
    const char *interface_id,
    const char *mac_address,
    const char *start_address,
    const char *end_address,
    const char *subnet_mask,
    uint32_t *out_status
) {
    if (out_status) {
        *out_status = VMNET_FAILURE;
    }

    xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
    if (desc == NULL) {
        return NULL;
    }

    xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, VMNET_SHARED_MODE);
    xpc_dictionary_set_string(desc, vmnet_interface_id_key, interface_id);
    xpc_dictionary_set_string(desc, vmnet_mac_address_key, mac_address);
    xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false);
    xpc_dictionary_set_uint64(desc, vmnet_mtu_key, 1500);
    xpc_dictionary_set_uint64(desc, vmnet_max_packet_size_key, 1514);
    xpc_dictionary_set_string(desc, vmnet_start_address_key, start_address);
    xpc_dictionary_set_string(desc, vmnet_end_address_key, end_address);
    xpc_dictionary_set_string(desc, vmnet_subnet_mask_key, subnet_mask);
    xpc_dictionary_set_bool(desc, vmnet_enable_isolation_key, false);
    xpc_dictionary_set_bool(desc, vmnet_enable_tso_key, false);
    xpc_dictionary_set_bool(desc, vmnet_enable_checksum_offload_key, false);
    xpc_dictionary_set_uint64(desc, vmnet_read_max_packets_key, 64);
    xpc_dictionary_set_uint64(desc, vmnet_write_max_packets_key, 64);
    xpc_dictionary_set_bool(desc, vmnet_enable_virtio_header_key, false);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("dev.conjet.jetstream.rust.vmnet", NULL);
    __block vmnet_return_t completion = VMNET_FAILURE;

    interface_ref iface = vmnet_start_interface(desc, queue, ^(vmnet_return_t status, xpc_object_t params) {
        (void)params;
        completion = status;
        dispatch_semaphore_signal(sem);
    });

    if (iface == NULL) {
        xpc_release(desc);
        return NULL;
    }

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 10LL * 1000LL * 1000LL * 1000LL);
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        completion = VMNET_FAILURE;
    }
    if (out_status) {
        *out_status = completion;
    }
    xpc_release(desc);
    if (completion != VMNET_SUCCESS) {
        return NULL;
    }
    return iface;
}

uint32_t js_vmnet_stop(void *interface) {
    if (interface == NULL) {
        return VMNET_SUCCESS;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("dev.conjet.jetstream.rust.vmnet.stop", NULL);
    __block vmnet_return_t completion = VMNET_FAILURE;
    vmnet_return_t scheduled = vmnet_stop_interface((interface_ref)interface, queue, ^(vmnet_return_t status) {
        completion = status;
        dispatch_semaphore_signal(sem);
    });
    if (scheduled != VMNET_SUCCESS) {
        return scheduled;
    }
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 5LL * 1000LL * 1000LL * 1000LL);
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        return VMNET_FAILURE;
    }
    return completion;
}

uint32_t js_vmnet_write(void *interface, const struct js_vmnet_packet *packets, int *packet_count) {
    if (interface == NULL || packets == NULL || packet_count == NULL || *packet_count <= 0) {
        return VMNET_INVALID_ARGUMENT;
    }
    int count = *packet_count;
    struct iovec *iovecs = calloc((size_t)count, sizeof(struct iovec));
    struct vmpktdesc *descs = calloc((size_t)count, sizeof(struct vmpktdesc));
    if (iovecs == NULL || descs == NULL) {
        free(iovecs);
        free(descs);
        return VMNET_MEM_FAILURE;
    }
    for (int i = 0; i < count; i++) {
        iovecs[i].iov_base = packets[i].data;
        iovecs[i].iov_len = packets[i].len;
        descs[i].vm_pkt_size = packets[i].len;
        descs[i].vm_pkt_iov = &iovecs[i];
        descs[i].vm_pkt_iovcnt = 1;
        descs[i].vm_flags = 0;
    }
    uint32_t status = vmnet_write((interface_ref)interface, descs, packet_count);
    free(iovecs);
    free(descs);
    return status;
}

uint32_t js_vmnet_read(void *interface, uint8_t *buffer, size_t packet_size, int *packet_count, size_t *sizes) {
    if (interface == NULL || buffer == NULL || packet_count == NULL || sizes == NULL || *packet_count <= 0) {
        return VMNET_INVALID_ARGUMENT;
    }
    int count = *packet_count;
    struct iovec *iovecs = calloc((size_t)count, sizeof(struct iovec));
    struct vmpktdesc *descs = calloc((size_t)count, sizeof(struct vmpktdesc));
    if (iovecs == NULL || descs == NULL) {
        free(iovecs);
        free(descs);
        return VMNET_MEM_FAILURE;
    }
    for (int i = 0; i < count; i++) {
        iovecs[i].iov_base = buffer + ((size_t)i * packet_size);
        iovecs[i].iov_len = packet_size;
        descs[i].vm_pkt_size = packet_size;
        descs[i].vm_pkt_iov = &iovecs[i];
        descs[i].vm_pkt_iovcnt = 1;
        descs[i].vm_flags = 0;
    }
    uint32_t status = vmnet_read((interface_ref)interface, descs, packet_count);
    if (status == VMNET_SUCCESS) {
        for (int i = 0; i < *packet_count; i++) {
            sizes[i] = descs[i].vm_pkt_size;
        }
    }
    free(iovecs);
    free(descs);
    return status;
}
