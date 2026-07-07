use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::devices::balloon::{BalloonMetrics, BalloonQueueHandler, MemoryLedgerSummary};
use crate::devices::block::BlockQueueHandler;
use crate::devices::bus::MmioBus;
use crate::devices::net::{NetQueueHandler, VmnetPacketBridge};
use crate::devices::vsock::{HostUnixVsockBridge, VsockQueueHandler};
use crate::vmm::memory::GuestMemory;

pub struct VmState {
    pub memory: GuestMemory,
    pub mmio_bus: MmioBus,
    pub vcpu_count: u8,
    pub devices: DeviceRuntimeState,
}

impl VmState {
    pub fn new(memory: GuestMemory, vcpu_count: u8) -> Self {
        Self {
            memory,
            mmio_bus: MmioBus::new(),
            vcpu_count,
            devices: DeviceRuntimeState::default(),
        }
    }
}

#[derive(Debug, Default)]
pub struct DeviceRuntimeState {
    pub block: BTreeMap<u64, BlockQueueHandler>,
    pub balloon: BTreeMap<u64, BalloonQueueHandler>,
    pub net: BTreeMap<u64, NetQueueHandler>,
    pub vmnet_bridge: Option<Arc<Mutex<VmnetPacketBridge>>>,
    pub vsock: BTreeMap<u64, VsockQueueHandler>,
    pub docker_bridge: Option<HostUnixVsockBridge>,
    pub memory_bridge: Option<HostUnixVsockBridge>,
}

impl DeviceRuntimeState {
    pub fn docker_phase_events(&self) -> DockerPhaseMetrics {
        self.docker_bridge
            .as_ref()
            .map(|bridge| {
                let state = bridge.state.lock().expect("Docker bridge mutex poisoned");
                DockerPhaseMetrics {
                    total: state.docker_phase_events(),
                    request: state.docker_phase_request_events(),
                    response: state.docker_phase_response_events(),
                    completed_streams: state.docker_completed_stream_events(),
                    completed_workload_streams: state.docker_completed_workload_stream_events(),
                    request_bytes: state.docker_request_bytes(),
                    response_bytes: state.docker_response_bytes(),
                }
            })
            .unwrap_or_default()
    }

    pub fn balloon_metrics(&self) -> BalloonMetrics {
        self.balloon
            .values()
            .fold(BalloonMetrics::default(), |mut total, handler| {
                let metrics = handler.metrics();
                total.offered_features |= metrics.offered_features;
                total.driver_features |= metrics.driver_features;
                total.driver_ok |= metrics.driver_ok;
                total.features_ok |= metrics.features_ok;
                total.page_reporting_negotiated |= metrics.page_reporting_negotiated;
                total.reporting_queue_index = total
                    .reporting_queue_index
                    .or(metrics.reporting_queue_index);
                total.reporting_queue_ready |= metrics.reporting_queue_ready;
                for index in 0..total.queue_ready.len() {
                    total.queue_ready[index] |= metrics.queue_ready[index];
                    total.queue_size[index] =
                        total.queue_size[index].max(metrics.queue_size[index]);
                    total.queue_descriptor_address[index] |=
                        metrics.queue_descriptor_address[index];
                    total.queue_driver_address[index] |= metrics.queue_driver_address[index];
                    total.queue_device_address[index] |= metrics.queue_device_address[index];
                }
                total.reporting_guard_blocked_notifications +=
                    metrics.reporting_guard_blocked_notifications;
                total.reporting_notifications += metrics.reporting_notifications;
                total.reporting_queue_notifications += metrics.reporting_queue_notifications;
                total.reporting_queue_acknowledgements += metrics.reporting_queue_acknowledgements;
                total.reporting_queue_pending_descriptors +=
                    metrics.reporting_queue_pending_descriptors;
                total.free_page_hint_negotiated |= metrics.free_page_hint_negotiated;
                total.free_page_hint_queue_index = total
                    .free_page_hint_queue_index
                    .or(metrics.free_page_hint_queue_index);
                total.free_page_hint_queue_ready |= metrics.free_page_hint_queue_ready;
                total.free_page_hint_notifications += metrics.free_page_hint_notifications;
                total.free_page_hint_reported_bytes += metrics.free_page_hint_reported_bytes;
                total.free_page_hint_reclaimed_bytes += metrics.free_page_hint_reclaimed_bytes;
                total.free_page_hint_cmd_id = total
                    .free_page_hint_cmd_id
                    .max(metrics.free_page_hint_cmd_id);
                total.actual_pages += metrics.actual_pages;
                total.inflate_pages += metrics.inflate_pages;
                total.deflate_pages += metrics.deflate_pages;
                total.reported_free_pages += metrics.reported_free_pages;
                total.reported_free_bytes += metrics.reported_free_bytes;
                total.host_granule_eligible_bytes += metrics.host_granule_eligible_bytes;
                total.discard_advised_bytes += metrics.discard_advised_bytes;
                total.soft_reclaimed_bytes += metrics.soft_reclaimed_bytes;
                total.hard_decommitted_bytes += metrics.hard_decommitted_bytes;
                total.discard_failed_bytes += metrics.discard_failed_bytes;
                total.discard_skipped_bytes += metrics.discard_skipped_bytes;
                total.partial_host_granule_bytes += metrics.partial_host_granule_bytes;
                total.reclaimed_bytes += metrics.reclaimed_bytes;
                total.reported_free_reclaimed_bytes += metrics.reported_free_reclaimed_bytes;
                total.balloon_owned_reclaimed_bytes += metrics.balloon_owned_reclaimed_bytes;
                total.report_inflight_reclaimed_bytes += metrics.report_inflight_reclaimed_bytes;
                total.current_balloon_owned_bytes += metrics.current_balloon_owned_bytes;
                total.current_fully_owned_host_granules +=
                    metrics.current_fully_owned_host_granules;
                total.current_partially_owned_host_granules +=
                    metrics.current_partially_owned_host_granules;
                total.current_balloon_decommitted_bytes +=
                    metrics.current_balloon_decommitted_bytes;
                total.reclaim_failures += metrics.reclaim_failures;
                total.malformed_reports += metrics.malformed_reports;
                total
            })
    }

    pub fn memory_ledger_summary(
        &self,
        guest_size: u64,
        host_page_size: u64,
    ) -> MemoryLedgerSummary {
        if self.balloon.is_empty() {
            let host_granules = if host_page_size == 0 {
                0
            } else {
                guest_size.div_ceil(host_page_size)
            };
            return MemoryLedgerSummary {
                guest_visible_bytes: guest_size,
                host_granule_bytes: host_page_size,
                host_granules,
                resident_bytes: guest_size,
                guest_owned_bytes: guest_size,
                ok: true,
                ..MemoryLedgerSummary::default()
            };
        }
        self.balloon
            .values()
            .fold(MemoryLedgerSummary::default(), |mut total, handler| {
                let summary = handler.memory_ledger_summary(guest_size, host_page_size);
                total.guest_visible_bytes =
                    total.guest_visible_bytes.max(summary.guest_visible_bytes);
                total.host_granule_bytes = total.host_granule_bytes.max(summary.host_granule_bytes);
                total.host_granules += summary.host_granules;
                total.resident_bytes += summary.resident_bytes;
                total.guest_owned_bytes += summary.guest_owned_bytes;
                total.pinned_bytes += summary.pinned_bytes;
                total.balloon_owned_bytes += summary.balloon_owned_bytes;
                total.report_inflight_bytes += summary.report_inflight_bytes;
                total.discarded_soft_bytes += summary.discarded_soft_bytes;
                total.discarded_hard_zero_bytes += summary.discarded_hard_zero_bytes;
                total.cumulative_soft_discarded_bytes += summary.cumulative_soft_discarded_bytes;
                total.cumulative_hard_decommitted_bytes +=
                    summary.cumulative_hard_decommitted_bytes;
                total.cumulative_balloon_authorized_bytes +=
                    summary.cumulative_balloon_authorized_bytes;
                total.cumulative_report_authorized_bytes +=
                    summary.cumulative_report_authorized_bytes;
                total.guest_owned_reclaimed_bytes += summary.guest_owned_reclaimed_bytes;
                total.pinned_reclaimed_bytes += summary.pinned_reclaimed_bytes;
                total.reclaim_without_authority_bytes += summary.reclaim_without_authority_bytes;
                total.report_acked_before_reclaim_bytes +=
                    summary.report_acked_before_reclaim_bytes;
                total.state_sum_mismatch_bytes += summary.state_sum_mismatch_bytes;
                total.ok = total.guest_owned_reclaimed_bytes == 0
                    && total.pinned_reclaimed_bytes == 0
                    && total.reclaim_without_authority_bytes == 0
                    && total.report_acked_before_reclaim_bytes == 0
                    && total.state_sum_mismatch_bytes == 0;
                total
            })
    }
}

#[derive(Debug, Clone, Default)]
pub struct DockerPhaseMetrics {
    pub total: u64,
    pub request: u64,
    pub response: u64,
    pub completed_streams: u64,
    pub completed_workload_streams: u64,
    pub request_bytes: u64,
    pub response_bytes: u64,
}
