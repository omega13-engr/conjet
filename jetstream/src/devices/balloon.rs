use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{read_descriptors, QueueError, SplitQueueExecutor, UsedElement};
use crate::vmm::memory::{GuestMemory, GuestMemoryError};

pub const BALLOON_FEATURE_STATS: u64 = 1 << 1;
pub const BALLOON_FEATURE_FREE_PAGE_HINT: u64 = 1 << 3;
pub const BALLOON_FEATURE_PAGE_REPORTING: u64 = 1 << 5;
const PAGE_SIZE: u64 = 4096;
const QUEUE_LIMIT: usize = 128;
const FREE_PAGE_HINT_CMD_ID_OFFSET: usize = 8;
const FREE_PAGE_HINT_CMD_ID_STOP: u32 = 0;
const FREE_PAGE_HINT_CMD_ID_DONE: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BalloonQueue {
    Inflate = 0,
    Deflate = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct BalloonQueueLayout {
    inflate: u32,
    deflate: u32,
    stats: Option<u32>,
    free_page_hint: Option<u32>,
    reporting: Option<u32>,
}

impl BalloonQueueLayout {
    fn from_transport(transport: &VirtioMmioDevice) -> Self {
        let features = if transport.features_ok() {
            transport.plan.features & transport.driver_features
        } else {
            transport.plan.features
        };
        Self::from_features(features)
    }

    fn from_features(features: u64) -> Self {
        let mut next = 2u32;
        let stats = allocate_optional_queue(features, BALLOON_FEATURE_STATS, &mut next);
        let free_page_hint =
            allocate_optional_queue(features, BALLOON_FEATURE_FREE_PAGE_HINT, &mut next);
        let reporting =
            allocate_optional_queue(features, BALLOON_FEATURE_PAGE_REPORTING, &mut next);
        Self {
            inflate: BalloonQueue::Inflate as u32,
            deflate: BalloonQueue::Deflate as u32,
            stats,
            free_page_hint,
            reporting,
        }
    }
}

fn allocate_optional_queue(features: u64, feature: u64, next: &mut u32) -> Option<u32> {
    if features & feature == 0 {
        return None;
    }
    let queue = *next;
    *next = (*next).saturating_add(1);
    Some(queue)
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct BalloonMetrics {
    pub offered_features: u64,
    pub driver_features: u64,
    pub driver_ok: bool,
    pub features_ok: bool,
    pub page_reporting_negotiated: bool,
    pub reporting_queue_index: Option<u32>,
    pub reporting_queue_ready: bool,
    pub queue_ready: [bool; 5],
    pub queue_size: [u32; 5],
    pub queue_descriptor_address: [u64; 5],
    pub queue_driver_address: [u64; 5],
    pub queue_device_address: [u64; 5],
    pub reporting_guard_blocked_notifications: u64,
    pub reporting_notifications: u64,
    pub reporting_queue_notifications: u64,
    pub reporting_queue_acknowledgements: u64,
    pub reporting_queue_pending_descriptors: u64,
    pub free_page_hint_negotiated: bool,
    pub free_page_hint_queue_index: Option<u32>,
    pub free_page_hint_queue_ready: bool,
    pub free_page_hint_notifications: u64,
    pub free_page_hint_reported_bytes: u64,
    pub free_page_hint_reclaimed_bytes: u64,
    pub free_page_hint_cmd_id: u32,
    pub actual_pages: u64,
    pub inflate_pages: u64,
    pub deflate_pages: u64,
    pub reported_free_pages: u64,
    pub reported_free_bytes: u64,
    pub host_granule_eligible_bytes: u64,
    pub discard_advised_bytes: u64,
    pub discard_failed_bytes: u64,
    pub discard_skipped_bytes: u64,
    pub partial_host_granule_bytes: u64,
    pub soft_reclaimed_bytes: u64,
    pub hard_decommitted_bytes: u64,
    pub balloon_owned_reclaimed_bytes: u64,
    pub report_inflight_reclaimed_bytes: u64,
    pub reclaimed_bytes: u64,
    pub reported_free_reclaimed_bytes: u64,
    pub current_balloon_owned_bytes: u64,
    pub current_fully_owned_host_granules: u64,
    pub current_partially_owned_host_granules: u64,
    pub current_balloon_decommitted_bytes: u64,
    pub reclaim_failures: u64,
    pub malformed_reports: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct MemoryLedgerSummary {
    pub guest_visible_bytes: u64,
    pub host_granule_bytes: u64,
    pub host_granules: u64,
    pub resident_bytes: u64,
    pub guest_owned_bytes: u64,
    pub pinned_bytes: u64,
    pub balloon_owned_bytes: u64,
    pub report_inflight_bytes: u64,
    pub discarded_soft_bytes: u64,
    pub discarded_hard_zero_bytes: u64,
    pub cumulative_soft_discarded_bytes: u64,
    pub cumulative_hard_decommitted_bytes: u64,
    pub cumulative_balloon_authorized_bytes: u64,
    pub cumulative_report_authorized_bytes: u64,
    pub guest_owned_reclaimed_bytes: u64,
    pub pinned_reclaimed_bytes: u64,
    pub reclaim_without_authority_bytes: u64,
    pub report_acked_before_reclaim_bytes: u64,
    pub state_sum_mismatch_bytes: u64,
    pub ok: bool,
}

impl MemoryLedgerSummary {
    fn with_ok(mut self) -> Self {
        self.ok = self.guest_owned_reclaimed_bytes == 0
            && self.pinned_reclaimed_bytes == 0
            && self.reclaim_without_authority_bytes == 0
            && self.report_acked_before_reclaim_bytes == 0
            && self.state_sum_mismatch_bytes == 0;
        self
    }
}

#[derive(Debug, Error)]
pub enum BalloonError {
    #[error("virtio-balloon PFN descriptor length is not aligned to 4 bytes")]
    MisalignedPfnDescriptor,
    #[error("free-page report descriptor is not aligned to the 4 KiB balloon unit")]
    MisalignedFreePageReport,
    #[error("free-page report descriptor address overflows")]
    FreePageReportOverflow,
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error(transparent)]
    Memory(#[from] GuestMemoryError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub struct PageRange {
    pub start: u64,
    pub size: u64,
}

impl PageRange {
    fn end(self) -> Option<u64> {
        self.start.checked_add(self.size)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReclaimReport {
    pub host_granule_eligible_bytes: u64,
    pub discard_advised_bytes: u64,
    pub soft_reclaimed_bytes: u64,
    pub hard_decommitted_bytes: u64,
    pub discard_failed_bytes: u64,
    pub discard_skipped_bytes: u64,
    pub partial_host_granule_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReclaimAuthority {
    BalloonOwned,
    ReportInFlight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LedgerAuthority {
    GuestOwned,
    #[allow(dead_code)]
    Pinned,
    BalloonOwned,
    ReportInFlight,
}

impl From<ReclaimAuthority> for LedgerAuthority {
    fn from(authority: ReclaimAuthority) -> Self {
        match authority {
            ReclaimAuthority::BalloonOwned => Self::BalloonOwned,
            ReclaimAuthority::ReportInFlight => Self::ReportInFlight,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BackingState {
    Resident,
    SoftDiscarded,
    HardDecommittedZero,
}

#[derive(Debug, Clone, Copy)]
struct HostPageLedgerEntry {
    authority: LedgerAuthority,
    backing: BackingState,
    last_reclaim_authority: LedgerAuthority,
}

impl Default for HostPageLedgerEntry {
    fn default() -> Self {
        Self {
            authority: LedgerAuthority::GuestOwned,
            backing: BackingState::Resident,
            last_reclaim_authority: LedgerAuthority::GuestOwned,
        }
    }
}

#[derive(Debug, Default)]
struct MemoryLedger {
    guest_base: u64,
    guest_size: u64,
    host_page_size: u64,
    entries: Vec<HostPageLedgerEntry>,
    cumulative_soft_discarded_bytes: u64,
    cumulative_hard_decommitted_bytes: u64,
    cumulative_balloon_authorized_bytes: u64,
    cumulative_report_authorized_bytes: u64,
    guest_owned_reclaimed_bytes: u64,
    pinned_reclaimed_bytes: u64,
    reclaim_without_authority_bytes: u64,
    report_acked_before_reclaim_bytes: u64,
}

impl MemoryLedger {
    fn ensure(&mut self, memory: &GuestMemory, guest_base: u64) {
        let guest_size = memory.len() as u64;
        let host_page_size = memory.host_page_size() as u64;
        if self.guest_base == guest_base
            && self.guest_size == guest_size
            && self.host_page_size == host_page_size
            && !self.entries.is_empty()
        {
            return;
        }
        let entry_count = guest_size.div_ceil(host_page_size) as usize;
        self.guest_base = guest_base;
        self.guest_size = guest_size;
        self.host_page_size = host_page_size;
        self.entries = vec![HostPageLedgerEntry::default(); entry_count];
        self.cumulative_soft_discarded_bytes = 0;
        self.cumulative_hard_decommitted_bytes = 0;
        self.cumulative_balloon_authorized_bytes = 0;
        self.cumulative_report_authorized_bytes = 0;
        self.guest_owned_reclaimed_bytes = 0;
        self.pinned_reclaimed_bytes = 0;
        self.reclaim_without_authority_bytes = 0;
        self.report_acked_before_reclaim_bytes = 0;
    }

    fn mark_authority(&mut self, ranges: &[PageRange], authority: LedgerAuthority) {
        for index in self.indices_for_ranges(ranges) {
            self.entries[index].authority = authority;
        }
    }

    fn clear_report_inflight(&mut self, ranges: &[PageRange]) {
        for index in self.indices_for_ranges(ranges) {
            let entry = &mut self.entries[index];
            if entry.authority == LedgerAuthority::ReportInFlight {
                if entry.backing == BackingState::Resident {
                    self.report_acked_before_reclaim_bytes = self
                        .report_acked_before_reclaim_bytes
                        .saturating_add(self.host_page_size);
                }
                entry.authority = LedgerAuthority::GuestOwned;
            }
        }
    }

    fn mark_guest_owned(&mut self, ranges: &[PageRange]) {
        for index in self.indices_for_ranges(ranges) {
            self.entries[index].authority = LedgerAuthority::GuestOwned;
        }
    }

    fn apply_reclaim(
        &mut self,
        ranges: &[PageRange],
        report: &ReclaimReport,
        authority: ReclaimAuthority,
    ) {
        let ledger_authority = LedgerAuthority::from(authority);
        let mut soft_remaining = report.soft_reclaimed_bytes;
        let mut hard_remaining = report.hard_decommitted_bytes;
        for index in self.indices_for_ranges(ranges) {
            if hard_remaining < self.host_page_size && soft_remaining < self.host_page_size {
                break;
            }
            let entry = &mut self.entries[index];
            if entry.authority != ledger_authority {
                self.reclaim_without_authority_bytes = self
                    .reclaim_without_authority_bytes
                    .saturating_add(self.host_page_size);
                match entry.authority {
                    LedgerAuthority::GuestOwned => {
                        self.guest_owned_reclaimed_bytes = self
                            .guest_owned_reclaimed_bytes
                            .saturating_add(self.host_page_size);
                    }
                    LedgerAuthority::Pinned => {
                        self.pinned_reclaimed_bytes = self
                            .pinned_reclaimed_bytes
                            .saturating_add(self.host_page_size);
                    }
                    LedgerAuthority::BalloonOwned | LedgerAuthority::ReportInFlight => {}
                }
            }
            if hard_remaining >= self.host_page_size {
                entry.backing = BackingState::HardDecommittedZero;
                entry.last_reclaim_authority = ledger_authority;
                self.cumulative_hard_decommitted_bytes = self
                    .cumulative_hard_decommitted_bytes
                    .saturating_add(self.host_page_size);
                match authority {
                    ReclaimAuthority::BalloonOwned => {
                        self.cumulative_balloon_authorized_bytes = self
                            .cumulative_balloon_authorized_bytes
                            .saturating_add(self.host_page_size);
                    }
                    ReclaimAuthority::ReportInFlight => {
                        self.cumulative_report_authorized_bytes = self
                            .cumulative_report_authorized_bytes
                            .saturating_add(self.host_page_size);
                    }
                }
                hard_remaining -= self.host_page_size;
            } else if soft_remaining >= self.host_page_size {
                entry.backing = BackingState::SoftDiscarded;
                entry.last_reclaim_authority = ledger_authority;
                self.cumulative_soft_discarded_bytes = self
                    .cumulative_soft_discarded_bytes
                    .saturating_add(self.host_page_size);
                match authority {
                    ReclaimAuthority::BalloonOwned => {
                        self.cumulative_balloon_authorized_bytes = self
                            .cumulative_balloon_authorized_bytes
                            .saturating_add(self.host_page_size);
                    }
                    ReclaimAuthority::ReportInFlight => {
                        self.cumulative_report_authorized_bytes = self
                            .cumulative_report_authorized_bytes
                            .saturating_add(self.host_page_size);
                    }
                }
                soft_remaining -= self.host_page_size;
            }
        }
    }

    fn summary(&self, guest_size: u64, host_page_size: u64) -> MemoryLedgerSummary {
        let guest_visible_bytes = if self.guest_size == 0 {
            guest_size
        } else {
            self.guest_size
        };
        let host_granule_bytes = if self.host_page_size == 0 {
            host_page_size
        } else {
            self.host_page_size
        };
        if self.entries.is_empty() {
            return MemoryLedgerSummary {
                guest_visible_bytes,
                host_granule_bytes,
                host_granules: guest_visible_bytes.div_ceil(host_granule_bytes),
                resident_bytes: guest_visible_bytes,
                guest_owned_bytes: guest_visible_bytes,
                ..MemoryLedgerSummary::default()
            }
            .with_ok();
        }

        let mut summary = MemoryLedgerSummary {
            guest_visible_bytes,
            host_granule_bytes,
            host_granules: self.entries.len() as u64,
            cumulative_soft_discarded_bytes: self.cumulative_soft_discarded_bytes,
            cumulative_hard_decommitted_bytes: self.cumulative_hard_decommitted_bytes,
            cumulative_balloon_authorized_bytes: self.cumulative_balloon_authorized_bytes,
            cumulative_report_authorized_bytes: self.cumulative_report_authorized_bytes,
            guest_owned_reclaimed_bytes: self.guest_owned_reclaimed_bytes,
            pinned_reclaimed_bytes: self.pinned_reclaimed_bytes,
            reclaim_without_authority_bytes: self.reclaim_without_authority_bytes,
            report_acked_before_reclaim_bytes: self.report_acked_before_reclaim_bytes,
            ..MemoryLedgerSummary::default()
        };
        for entry in &self.entries {
            match entry.authority {
                LedgerAuthority::GuestOwned => summary.guest_owned_bytes += host_granule_bytes,
                LedgerAuthority::Pinned => summary.pinned_bytes += host_granule_bytes,
                LedgerAuthority::BalloonOwned => summary.balloon_owned_bytes += host_granule_bytes,
                LedgerAuthority::ReportInFlight => {
                    summary.report_inflight_bytes += host_granule_bytes;
                }
            }
            match entry.backing {
                BackingState::Resident => summary.resident_bytes += host_granule_bytes,
                BackingState::SoftDiscarded => {
                    summary.discarded_soft_bytes += host_granule_bytes;
                }
                BackingState::HardDecommittedZero => {
                    summary.discarded_hard_zero_bytes += host_granule_bytes;
                }
            }
        }
        let state_sum = summary
            .resident_bytes
            .saturating_add(summary.discarded_soft_bytes)
            .saturating_add(summary.discarded_hard_zero_bytes);
        summary.state_sum_mismatch_bytes = state_sum.abs_diff(guest_visible_bytes);
        summary.with_ok()
    }

    fn indices_for_ranges(&self, ranges: &[PageRange]) -> Vec<usize> {
        let mut indices = Vec::new();
        if self.host_page_size == 0 {
            return indices;
        }
        for range in ranges {
            let Some(end) = range.end() else {
                continue;
            };
            let Some(start_offset) = range.start.checked_sub(self.guest_base) else {
                continue;
            };
            let Some(end_offset) = end.checked_sub(self.guest_base) else {
                continue;
            };
            let start_index = start_offset / self.host_page_size;
            let end_index = end_offset.div_ceil(self.host_page_size);
            for index in start_index..end_index {
                if let Ok(index) = usize::try_from(index) {
                    if index < self.entries.len() {
                        indices.push(index);
                    }
                }
            }
        }
        indices.sort_unstable();
        indices.dedup();
        indices
    }
}

pub trait GuestMemoryReclaimer: std::fmt::Debug + Send + Sync {
    fn reclaim_ranges(
        &self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: &[PageRange],
        authority: ReclaimAuthority,
    ) -> ReclaimReport;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HostGranuleOwnership {
    ballooned_subpages: u128,
    required_subpages: u8,
    decommitted: bool,
}

impl HostGranuleOwnership {
    fn new(required_subpages: u8) -> Self {
        Self {
            ballooned_subpages: 0,
            required_subpages,
            decommitted: false,
        }
    }

    fn required_mask(self) -> u128 {
        if self.required_subpages >= u128::BITS as u8 {
            u128::MAX
        } else {
            (1u128 << self.required_subpages) - 1
        }
    }

    fn fully_owned(self) -> bool {
        self.ballooned_subpages == self.required_mask()
    }

    fn host_granule_bytes(self) -> u64 {
        u64::from(self.required_subpages) * PAGE_SIZE
    }
}

#[derive(Debug, Default)]
pub struct BalloonQueueHandler {
    inflate_executor: SplitQueueExecutor,
    deflate_executor: SplitQueueExecutor,
    free_page_hint_executor: SplitQueueExecutor,
    reporting_executor: SplitQueueExecutor,
    ballooned_pfns: HashSet<u64>,
    balloon_host_granules: HashMap<u64, HostGranuleOwnership>,
    free_page_hint_active_cmd_id: Option<u32>,
    memory_ledger: MemoryLedger,
    metrics: BalloonMetrics,
    reclaimer: Option<Arc<dyn GuestMemoryReclaimer>>,
}

impl BalloonQueueHandler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_reclaimer(reclaimer: Arc<dyn GuestMemoryReclaimer>) -> Self {
        Self {
            reclaimer: Some(reclaimer),
            ..Self::default()
        }
    }

    pub fn metrics(&self) -> BalloonMetrics {
        let mut metrics = self.metrics;
        metrics.actual_pages = self.ballooned_pfns.len() as u64;
        metrics.current_balloon_owned_bytes = metrics.actual_pages.saturating_mul(PAGE_SIZE);
        metrics.current_fully_owned_host_granules = self
            .balloon_host_granules
            .values()
            .filter(|ownership| ownership.fully_owned())
            .count() as u64;
        metrics.current_partially_owned_host_granules = self
            .balloon_host_granules
            .values()
            .filter(|ownership| ownership.ballooned_subpages != 0 && !ownership.fully_owned())
            .count() as u64;
        metrics.current_balloon_decommitted_bytes = self
            .balloon_host_granules
            .values()
            .filter(|ownership| ownership.decommitted)
            .map(|ownership| ownership.host_granule_bytes())
            .sum();
        metrics
    }

    pub fn memory_ledger_summary(
        &self,
        guest_size: u64,
        host_page_size: u64,
    ) -> MemoryLedgerSummary {
        self.memory_ledger.summary(guest_size, host_page_size)
    }

    pub fn refresh_transport_metrics(&mut self, transport: &VirtioMmioDevice) {
        self.record_transport_state(transport);
    }

    pub fn handle_available(
        &mut self,
        queue: VirtioQueueState,
        queue_index: u32,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, BalloonError> {
        self.record_transport_state(transport);
        let layout = BalloonQueueLayout::from_transport(transport);
        match queue_index {
            x if x == layout.inflate => {
                self.handle_pfn_queue(queue, transport, memory, guest_base, true)
            }
            x if x == layout.deflate => {
                self.handle_pfn_queue(queue, transport, memory, guest_base, false)
            }
            x if Some(x) == layout.reporting => {
                self.handle_reporting_queue(queue, queue_index, transport, memory, guest_base)
            }
            x if Some(x) == layout.free_page_hint => {
                self.handle_free_page_hint_queue(queue, queue_index, transport, memory, guest_base)
            }
            _ => Ok(Vec::new()),
        }
    }

    fn handle_pfn_queue(
        &mut self,
        queue: VirtioQueueState,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
        inflate: bool,
    ) -> Result<Vec<UsedElement>, BalloonError> {
        let chains = {
            let executor = if inflate {
                &mut self.inflate_executor
            } else {
                &mut self.deflate_executor
            };
            executor.drain_available_chains(queue, memory, guest_base, Some(QUEUE_LIMIT))?
        };
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        let mut used = Vec::with_capacity(chains.len());
        for chain in &chains {
            let pfns = match read_pfns(chain, memory, guest_base) {
                Ok(pfns) => pfns,
                Err(error) => {
                    self.metrics.malformed_reports += 1;
                    if matches!(error, BalloonError::MisalignedPfnDescriptor) {
                        used.push(UsedElement {
                            id: u32::from(chain.head_index),
                            length: 0,
                        });
                        continue;
                    }
                    return Err(error);
                }
            };
            if inflate {
                self.metrics.inflate_pages += pfns.len() as u64;
                let reclaim_ranges = self.record_balloon_inflate(memory, guest_base, &pfns);
                self.reclaim_balloon_owned_ranges(memory, guest_base, reclaim_ranges);
            } else {
                self.metrics.deflate_pages += pfns.len() as u64;
                self.record_balloon_deflate(memory, guest_base, &pfns);
            }
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: 0,
            });
        }

        {
            let executor = if inflate {
                &mut self.inflate_executor
            } else {
                &mut self.deflate_executor
            };
            executor.publish_used(queue, transport, memory, guest_base, &used)?;
        }
        update_actual_pages_config(transport, self.ballooned_pfns.len() as u32);
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }

    fn record_balloon_inflate(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        pfns: &[u64],
    ) -> Vec<PageRange> {
        let mut candidates = Vec::new();
        self.memory_ledger.ensure(memory, guest_base);
        for &pfn in pfns {
            let Some((granule_start, subpage_mask, required_subpages)) =
                host_granule_for_pfn(memory, guest_base, pfn)
            else {
                self.metrics.reclaim_failures += 1;
                continue;
            };
            self.ballooned_pfns.insert(pfn);
            let ownership = self
                .balloon_host_granules
                .entry(granule_start)
                .or_insert_with(|| HostGranuleOwnership::new(required_subpages));
            ownership.ballooned_subpages |= subpage_mask;
            if ownership.fully_owned() && !ownership.decommitted {
                candidates.push(PageRange {
                    start: granule_start,
                    size: ownership.host_granule_bytes(),
                });
            }
        }
        coalesce_ranges(candidates)
    }

    fn reclaim_balloon_owned_ranges(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: Vec<PageRange>,
    ) {
        for range in ranges {
            let eligible_ranges =
                eligible_reclaim_ranges(memory, guest_base, std::slice::from_ref(&range));
            self.memory_ledger
                .mark_authority(&eligible_ranges, LedgerAuthority::BalloonOwned);
            let report = reclaim_ranges(
                memory,
                guest_base,
                vec![range],
                self.reclaimer.as_deref(),
                ReclaimAuthority::BalloonOwned,
            );
            let reclaimed = report.discard_advised_bytes == range.size;
            self.memory_ledger.apply_reclaim(
                &eligible_ranges,
                &report,
                ReclaimAuthority::BalloonOwned,
            );
            self.record_reclaim_report(report, ReclaimAuthority::BalloonOwned, false);
            if reclaimed {
                self.mark_balloon_range_decommitted(range);
            }
        }
    }

    fn mark_balloon_range_decommitted(&mut self, range: PageRange) {
        let Some(end) = range.end() else {
            return;
        };
        let mut granule_start = range.start;
        while granule_start < end {
            let step = if let Some(ownership) = self.balloon_host_granules.get_mut(&granule_start) {
                ownership.decommitted = true;
                ownership.host_granule_bytes()
            } else {
                PAGE_SIZE
            };
            if step == 0 {
                break;
            }
            granule_start = granule_start.saturating_add(step);
        }
    }

    fn record_balloon_deflate(&mut self, memory: &GuestMemory, guest_base: u64, pfns: &[u64]) {
        self.memory_ledger.ensure(memory, guest_base);
        let mut guest_owned_ranges = Vec::new();
        for &pfn in pfns {
            if !self.ballooned_pfns.remove(&pfn) {
                continue;
            }
            let Some((granule_start, subpage_mask, _)) =
                host_granule_for_pfn(memory, guest_base, pfn)
            else {
                continue;
            };
            let mut remove_granule = false;
            if let Some(ownership) = self.balloon_host_granules.get_mut(&granule_start) {
                ownership.ballooned_subpages &= !subpage_mask;
                ownership.decommitted = false;
                remove_granule = ownership.ballooned_subpages == 0;
            }
            if remove_granule {
                self.balloon_host_granules.remove(&granule_start);
            }
            guest_owned_ranges.push(PageRange {
                start: pfn.saturating_mul(PAGE_SIZE),
                size: PAGE_SIZE,
            });
        }
        let guest_owned_ranges = eligible_reclaim_ranges(memory, guest_base, &guest_owned_ranges);
        self.memory_ledger.mark_guest_owned(&guest_owned_ranges);
    }

    fn handle_reporting_queue(
        &mut self,
        queue: VirtioQueueState,
        queue_index: u32,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, BalloonError> {
        self.metrics.reporting_notifications += 1;
        self.metrics.reporting_queue_notifications += 1;
        self.metrics.reporting_queue_index = Some(queue_index);
        if !transport.driver_ok()
            || !transport.features_ok()
            || !transport.negotiated(BALLOON_FEATURE_PAGE_REPORTING)
            || !transport.queue_ready(queue_index)
        {
            self.metrics.reporting_guard_blocked_notifications += 1;
            return Ok(Vec::new());
        }
        let chains = self.reporting_executor.drain_available_chains(
            queue,
            memory,
            guest_base,
            Some(QUEUE_LIMIT),
        )?;
        self.metrics.reporting_queue_pending_descriptors = chains.len() as u64;
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        let mut used = Vec::with_capacity(chains.len());
        let mut batch_ranges = Vec::new();
        let mut batch_reported = 0u64;
        for chain in &chains {
            let writable = chain.writable_descriptors().copied().collect::<Vec<_>>();
            if writable.is_empty() {
                self.metrics.malformed_reports += 1;
            }
            match page_ranges_from_reporting_descriptors(&writable, memory, guest_base) {
                Ok(ranges) => {
                    batch_reported += ranges.iter().map(|range| range.size).sum::<u64>();
                    batch_ranges.extend(ranges);
                }
                Err(_) => {
                    self.metrics.malformed_reports += 1;
                }
            }
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: 0,
            });
        }
        if !batch_ranges.is_empty() {
            self.reclaim_report_inflight_ranges(memory, guest_base, batch_ranges, batch_reported);
        }

        self.reporting_executor
            .publish_used(queue, transport, memory, guest_base, &used)?;
        self.metrics.reporting_queue_acknowledgements += used.len() as u64;
        self.metrics.reporting_queue_pending_descriptors = 0;
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }

    fn reclaim_report_inflight_ranges(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        batch_ranges: Vec<PageRange>,
        batch_reported: u64,
    ) {
        self.memory_ledger.ensure(memory, guest_base);
        let eligible_ranges = eligible_reclaim_ranges(memory, guest_base, &batch_ranges);
        self.memory_ledger
            .mark_authority(&eligible_ranges, LedgerAuthority::ReportInFlight);
        let report = reclaim_ranges(
            memory,
            guest_base,
            batch_ranges,
            self.reclaimer.as_deref(),
            ReclaimAuthority::ReportInFlight,
        );
        self.memory_ledger.apply_reclaim(
            &eligible_ranges,
            &report,
            ReclaimAuthority::ReportInFlight,
        );
        self.memory_ledger.clear_report_inflight(&eligible_ranges);
        self.metrics.reported_free_pages += batch_reported / PAGE_SIZE;
        self.metrics.reported_free_bytes += batch_reported;
        self.record_reclaim_report(report, ReclaimAuthority::ReportInFlight, true);
    }

    fn handle_free_page_hint_queue(
        &mut self,
        queue: VirtioQueueState,
        queue_index: u32,
        transport: &mut VirtioMmioDevice,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> Result<Vec<UsedElement>, BalloonError> {
        self.metrics.free_page_hint_notifications += 1;
        self.metrics.free_page_hint_queue_index = Some(queue_index);
        if !transport.driver_ok()
            || !transport.features_ok()
            || !transport.negotiated(BALLOON_FEATURE_FREE_PAGE_HINT)
            || !transport.queue_ready(queue_index)
        {
            return Ok(Vec::new());
        }
        let chains = self.free_page_hint_executor.drain_available_chains(
            queue,
            memory,
            guest_base,
            Some(QUEUE_LIMIT),
        )?;
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        let mut used = Vec::with_capacity(chains.len());
        let mut batch_ranges = Vec::new();
        let mut batch_reported = 0u64;
        for chain in &chains {
            let readable = chain.readable_descriptors().copied().collect::<Vec<_>>();
            if !readable.is_empty() {
                match read_free_page_hint_cmd_id(&readable, memory, guest_base) {
                    Ok(FREE_PAGE_HINT_CMD_ID_STOP) | Ok(FREE_PAGE_HINT_CMD_ID_DONE) => {
                        let completed_active_command =
                            self.free_page_hint_active_cmd_id.take().is_some();
                        self.free_page_hint_active_cmd_id = None;
                        if completed_active_command {
                            set_free_page_hint_cmd_id(transport, FREE_PAGE_HINT_CMD_ID_DONE);
                        }
                    }
                    Ok(cmd_id) => {
                        self.free_page_hint_active_cmd_id = Some(cmd_id);
                    }
                    Err(_) => {
                        self.metrics.malformed_reports += 1;
                    }
                }
            }
            let writable = chain.writable_descriptors().copied().collect::<Vec<_>>();
            if !writable.is_empty() && self.free_page_hint_active_cmd_id.is_some() {
                match page_ranges_from_reporting_descriptors(&writable, memory, guest_base) {
                    Ok(ranges) => {
                        batch_reported += ranges.iter().map(|range| range.size).sum::<u64>();
                        batch_ranges.extend(ranges);
                    }
                    Err(_) => {
                        self.metrics.malformed_reports += 1;
                    }
                }
            }
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: 0,
            });
        }
        if !batch_ranges.is_empty() {
            self.reclaim_free_page_hint_ranges(memory, guest_base, batch_ranges, batch_reported);
        }

        self.free_page_hint_executor
            .publish_used(queue, transport, memory, guest_base, &used)?;
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }

    fn reclaim_free_page_hint_ranges(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        batch_ranges: Vec<PageRange>,
        batch_reported: u64,
    ) {
        self.memory_ledger.ensure(memory, guest_base);
        let eligible_ranges = eligible_reclaim_ranges(memory, guest_base, &batch_ranges);
        self.memory_ledger
            .mark_authority(&eligible_ranges, LedgerAuthority::ReportInFlight);
        let report = reclaim_ranges(
            memory,
            guest_base,
            batch_ranges,
            self.reclaimer.as_deref(),
            ReclaimAuthority::ReportInFlight,
        );
        self.memory_ledger.apply_reclaim(
            &eligible_ranges,
            &report,
            ReclaimAuthority::ReportInFlight,
        );
        self.memory_ledger.clear_report_inflight(&eligible_ranges);
        self.metrics.free_page_hint_reported_bytes += batch_reported;
        self.metrics.free_page_hint_reclaimed_bytes += report.discard_advised_bytes;
        self.record_reclaim_report(report, ReclaimAuthority::ReportInFlight, false);
    }

    fn record_reclaim_report(
        &mut self,
        report: ReclaimReport,
        authority: ReclaimAuthority,
        page_reporting: bool,
    ) {
        self.metrics.host_granule_eligible_bytes += report.host_granule_eligible_bytes;
        self.metrics.discard_advised_bytes += report.discard_advised_bytes;
        self.metrics.soft_reclaimed_bytes += report.soft_reclaimed_bytes;
        self.metrics.hard_decommitted_bytes += report.hard_decommitted_bytes;
        self.metrics.discard_failed_bytes += report.discard_failed_bytes;
        self.metrics.discard_skipped_bytes += report.discard_skipped_bytes;
        self.metrics.partial_host_granule_bytes += report.partial_host_granule_bytes;
        self.metrics.reclaimed_bytes += report.discard_advised_bytes;
        match authority {
            ReclaimAuthority::BalloonOwned => {
                self.metrics.balloon_owned_reclaimed_bytes += report.discard_advised_bytes;
            }
            ReclaimAuthority::ReportInFlight => {
                self.metrics.report_inflight_reclaimed_bytes += report.discard_advised_bytes;
            }
        }
        if page_reporting {
            self.metrics.reported_free_reclaimed_bytes += report.discard_advised_bytes;
        }
        if report.discard_failed_bytes > 0 {
            self.metrics.reclaim_failures += 1;
        }
    }

    fn record_transport_state(&mut self, transport: &VirtioMmioDevice) {
        self.metrics.offered_features = transport.plan.features;
        self.metrics.driver_features = transport.driver_features;
        self.metrics.driver_ok = transport.driver_ok();
        self.metrics.features_ok = transport.features_ok();
        let layout = BalloonQueueLayout::from_transport(transport);
        self.metrics.page_reporting_negotiated =
            transport.negotiated(BALLOON_FEATURE_PAGE_REPORTING);
        self.metrics.reporting_queue_index = layout.reporting;
        self.metrics.reporting_queue_ready = layout
            .reporting
            .is_some_and(|index| transport.queue_ready(index));
        for index in 0..self.metrics.queue_ready.len() {
            if let Some(queue) = transport.queue_state(index as u32) {
                self.metrics.queue_ready[index] = queue.ready;
                self.metrics.queue_size[index] = queue.size;
                self.metrics.queue_descriptor_address[index] = queue.descriptor_address;
                self.metrics.queue_driver_address[index] = queue.driver_address;
                self.metrics.queue_device_address[index] = queue.device_address;
            }
        }
        self.metrics.free_page_hint_negotiated =
            transport.negotiated(BALLOON_FEATURE_FREE_PAGE_HINT);
        self.metrics.free_page_hint_queue_index = layout.free_page_hint;
        self.metrics.free_page_hint_queue_ready = layout
            .free_page_hint
            .is_some_and(|index| transport.queue_ready(index));
        let config = transport.configuration_bytes();
        if config.len() >= FREE_PAGE_HINT_CMD_ID_OFFSET + 4 {
            self.metrics.free_page_hint_cmd_id = u32::from_le_bytes(
                config[FREE_PAGE_HINT_CMD_ID_OFFSET..FREE_PAGE_HINT_CMD_ID_OFFSET + 4]
                    .try_into()
                    .expect("free page hint command id field is 4 bytes"),
            );
        }
    }
}

fn set_free_page_hint_cmd_id(transport: &mut VirtioMmioDevice, cmd_id: u32) {
    let mut config = transport.configuration_bytes().to_vec();
    if config.len() < 16 {
        config.resize(16, 0);
    }
    config[FREE_PAGE_HINT_CMD_ID_OFFSET..FREE_PAGE_HINT_CMD_ID_OFFSET + 4]
        .copy_from_slice(&cmd_id.to_le_bytes());
    transport.update_configuration(config, true);
}

pub fn configuration(target_pages: u32, actual_pages: u32, free_page_hint_cmd_id: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(&target_pages.to_le_bytes());
    out.extend_from_slice(&actual_pages.to_le_bytes());
    out.extend_from_slice(&free_page_hint_cmd_id.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}

fn read_pfns(
    chain: &crate::devices::virtqueue::DescriptorChain,
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<Vec<u64>, BalloonError> {
    let descriptors = chain.readable_descriptors().copied().collect::<Vec<_>>();
    if descriptors
        .iter()
        .any(|descriptor| descriptor.length % 4 != 0)
    {
        return Err(BalloonError::MisalignedPfnDescriptor);
    }
    let bytes = read_descriptors(memory, guest_base, descriptors)?;
    let mut pfns = Vec::with_capacity(bytes.len() / 4);
    for chunk in bytes.chunks_exact(4) {
        pfns.push(u64::from(u32::from_le_bytes(
            chunk.try_into().expect("PFN chunk has 4 bytes"),
        )));
    }
    Ok(pfns)
}

fn read_free_page_hint_cmd_id(
    descriptors: &[crate::devices::virtqueue::QueueDescriptor],
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<u32, BalloonError> {
    let bytes = read_descriptors(memory, guest_base, descriptors.iter().copied())?;
    if bytes.len() != std::mem::size_of::<u32>() {
        return Err(BalloonError::MisalignedPfnDescriptor);
    }
    Ok(u32::from_le_bytes(
        bytes
            .try_into()
            .expect("free-page hint command id has 4 bytes"),
    ))
}

fn page_ranges_from_reporting_descriptors(
    descriptors: &[crate::devices::virtqueue::QueueDescriptor],
    memory: &GuestMemory,
    guest_base: u64,
) -> Result<Vec<PageRange>, BalloonError> {
    let mut ranges = Vec::with_capacity(descriptors.len());
    for descriptor in descriptors {
        if descriptor.length == 0 {
            continue;
        }
        if descriptor.address % PAGE_SIZE != 0 || u64::from(descriptor.length) % PAGE_SIZE != 0 {
            return Err(BalloonError::MisalignedFreePageReport);
        }
        let end = descriptor
            .address
            .checked_add(u64::from(descriptor.length))
            .ok_or(BalloonError::FreePageReportOverflow)?;
        memory.host_address_at(guest_base, descriptor.address, descriptor.length as usize)?;
        if end == descriptor.address {
            continue;
        }
        ranges.push(PageRange {
            start: descriptor.address,
            size: u64::from(descriptor.length),
        });
    }
    Ok(coalesce_ranges(ranges))
}

fn eligible_reclaim_ranges(
    memory: &GuestMemory,
    guest_base: u64,
    ranges: &[PageRange],
) -> Vec<PageRange> {
    host_granule_ranges(memory, guest_base, ranges.to_vec()).eligible
}

fn reclaim_ranges(
    memory: &GuestMemory,
    guest_base: u64,
    ranges: Vec<PageRange>,
    reclaimer: Option<&dyn GuestMemoryReclaimer>,
    authority: ReclaimAuthority,
) -> ReclaimReport {
    let ranges = host_granule_ranges(memory, guest_base, ranges);
    let host_granule_eligible_bytes = ranges.eligible.iter().map(|range| range.size).sum();
    if let Some(reclaimer) = reclaimer {
        let mut report = reclaimer.reclaim_ranges(memory, guest_base, &ranges.eligible, authority);
        report.host_granule_eligible_bytes += host_granule_eligible_bytes;
        report.partial_host_granule_bytes += ranges.partial_bytes;
        return report;
    }
    let mut report = ReclaimReport {
        host_granule_eligible_bytes,
        partial_host_granule_bytes: ranges.partial_bytes,
        ..ReclaimReport::default()
    };
    for range in ranges.eligible {
        match memory.advise_free_at(guest_base, range.start, range.size as usize) {
            Ok(()) => {
                report.discard_advised_bytes += range.size;
                report.soft_reclaimed_bytes += range.size;
            }
            Err(_) => report.discard_failed_bytes += range.size,
        }
    }
    report
}

#[derive(Debug, Default)]
struct HostGranuleRanges {
    eligible: Vec<PageRange>,
    partial_bytes: u64,
}

fn host_granule_ranges(
    memory: &GuestMemory,
    guest_base: u64,
    ranges: Vec<PageRange>,
) -> HostGranuleRanges {
    let host_page_size = memory.host_page_size() as u64;
    let mut eligible = Vec::with_capacity(ranges.len());
    let mut partial_bytes = 0u64;
    for range in coalesce_ranges(ranges) {
        let Some(end) = range.end() else {
            partial_bytes = partial_bytes.saturating_add(range.size);
            continue;
        };
        let Some(offset_start) = range.start.checked_sub(guest_base) else {
            partial_bytes = partial_bytes.saturating_add(range.size);
            continue;
        };
        let Some(offset_end) = end.checked_sub(guest_base) else {
            partial_bytes = partial_bytes.saturating_add(range.size);
            continue;
        };
        let aligned_offset_start = align_up(offset_start, host_page_size);
        let aligned_offset_end = align_down(offset_end, host_page_size);
        let Some(aligned_start) = guest_base.checked_add(aligned_offset_start) else {
            partial_bytes = partial_bytes.saturating_add(range.size);
            continue;
        };
        let Some(aligned_end) = guest_base.checked_add(aligned_offset_end) else {
            partial_bytes = partial_bytes.saturating_add(range.size);
            continue;
        };
        if aligned_start < aligned_end {
            eligible.push(PageRange {
                start: aligned_start,
                size: aligned_end - aligned_start,
            });
            partial_bytes = partial_bytes
                .saturating_add(aligned_start.saturating_sub(range.start))
                .saturating_add(end.saturating_sub(aligned_end));
        } else {
            partial_bytes = partial_bytes.saturating_add(range.size);
        }
    }
    HostGranuleRanges {
        eligible,
        partial_bytes,
    }
}

fn coalesce_ranges(mut ranges: Vec<PageRange>) -> Vec<PageRange> {
    ranges.sort_by_key(|range| range.start);
    let mut coalesced: Vec<PageRange> = Vec::with_capacity(ranges.len());
    for range in ranges {
        if range.size == 0 {
            continue;
        }
        let Some(range_end) = range.end() else {
            continue;
        };
        if let Some(last) = coalesced.last_mut() {
            if let Some(last_end) = last.end() {
                if range.start <= last_end {
                    last.size = range_end.saturating_sub(last.start).max(last.size);
                    continue;
                }
            }
        }
        coalesced.push(range);
    }
    coalesced
}

fn align_up(value: u64, alignment: u64) -> u64 {
    if alignment == 0 {
        return value;
    }
    let remainder = value % alignment;
    if remainder == 0 {
        value
    } else {
        value.saturating_add(alignment - remainder)
    }
}

fn align_down(value: u64, alignment: u64) -> u64 {
    if alignment == 0 {
        value
    } else {
        value - (value % alignment)
    }
}

fn update_actual_pages_config(transport: &mut VirtioMmioDevice, actual_pages: u32) {
    let mut config = transport.configuration_bytes().to_vec();
    if config.len() < 16 {
        config.resize(16, 0);
    }
    config[4..8].copy_from_slice(&actual_pages.to_le_bytes());
    transport.update_configuration(config, false);
}

fn host_granule_for_pfn(
    memory: &GuestMemory,
    guest_base: u64,
    pfn: u64,
) -> Option<(u64, u128, u8)> {
    let guest_address = pfn.checked_mul(PAGE_SIZE)?;
    let offset = guest_address.checked_sub(guest_base)?;
    let host_page_size = memory.host_page_size() as u64;
    if host_page_size < PAGE_SIZE || host_page_size % PAGE_SIZE != 0 {
        return None;
    }
    let required_subpages = u8::try_from(host_page_size / PAGE_SIZE).ok()?;
    if required_subpages == 0 || required_subpages > u128::BITS as u8 {
        return None;
    }
    let granule_offset = align_down(offset, host_page_size);
    let granule_start = guest_base.checked_add(granule_offset)?;
    let subpage_index = (offset - granule_offset) / PAGE_SIZE;
    if subpage_index >= u64::from(required_subpages) {
        return None;
    }
    let subpage_mask = 1u128 << subpage_index;
    Some((granule_start, subpage_mask, required_subpages))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::bus::MmioDevice;
    use crate::devices::virtio::{
        VirtioDeviceKind, VirtioMmioDevice, VirtioMmioDevicePlan, STATUS_DRIVER_OK,
        STATUS_FEATURES_OK,
    };
    use crate::devices::virtqueue::{DescriptorChain, QueueDescriptor};
    use std::sync::Mutex;

    #[test]
    fn configuration_encodes_target_and_actual_pages() {
        assert_eq!(
            configuration(7, 3, 11),
            vec![7, 0, 0, 0, 3, 0, 0, 0, 11, 0, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn queue_layout_places_reporting_at_queue_two_with_current_features() {
        let layout = BalloonQueueLayout::from_features(BALLOON_FEATURE_PAGE_REPORTING);

        assert_eq!(layout.inflate, 0);
        assert_eq!(layout.deflate, 1);
        assert_eq!(layout.stats, None);
        assert_eq!(layout.free_page_hint, None);
        assert_eq!(layout.reporting, Some(2));
    }

    #[test]
    fn queue_layout_accounts_for_optional_queues() {
        let layout = BalloonQueueLayout::from_features(
            BALLOON_FEATURE_STATS | BALLOON_FEATURE_FREE_PAGE_HINT | BALLOON_FEATURE_PAGE_REPORTING,
        );

        assert_eq!(layout.stats, Some(2));
        assert_eq!(layout.free_page_hint, Some(3));
        assert_eq!(layout.reporting, Some(4));
    }

    #[test]
    fn queue_layout_skips_unnamed_optional_queues() {
        let layout = BalloonQueueLayout::from_features(
            BALLOON_FEATURE_FREE_PAGE_HINT | BALLOON_FEATURE_PAGE_REPORTING,
        );

        assert_eq!(layout.stats, None);
        assert_eq!(layout.free_page_hint, Some(2));
        assert_eq!(layout.reporting, Some(3));
    }

    #[test]
    fn transport_metrics_use_negotiated_reporting_queue_index() {
        let plan = VirtioMmioDevicePlan::new(VirtioDeviceKind::Balloon, 0);
        let mut transport = VirtioMmioDevice::new(plan.clone(), configuration(0, 0, 0));
        transport.driver_features = plan.features;
        transport.device_status = STATUS_FEATURES_OK | STATUS_DRIVER_OK;
        MmioDevice::write(&mut transport, 0x030, 2, 4).unwrap();
        MmioDevice::write(&mut transport, 0x044, 1, 4).unwrap();

        let mut handler = BalloonQueueHandler::new();
        handler.refresh_transport_metrics(&transport);
        let metrics = handler.metrics();

        assert!(metrics.page_reporting_negotiated);
        assert_eq!(metrics.reporting_queue_index, Some(2));
        assert!(metrics.reporting_queue_ready);
        assert!(metrics.queue_ready[2]);
        assert!(!metrics.queue_ready[4]);
    }

    #[test]
    fn reads_legacy_32_bit_balloon_pfns() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        memory
            .write_at(guest_base, guest_base + 0x100, &[1, 0, 0, 0, 2, 0, 0, 0])
            .unwrap();
        let chain = DescriptorChain {
            head_index: 9,
            descriptors: vec![QueueDescriptor {
                address: guest_base + 0x100,
                length: 8,
                flags: 0,
                next: 0,
            }],
        };
        assert_eq!(read_pfns(&chain, &memory, guest_base).unwrap(), vec![1, 2]);
    }

    #[test]
    fn rejects_misaligned_pfn_descriptors() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let chain = DescriptorChain {
            head_index: 9,
            descriptors: vec![QueueDescriptor {
                address: guest_base + 0x100,
                length: 3,
                flags: 0,
                next: 0,
            }],
        };
        assert!(matches!(
            read_pfns(&chain, &memory, guest_base),
            Err(BalloonError::MisalignedPfnDescriptor)
        ));
    }

    #[test]
    fn rejects_unaligned_free_page_reports_without_rounding() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let descriptors = vec![QueueDescriptor {
            address: guest_base + 0x1001,
            length: 4096,
            flags: 2,
            next: 0,
        }];

        assert!(matches!(
            page_ranges_from_reporting_descriptors(&descriptors, &memory, guest_base),
            Err(BalloonError::MisalignedFreePageReport)
        ));
    }

    #[test]
    fn coalesces_ranges_before_host_granule_filtering() {
        let guest_base = 0x4000_0000;
        let host_page_size = GuestMemory::anonymous(0x4000).unwrap().host_page_size() as u64;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();
        let ranges = vec![
            PageRange {
                start: guest_base,
                size: PAGE_SIZE,
            },
            PageRange {
                start: guest_base + PAGE_SIZE,
                size: host_page_size.saturating_sub(PAGE_SIZE),
            },
        ];

        let granules = host_granule_ranges(&memory, guest_base, ranges);
        assert_eq!(
            granules.eligible,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );
        assert_eq!(granules.partial_bytes, 0);
    }

    #[test]
    fn host_granule_filtering_aligns_relative_to_guest_base() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let guest_base = 0x4000_1000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();

        let granules = host_granule_ranges(
            &memory,
            guest_base,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }],
        );

        assert_eq!(
            granules.eligible,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );
        assert_eq!(granules.partial_bytes, 0);
    }

    #[test]
    fn host_granule_filtering_rejects_ranges_below_guest_base() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let guest_base = 0x4000_1000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();

        let granules = host_granule_ranges(
            &memory,
            guest_base,
            vec![PageRange {
                start: guest_base - PAGE_SIZE,
                size: host_page_size,
            }],
        );

        assert!(granules.eligible.is_empty());
        assert_eq!(granules.partial_bytes, host_page_size);
    }

    #[test]
    fn skips_partial_host_granules() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = memory.host_page_size() as u64;
        let granules = host_granule_ranges(
            &memory,
            guest_base,
            vec![PageRange {
                start: guest_base,
                size: host_page_size.saturating_sub(PAGE_SIZE).max(PAGE_SIZE),
            }],
        );

        if host_page_size == PAGE_SIZE {
            assert_eq!(granules.partial_bytes, 0);
            assert_eq!(granules.eligible.len(), 1);
        } else {
            assert_eq!(granules.partial_bytes, host_page_size - PAGE_SIZE);
            assert!(granules.eligible.is_empty());
        }
    }

    #[test]
    fn tracks_balloon_host_granules_across_separate_inflate_batches() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let required_subpages = host_page_size / PAGE_SIZE;
        if required_subpages <= 1 {
            return;
        }

        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();
        let first_pfn = guest_base / PAGE_SIZE;
        let mut handler = BalloonQueueHandler::new();

        for subpage in 0..required_subpages - 1 {
            let candidates =
                handler.record_balloon_inflate(&memory, guest_base, &[first_pfn + subpage]);
            assert!(candidates.is_empty());
            let metrics = handler.metrics();
            assert_eq!(metrics.current_fully_owned_host_granules, 0);
            assert_eq!(metrics.current_partially_owned_host_granules, 1);
            assert_eq!(metrics.current_balloon_decommitted_bytes, 0);
        }

        let candidates = handler.record_balloon_inflate(
            &memory,
            guest_base,
            &[first_pfn + required_subpages - 1],
        );
        assert_eq!(
            candidates,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );

        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        let metrics = handler.metrics();
        assert_eq!(metrics.current_fully_owned_host_granules, 1);
        assert_eq!(metrics.current_partially_owned_host_granules, 0);
        assert_eq!(metrics.current_balloon_decommitted_bytes, host_page_size);
    }

    #[test]
    fn deflate_clears_balloon_host_granule_decommit_state() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let required_subpages = host_page_size / PAGE_SIZE;
        if required_subpages <= 1 {
            return;
        }

        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();
        let first_pfn = guest_base / PAGE_SIZE;
        let pfns = (0..required_subpages)
            .map(|subpage| first_pfn + subpage)
            .collect::<Vec<_>>();
        let mut handler = BalloonQueueHandler::new();
        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        assert_eq!(
            handler.metrics().current_balloon_decommitted_bytes,
            host_page_size
        );

        handler.record_balloon_deflate(&memory, guest_base, &[first_pfn]);
        let metrics = handler.metrics();
        assert_eq!(metrics.current_fully_owned_host_granules, 0);
        assert_eq!(metrics.current_partially_owned_host_granules, 1);
        assert_eq!(metrics.current_balloon_decommitted_bytes, 0);
        assert_eq!(
            metrics.current_balloon_owned_bytes,
            (required_subpages - 1) * PAGE_SIZE
        );
    }

    #[test]
    fn coalesced_balloon_reclaim_marks_each_host_granule_decommitted() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let required_subpages = host_page_size / PAGE_SIZE;
        if required_subpages <= 1 {
            return;
        }

        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 4).unwrap();
        let first_pfn = guest_base / PAGE_SIZE;
        let pfns = (0..required_subpages * 2)
            .map(|subpage| first_pfn + subpage)
            .collect::<Vec<_>>();
        let mut handler = BalloonQueueHandler::new();
        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        assert_eq!(
            candidates,
            vec![PageRange {
                start: guest_base,
                size: host_page_size * 2,
            }]
        );

        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        let metrics = handler.metrics();
        assert_eq!(metrics.current_fully_owned_host_granules, 2);
        assert_eq!(
            metrics.current_balloon_decommitted_bytes,
            host_page_size * 2
        );
    }

    #[derive(Debug, Default)]
    struct RecordingReclaimer {
        ranges: Mutex<Vec<PageRange>>,
        authorities: Mutex<Vec<ReclaimAuthority>>,
        hard_zero: bool,
    }

    impl GuestMemoryReclaimer for RecordingReclaimer {
        fn reclaim_ranges(
            &self,
            _memory: &GuestMemory,
            _guest_base: u64,
            ranges: &[PageRange],
            authority: ReclaimAuthority,
        ) -> ReclaimReport {
            self.ranges.lock().unwrap().extend_from_slice(ranges);
            self.authorities.lock().unwrap().push(authority);
            let reclaimed_bytes = ranges.iter().map(|range| range.size).sum();
            let hard_decommitted_bytes = if self.hard_zero { reclaimed_bytes } else { 0 };
            let soft_reclaimed_bytes = if self.hard_zero { 0 } else { reclaimed_bytes };
            ReclaimReport {
                discard_advised_bytes: reclaimed_bytes,
                soft_reclaimed_bytes,
                hard_decommitted_bytes,
                ..ReclaimReport::default()
            }
        }
    }

    #[test]
    fn balloon_owned_reclaim_records_authority_and_hard_decommit_metrics() {
        let guest_base = 0x4000_0000;
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let required_subpages = host_page_size / PAGE_SIZE;
        let memory = GuestMemory::anonymous(host_page_size as usize * 2).unwrap();
        let first_pfn = guest_base / PAGE_SIZE;
        let pfns = (0..required_subpages)
            .map(|subpage| first_pfn + subpage)
            .collect::<Vec<_>>();
        let reclaimer = Arc::new(RecordingReclaimer {
            hard_zero: true,
            ..RecordingReclaimer::default()
        });
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer.clone());

        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);

        let metrics = handler.metrics();
        assert_eq!(metrics.balloon_owned_reclaimed_bytes, host_page_size);
        assert_eq!(metrics.report_inflight_reclaimed_bytes, 0);
        assert_eq!(metrics.hard_decommitted_bytes, host_page_size);
        assert_eq!(metrics.soft_reclaimed_bytes, 0);
        let ledger = handler.memory_ledger_summary(memory.len() as u64, host_page_size);
        assert!(ledger.ok);
        assert_eq!(ledger.cumulative_balloon_authorized_bytes, host_page_size);
        assert_eq!(ledger.cumulative_report_authorized_bytes, 0);
        assert_eq!(ledger.cumulative_hard_decommitted_bytes, host_page_size);
        assert_eq!(ledger.discarded_hard_zero_bytes, host_page_size);
        assert_eq!(ledger.balloon_owned_bytes, host_page_size);
        assert_eq!(ledger.reclaim_without_authority_bytes, 0);
        assert_eq!(ledger.guest_owned_reclaimed_bytes, 0);
        assert_eq!(
            reclaimer.authorities.lock().unwrap().as_slice(),
            &[ReclaimAuthority::BalloonOwned]
        );
    }

    #[test]
    fn reported_free_reclaim_records_inflight_authority_before_ack() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = memory.host_page_size() as u64;
        let reclaimer = Arc::new(RecordingReclaimer::default());
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer.clone());

        handler.reclaim_report_inflight_ranges(
            &memory,
            guest_base,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }],
            host_page_size,
        );

        let metrics = handler.metrics();
        assert_eq!(metrics.reported_free_bytes, host_page_size);
        assert_eq!(metrics.reported_free_reclaimed_bytes, host_page_size);
        assert_eq!(metrics.report_inflight_reclaimed_bytes, host_page_size);
        assert_eq!(metrics.balloon_owned_reclaimed_bytes, 0);
        assert_eq!(metrics.soft_reclaimed_bytes, host_page_size);
        let ledger = handler.memory_ledger_summary(memory.len() as u64, host_page_size);
        assert!(ledger.ok);
        assert_eq!(ledger.cumulative_balloon_authorized_bytes, 0);
        assert_eq!(ledger.cumulative_report_authorized_bytes, host_page_size);
        assert_eq!(ledger.cumulative_soft_discarded_bytes, host_page_size);
        assert_eq!(ledger.discarded_soft_bytes, host_page_size);
        assert_eq!(ledger.report_inflight_bytes, 0);
        assert_eq!(ledger.report_acked_before_reclaim_bytes, 0);
        assert_eq!(ledger.reclaim_without_authority_bytes, 0);
        assert_eq!(
            reclaimer.authorities.lock().unwrap().as_slice(),
            &[ReclaimAuthority::ReportInFlight]
        );
    }

    #[test]
    fn ledger_flags_reclaim_without_authority() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = memory.host_page_size() as u64;
        let mut ledger = MemoryLedger::default();
        ledger.ensure(&memory, guest_base);
        let report = ReclaimReport {
            discard_advised_bytes: host_page_size,
            hard_decommitted_bytes: host_page_size,
            ..ReclaimReport::default()
        };

        ledger.apply_reclaim(
            &[PageRange {
                start: guest_base,
                size: host_page_size,
            }],
            &report,
            ReclaimAuthority::ReportInFlight,
        );

        let summary = ledger.summary(memory.len() as u64, host_page_size);
        assert!(!summary.ok);
        assert_eq!(summary.reclaim_without_authority_bytes, host_page_size);
        assert_eq!(summary.guest_owned_reclaimed_bytes, host_page_size);
        assert_eq!(summary.discarded_hard_zero_bytes, host_page_size);
    }

    #[test]
    fn rejects_free_page_reports_outside_guest_ram() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let descriptors = vec![QueueDescriptor {
            address: guest_base + 0x8000,
            length: 4096,
            flags: 2,
            next: 0,
        }];

        assert!(matches!(
            page_ranges_from_reporting_descriptors(&descriptors, &memory, guest_base),
            Err(BalloonError::Memory(_))
        ));
    }

    #[test]
    fn free_page_hint_ranges_are_reclaimed_not_just_counted() {
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = memory.host_page_size() as u64;
        let reclaimer = Arc::new(RecordingReclaimer::default());
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer.clone());

        handler.reclaim_free_page_hint_ranges(
            &memory,
            guest_base,
            vec![PageRange {
                start: guest_base,
                size: host_page_size,
            }],
            host_page_size,
        );

        let metrics = handler.metrics();
        assert_eq!(metrics.free_page_hint_reported_bytes, host_page_size);
        assert_eq!(metrics.free_page_hint_reclaimed_bytes, host_page_size);
        assert_eq!(metrics.reclaimed_bytes, host_page_size);
        assert_eq!(metrics.report_inflight_reclaimed_bytes, host_page_size);
        assert_eq!(
            reclaimer.ranges.lock().unwrap().as_slice(),
            &[PageRange {
                start: guest_base,
                size: host_page_size
            }]
        );
        assert_eq!(
            reclaimer.authorities.lock().unwrap().as_slice(),
            &[ReclaimAuthority::ReportInFlight]
        );
    }
}
