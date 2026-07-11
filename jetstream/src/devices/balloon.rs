use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::devices::virtio::{VirtioMmioDevice, VirtioQueueState};
use crate::devices::virtqueue::{read_descriptors, QueueError, SplitQueueExecutor, UsedElement};
use crate::vmm::memory::{GuestMemory, GuestMemoryError};

pub const BALLOON_FEATURE_STATS: u64 = 1 << 1;
pub const BALLOON_FEATURE_MUST_TELL_HOST: u64 = 1;
pub const BALLOON_FEATURE_FREE_PAGE_HINT: u64 = 1 << 3;
pub const BALLOON_FEATURE_PAGE_REPORTING: u64 = 1 << 5;
const PAGE_SIZE: u64 = 4096;
const QUEUE_LIMIT: usize = 128;
// Keep ownership transitions bounded: a reclaim result describes one unit of
// backing state, so a partial host failure cannot leave an untracked detached
// subrange behind.
const BALLOON_RECLAIM_CHUNK_BYTES: u64 = 64 * 1024 * 1024;
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
    pub must_tell_host_negotiated: bool,
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
    pub reusable_reclaimed_bytes: u64,
    pub reusable_restored_bytes: u64,
    pub idle_hard_decommitted_bytes: u64,
    pub idle_hard_decommit_failures: u64,
    pub zero_swept_bytes: u64,
    pub zero_sweep_failed_bytes: u64,
    pub hard_decommitted_bytes: u64,
    pub balloon_owned_reclaimed_bytes: u64,
    pub report_inflight_reclaimed_bytes: u64,
    pub reclaimed_bytes: u64,
    pub reported_free_reclaimed_bytes: u64,
    pub current_balloon_owned_bytes: u64,
    pub current_fully_owned_host_granules: u64,
    pub current_partially_owned_host_granules: u64,
    pub current_balloon_decommitted_bytes: u64,
    pub current_balloon_reusable_bytes: u64,
    pub reclaim_failures: u64,
    pub reuse_failures: u64,
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
    #[error("failed to restore {bytes} reusable balloon bytes before guest ownership returned")]
    ReusableRestoreFailed { bytes: u64 },
    #[error(
        "failed to restore {bytes} hard-decommitted balloon bytes before guest ownership returned"
    )]
    HardDecommitRestoreFailed { bytes: u64 },
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
    pub reusable_reclaimed_bytes: u64,
    pub zero_swept_bytes: u64,
    pub zero_sweep_failed_bytes: u64,
    pub hard_decommitted_bytes: u64,
    pub discard_failed_bytes: u64,
    pub discard_skipped_bytes: u64,
    pub partial_host_granule_bytes: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RestoreReport {
    pub restored_bytes: u64,
    pub failed_bytes: u64,
}

/// Result of converting detached reusable balloon backing to a deterministic
/// zero-filled mapping after the guest has reached a stable idle target.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct IdleBackingCompactionReport {
    pub hard_decommitted_bytes: u64,
    pub failed_bytes: u64,
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

    fn mark_guest_owned_restored(&mut self, ranges: &[PageRange]) {
        for index in self.indices_for_ranges(ranges) {
            self.entries[index].authority = LedgerAuthority::GuestOwned;
            self.entries[index].backing = BackingState::Resident;
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

    fn promote_soft_discarded_to_hard(&mut self, ranges: &[PageRange]) -> u64 {
        let mut promoted = 0u64;
        for index in self.indices_for_ranges(ranges) {
            let entry = &mut self.entries[index];
            if entry.backing != BackingState::SoftDiscarded {
                continue;
            }
            entry.backing = BackingState::HardDecommittedZero;
            self.cumulative_hard_decommitted_bytes = self
                .cumulative_hard_decommitted_bytes
                .saturating_add(self.host_page_size);
            promoted = promoted.saturating_add(self.host_page_size);
        }
        promoted
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

    fn restore_ranges(
        &self,
        _memory: &GuestMemory,
        _guest_base: u64,
        ranges: &[PageRange],
        _mode: BalloonRestoreMode,
    ) -> RestoreReport {
        RestoreReport {
            restored_bytes: ranges.iter().map(|range| range.size).sum(),
            failed_bytes: 0,
        }
    }

    /// Converts a range whose guest mapping is already detached and whose host
    /// backing is reusable into hard-decommitted zero backing. Implementations
    /// must be all-or-nothing per supplied range so the balloon ownership
    /// tracker can preserve a correct restore mode.
    fn hard_decommit_reusable_ranges(
        &self,
        _memory: &GuestMemory,
        _guest_base: u64,
        ranges: &[PageRange],
    ) -> ReclaimReport {
        ReclaimReport {
            discard_failed_bytes: ranges.iter().map(|range| range.size).sum(),
            ..ReclaimReport::default()
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BalloonRestoreMode {
    /// The host mapping is retained but marked reusable and must be made
    /// non-reusable before it is mapped back into the guest.
    Reusable,
    /// The host backing was replaced by a fresh zero-filled mapping after its
    /// GPA mapping was detached. It only needs to be mapped back into HVF.
    HardDecommitted,
}

const HOST_GRANULE_FLAG_DECOMMITTED: u8 = 1;
const HOST_GRANULE_FLAG_REUSABLE: u8 = 1 << 1;
const HOST_GRANULE_FLAG_HARD_DECOMMITTED: u8 = 1 << 2;

#[derive(Debug, Clone, Copy)]
struct HostGranuleLocation {
    index: usize,
    start: u64,
    subpage_mask: u64,
}

/// Tracks balloon ownership by host granule instead of storing one hash-table
/// entry per 4 KiB guest PFN. On 16 KiB hosts this reduces an 8 GiB guest's
/// steady-state bookkeeping from tens of MiB to a compact 4.5 MiB table.
#[derive(Debug, Default)]
struct HostGranuleTracker {
    guest_base: u64,
    guest_size: u64,
    host_page_size: u64,
    required_subpages: u8,
    ballooned_subpages: Vec<u64>,
    flags: Vec<u8>,
}

impl HostGranuleTracker {
    /// Returns whether the layout was reset. A reset also invalidates the
    /// caller's balloon-page count.
    fn ensure(&mut self, memory: &GuestMemory, guest_base: u64) -> Option<bool> {
        let guest_size = memory.len() as u64;
        let host_page_size = memory.host_page_size() as u64;
        self.ensure_layout(guest_base, guest_size, host_page_size)
    }

    fn ensure_layout(
        &mut self,
        guest_base: u64,
        guest_size: u64,
        host_page_size: u64,
    ) -> Option<bool> {
        if host_page_size < PAGE_SIZE || host_page_size % PAGE_SIZE != 0 {
            return None;
        }
        let required_subpages = u8::try_from(host_page_size / PAGE_SIZE).ok()?;
        if required_subpages == 0 || required_subpages > u64::BITS as u8 {
            return None;
        }
        if self.guest_base == guest_base
            && self.guest_size == guest_size
            && self.host_page_size == host_page_size
            && !self.ballooned_subpages.is_empty()
        {
            return Some(false);
        }

        let granule_count = usize::try_from(guest_size.div_ceil(host_page_size)).ok()?;
        self.guest_base = guest_base;
        self.guest_size = guest_size;
        self.host_page_size = host_page_size;
        self.required_subpages = required_subpages;
        self.ballooned_subpages = vec![0; granule_count];
        self.flags = vec![0; granule_count];
        Some(true)
    }

    #[cfg(test)]
    fn allocation_bytes(&self) -> usize {
        self.ballooned_subpages
            .capacity()
            .saturating_mul(std::mem::size_of::<u64>())
            .saturating_add(
                self.flags
                    .capacity()
                    .saturating_mul(std::mem::size_of::<u8>()),
            )
    }

    fn location_for_pfn(&self, pfn: u64) -> Option<HostGranuleLocation> {
        let guest_address = pfn.checked_mul(PAGE_SIZE)?;
        let offset = guest_address.checked_sub(self.guest_base)?;
        let end = offset.checked_add(PAGE_SIZE)?;
        if end > self.guest_size || self.host_page_size == 0 {
            return None;
        }
        let index = usize::try_from(offset / self.host_page_size).ok()?;
        let subpage_index = (offset % self.host_page_size) / PAGE_SIZE;
        if index >= self.ballooned_subpages.len()
            || subpage_index >= u64::from(self.required_subpages)
        {
            return None;
        }
        let start = self
            .guest_base
            .checked_add((index as u64).saturating_mul(self.host_page_size))?;
        Some(HostGranuleLocation {
            index,
            start,
            subpage_mask: 1u64 << subpage_index,
        })
    }

    fn required_mask(&self) -> u64 {
        if self.required_subpages == u64::BITS as u8 {
            u64::MAX
        } else {
            (1u64 << self.required_subpages) - 1
        }
    }

    fn insert(&mut self, location: HostGranuleLocation) -> bool {
        let previous = self.ballooned_subpages[location.index];
        self.ballooned_subpages[location.index] |= location.subpage_mask;
        previous & location.subpage_mask == 0
    }

    fn remove(&mut self, location: HostGranuleLocation) -> bool {
        let previous = self.ballooned_subpages[location.index];
        if previous & location.subpage_mask == 0 {
            return false;
        }
        self.ballooned_subpages[location.index] &= !location.subpage_mask;
        self.flags[location.index] = 0;
        true
    }

    fn contains(&self, location: HostGranuleLocation) -> bool {
        self.ballooned_subpages[location.index] & location.subpage_mask != 0
    }

    fn fully_owned(&self, index: usize) -> bool {
        self.ballooned_subpages[index] == self.required_mask()
    }

    fn partially_owned(&self, index: usize) -> bool {
        self.ballooned_subpages[index] != 0 && !self.fully_owned(index)
    }

    fn decommitted(&self, index: usize) -> bool {
        self.flags[index] & HOST_GRANULE_FLAG_DECOMMITTED != 0
    }

    fn reusable(&self, index: usize) -> bool {
        self.flags[index] & HOST_GRANULE_FLAG_REUSABLE != 0
    }

    fn mark_decommitted(&mut self, index: usize, reusable: bool, hard_decommitted: bool) {
        self.flags[index] |= HOST_GRANULE_FLAG_DECOMMITTED;
        if reusable {
            self.flags[index] |= HOST_GRANULE_FLAG_REUSABLE;
        } else {
            self.flags[index] &= !HOST_GRANULE_FLAG_REUSABLE;
        }
        if hard_decommitted {
            self.flags[index] |= HOST_GRANULE_FLAG_HARD_DECOMMITTED;
        } else {
            self.flags[index] &= !HOST_GRANULE_FLAG_HARD_DECOMMITTED;
        }
    }

    fn clear_decommitted(&mut self, index: usize) {
        self.flags[index] &= !(HOST_GRANULE_FLAG_DECOMMITTED
            | HOST_GRANULE_FLAG_REUSABLE
            | HOST_GRANULE_FLAG_HARD_DECOMMITTED);
    }

    fn hard_decommitted(&self, index: usize) -> bool {
        self.flags[index] & HOST_GRANULE_FLAG_HARD_DECOMMITTED != 0
    }

    fn indices_for_range(&self, range: PageRange) -> Option<std::ops::Range<usize>> {
        let end = range.end()?;
        let start_offset = range.start.checked_sub(self.guest_base)?;
        let end_offset = end.checked_sub(self.guest_base)?;
        if start_offset % self.host_page_size != 0
            || end_offset % self.host_page_size != 0
            || end_offset > self.guest_size
        {
            return None;
        }
        let start = usize::try_from(start_offset / self.host_page_size).ok()?;
        let end = usize::try_from(end_offset / self.host_page_size).ok()?;
        (start <= end && end <= self.ballooned_subpages.len()).then_some(start..end)
    }

    fn start_for_index(&self, index: usize) -> Option<u64> {
        self.guest_base
            .checked_add((index as u64).checked_mul(self.host_page_size)?)
    }
}

#[derive(Debug, Default)]
pub struct BalloonQueueHandler {
    inflate_executor: SplitQueueExecutor,
    deflate_executor: SplitQueueExecutor,
    free_page_hint_executor: SplitQueueExecutor,
    reporting_executor: SplitQueueExecutor,
    ballooned_pages: u64,
    balloon_host_granules: HostGranuleTracker,
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
        metrics.actual_pages = self.ballooned_pages;
        metrics.current_balloon_owned_bytes = metrics.actual_pages.saturating_mul(PAGE_SIZE);
        metrics.current_fully_owned_host_granules = self
            .balloon_host_granules
            .ballooned_subpages
            .iter()
            .enumerate()
            .filter(|(index, _)| self.balloon_host_granules.fully_owned(*index))
            .count() as u64;
        metrics.current_partially_owned_host_granules = self
            .balloon_host_granules
            .ballooned_subpages
            .iter()
            .enumerate()
            .filter(|(index, _)| self.balloon_host_granules.partially_owned(*index))
            .count() as u64;
        metrics.current_balloon_decommitted_bytes = self
            .balloon_host_granules
            .flags
            .iter()
            .enumerate()
            .filter(|(index, _)| self.balloon_host_granules.decommitted(*index))
            .map(|_| self.balloon_host_granules.host_page_size)
            .sum();
        metrics.current_balloon_reusable_bytes = self
            .balloon_host_granules
            .flags
            .iter()
            .enumerate()
            .filter(|(index, _)| self.balloon_host_granules.reusable(*index))
            .map(|_| self.balloon_host_granules.host_page_size)
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
                self.record_balloon_inflate(memory, guest_base, &pfns);
            } else {
                self.metrics.deflate_pages += pfns.len() as u64;
                self.record_balloon_deflate(memory, guest_base, &pfns)?;
            }
            used.push(UsedElement {
                id: u32::from(chain.head_index),
                length: 0,
            });
        }

        // Replacing the anonymous backing one descriptor at a time leaves one Mach VM
        // region per tiny reclaim. Wait until the guest reaches the requested balloon
        // size, then replace every fully owned run in one globally coalesced pass.
        // Page reporting still provides mapping-preserving reclaim while a workload is
        // active, so this batching only delays the destructive zero-remap until Linux
        // has finished transferring ownership.
        if inflate
            && transport.negotiated(BALLOON_FEATURE_MUST_TELL_HOST)
            && self.balloon_target_reached(transport)
        {
            let reclaim_ranges = self.balloon_owned_reclaim_candidates();
            self.reclaim_balloon_owned_ranges(memory, guest_base, reclaim_ranges);
        }

        {
            let executor = if inflate {
                &mut self.inflate_executor
            } else {
                &mut self.deflate_executor
            };
            executor.publish_used(queue, transport, memory, guest_base, &used)?;
        }
        update_actual_pages_config(transport, self.ballooned_pages as u32);
        if !used.is_empty() && transport.interrupt_status == 0 {
            transport.mark_queue_used();
        }
        Ok(used)
    }

    fn balloon_target_reached(&self, transport: &VirtioMmioDevice) -> bool {
        let config = transport.configuration_bytes();
        if config.len() < 4 {
            return false;
        }
        let target_pages = u32::from_le_bytes(
            config[..4]
                .try_into()
                .expect("virtio-balloon target field is 4 bytes"),
        );
        target_pages > 0 && self.ballooned_pages >= u64::from(target_pages)
    }

    fn balloon_owned_reclaim_candidates(&self) -> Vec<PageRange> {
        coalesce_ranges(
            self.balloon_host_granules
                .ballooned_subpages
                .iter()
                .enumerate()
                .filter_map(|(index, _)| {
                    (self.balloon_host_granules.fully_owned(index)
                        && !self.balloon_host_granules.decommitted(index))
                    .then(|| {
                        self.balloon_host_granules
                            .start_for_index(index)
                            .map(|start| PageRange {
                                start,
                                size: self.balloon_host_granules.host_page_size,
                            })
                    })
                    .flatten()
                })
                .collect(),
        )
    }

    fn reusable_balloon_owned_ranges(&self) -> Vec<PageRange> {
        coalesce_ranges(
            self.balloon_host_granules
                .ballooned_subpages
                .iter()
                .enumerate()
                .filter_map(|(index, _)| {
                    (self.balloon_host_granules.fully_owned(index)
                        && self.balloon_host_granules.decommitted(index)
                        && self.balloon_host_granules.reusable(index))
                    .then(|| {
                        self.balloon_host_granules
                            .start_for_index(index)
                            .map(|start| PageRange {
                                start,
                                size: self.balloon_host_granules.host_page_size,
                            })
                    })
                    .flatten()
                })
                .collect(),
        )
    }

    fn ensure_balloon_tracking(&mut self, memory: &GuestMemory, guest_base: u64) -> bool {
        match self.balloon_host_granules.ensure(memory, guest_base) {
            Some(reset) => {
                if reset {
                    self.ballooned_pages = 0;
                }
                true
            }
            None => false,
        }
    }

    fn record_balloon_inflate(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        pfns: &[u64],
    ) -> Vec<PageRange> {
        let mut candidates = Vec::new();
        self.memory_ledger.ensure(memory, guest_base);
        if !self.ensure_balloon_tracking(memory, guest_base) {
            self.metrics.reclaim_failures = self
                .metrics
                .reclaim_failures
                .saturating_add(pfns.len() as u64);
            return candidates;
        }
        for &pfn in pfns {
            let Some(location) = self.balloon_host_granules.location_for_pfn(pfn) else {
                self.metrics.reclaim_failures += 1;
                continue;
            };
            if !self.balloon_host_granules.insert(location) {
                continue;
            }
            self.ballooned_pages = self.ballooned_pages.saturating_add(1);
            if self.balloon_host_granules.fully_owned(location.index)
                && !self.balloon_host_granules.decommitted(location.index)
            {
                candidates.push(PageRange {
                    start: location.start,
                    size: self.balloon_host_granules.host_page_size,
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
            for chunk in balloon_reclaim_chunks(range) {
                let eligible_ranges =
                    eligible_reclaim_ranges(memory, guest_base, std::slice::from_ref(&chunk));
                self.memory_ledger
                    .mark_authority(&eligible_ranges, LedgerAuthority::BalloonOwned);
                let report = reclaim_ranges(
                    memory,
                    guest_base,
                    vec![chunk],
                    self.reclaimer.as_deref(),
                    ReclaimAuthority::BalloonOwned,
                );
                let reclaimed = report.discard_advised_bytes == chunk.size;
                let reusable = report.reusable_reclaimed_bytes == chunk.size;
                let hard_decommitted = report.hard_decommitted_bytes == chunk.size;
                self.memory_ledger.apply_reclaim(
                    &eligible_ranges,
                    &report,
                    ReclaimAuthority::BalloonOwned,
                );
                self.record_reclaim_report(report, ReclaimAuthority::BalloonOwned, false);
                if reclaimed {
                    self.mark_balloon_range_decommitted(chunk, reusable, hard_decommitted);
                }
            }
        }
    }

    fn mark_balloon_range_decommitted(
        &mut self,
        range: PageRange,
        reusable: bool,
        hard_decommitted: bool,
    ) {
        if let Some(indices) = self.balloon_host_granules.indices_for_range(range) {
            for index in indices {
                self.balloon_host_granules
                    .mark_decommitted(index, reusable, hard_decommitted);
            }
        }
    }

    /// Strongly releases reusable balloon backing only after the Core has
    /// already verified the guest idle target. The guest mapping remains
    /// detached throughout, so a later deflate restores it through the normal
    /// hard-decommit path before Linux regains ownership.
    pub fn hard_decommit_reusable_balloon_backing(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
    ) -> IdleBackingCompactionReport {
        self.memory_ledger.ensure(memory, guest_base);
        let Some(reclaimer) = self.reclaimer.clone() else {
            let failed_bytes = self
                .reusable_balloon_owned_ranges()
                .iter()
                .map(|range| range.size)
                .sum();
            self.metrics.idle_hard_decommit_failures = self
                .metrics
                .idle_hard_decommit_failures
                .saturating_add(failed_bytes);
            return IdleBackingCompactionReport {
                failed_bytes,
                ..IdleBackingCompactionReport::default()
            };
        };

        let mut total = IdleBackingCompactionReport::default();
        for range in self.reusable_balloon_owned_ranges() {
            for chunk in balloon_reclaim_chunks(range) {
                let report = reclaimer.hard_decommit_reusable_ranges(
                    memory,
                    guest_base,
                    std::slice::from_ref(&chunk),
                );
                if report.hard_decommitted_bytes == chunk.size {
                    let promoted = self
                        .memory_ledger
                        .promote_soft_discarded_to_hard(std::slice::from_ref(&chunk));
                    if promoted == chunk.size {
                        self.mark_balloon_range_decommitted(chunk, false, true);
                        self.metrics.hard_decommitted_bytes = self
                            .metrics
                            .hard_decommitted_bytes
                            .saturating_add(chunk.size);
                        self.metrics.idle_hard_decommitted_bytes = self
                            .metrics
                            .idle_hard_decommitted_bytes
                            .saturating_add(chunk.size);
                        total.hard_decommitted_bytes =
                            total.hard_decommitted_bytes.saturating_add(chunk.size);
                        continue;
                    }
                }
                total.failed_bytes = total.failed_bytes.saturating_add(chunk.size);
                self.metrics.idle_hard_decommit_failures = self
                    .metrics
                    .idle_hard_decommit_failures
                    .saturating_add(chunk.size);
            }
        }
        total
    }

    fn record_balloon_deflate(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        pfns: &[u64],
    ) -> Result<(), BalloonError> {
        self.memory_ledger.ensure(memory, guest_base);
        if !self.ensure_balloon_tracking(memory, guest_base) {
            self.metrics.reclaim_failures = self
                .metrics
                .reclaim_failures
                .saturating_add(pfns.len() as u64);
            return Ok(());
        }
        let (released_ranges, reusable_ranges, hard_decommitted_ranges) =
            self.balloon_release_ranges_for_deflate(pfns);
        if let Err(bytes) = self.restore_balloon_ranges(
            memory,
            guest_base,
            &reusable_ranges,
            BalloonRestoreMode::Reusable,
        ) {
            return Err(BalloonError::ReusableRestoreFailed { bytes });
        }
        if let Err(bytes) = self.restore_balloon_ranges(
            memory,
            guest_base,
            &hard_decommitted_ranges,
            BalloonRestoreMode::HardDecommitted,
        ) {
            return Err(BalloonError::HardDecommitRestoreFailed { bytes });
        }
        if !released_ranges.is_empty() {
            self.memory_ledger
                .mark_guest_owned_restored(&released_ranges);
            for range in &released_ranges {
                self.mark_balloon_range_restored(*range);
            }
        }
        let mut guest_owned_ranges = Vec::new();
        for &pfn in pfns {
            let Some(location) = self.balloon_host_granules.location_for_pfn(pfn) else {
                continue;
            };
            if !self.balloon_host_granules.remove(location) {
                continue;
            }
            self.ballooned_pages = self.ballooned_pages.saturating_sub(1);
            guest_owned_ranges.push(PageRange {
                start: pfn.saturating_mul(PAGE_SIZE),
                size: PAGE_SIZE,
            });
        }
        let guest_owned_ranges = eligible_reclaim_ranges(memory, guest_base, &guest_owned_ranges);
        self.memory_ledger.mark_guest_owned(&guest_owned_ranges);
        Ok(())
    }

    fn restore_balloon_ranges(
        &mut self,
        memory: &GuestMemory,
        guest_base: u64,
        ranges: &[PageRange],
        mode: BalloonRestoreMode,
    ) -> Result<(), u64> {
        if ranges.is_empty() {
            return Ok(());
        }
        let report = self
            .reclaimer
            .as_deref()
            .map(|reclaimer| reclaimer.restore_ranges(memory, guest_base, ranges, mode))
            .unwrap_or_else(|| RestoreReport {
                restored_bytes: 0,
                failed_bytes: ranges.iter().map(|range| range.size).sum(),
            });
        if mode == BalloonRestoreMode::Reusable {
            self.metrics.reusable_restored_bytes = self
                .metrics
                .reusable_restored_bytes
                .saturating_add(report.restored_bytes);
        }
        if report.failed_bytes > 0 {
            self.metrics.reuse_failures = self.metrics.reuse_failures.saturating_add(1);
            return Err(report.failed_bytes);
        }
        Ok(())
    }

    fn balloon_release_ranges_for_deflate(
        &self,
        pfns: &[u64],
    ) -> (Vec<PageRange>, Vec<PageRange>, Vec<PageRange>) {
        let mut released = Vec::new();
        let mut reusable = Vec::new();
        let mut hard_decommitted = Vec::new();
        for &pfn in pfns {
            let Some(location) = self.balloon_host_granules.location_for_pfn(pfn) else {
                continue;
            };
            if !self.balloon_host_granules.contains(location)
                || !self.balloon_host_granules.decommitted(location.index)
            {
                continue;
            }
            let range = PageRange {
                start: location.start,
                size: self.balloon_host_granules.host_page_size,
            };
            released.push(range);
            if self.balloon_host_granules.reusable(location.index) {
                reusable.push(range);
            }
            if self.balloon_host_granules.hard_decommitted(location.index) {
                hard_decommitted.push(range);
            }
        }
        (
            coalesce_ranges(released),
            coalesce_ranges(reusable),
            coalesce_ranges(hard_decommitted),
        )
    }

    fn mark_balloon_range_restored(&mut self, range: PageRange) {
        if let Some(indices) = self.balloon_host_granules.indices_for_range(range) {
            for index in indices {
                self.balloon_host_granules.clear_decommitted(index);
            }
        }
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
        self.metrics.reusable_reclaimed_bytes += report.reusable_reclaimed_bytes;
        self.metrics.zero_swept_bytes += report.zero_swept_bytes;
        self.metrics.zero_sweep_failed_bytes += report.zero_sweep_failed_bytes;
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
        self.metrics.must_tell_host_negotiated =
            transport.negotiated(BALLOON_FEATURE_MUST_TELL_HOST);
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

fn balloon_reclaim_chunks(range: PageRange) -> Vec<PageRange> {
    let mut chunks = Vec::new();
    let Some(end) = range.end() else {
        return chunks;
    };
    let mut start = range.start;
    while start < end {
        let size = (end - start).min(BALLOON_RECLAIM_CHUNK_BYTES);
        if size == 0 {
            break;
        }
        chunks.push(PageRange { start, size });
        start = start.saturating_add(size);
    }
    chunks
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
    fn balloon_reclaim_waits_until_the_requested_target_is_reached() {
        let plan = VirtioMmioDevicePlan::new(VirtioDeviceKind::Balloon, 0);
        let transport = VirtioMmioDevice::new(plan, configuration(4, 0, 0));
        let mut handler = BalloonQueueHandler::new();
        handler.ballooned_pages = 3;
        assert!(!handler.balloon_target_reached(&transport));

        handler.ballooned_pages = 4;
        assert!(handler.balloon_target_reached(&transport));
    }

    #[test]
    fn dense_balloon_tracker_stays_small_for_an_eight_gib_guest() {
        let mut tracker = HostGranuleTracker::default();
        let guest_size = 8 * 1024 * 1024 * 1024u64;

        assert_eq!(
            tracker.ensure_layout(0x4000_0000, guest_size, 16 * 1024),
            Some(true)
        );
        assert_eq!(tracker.ballooned_subpages.len(), 524_288);
        assert_eq!(tracker.flags.len(), 524_288);
        assert!(tracker.allocation_bytes() <= 5 * 1024 * 1024);
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

        handler
            .record_balloon_deflate(&memory, guest_base, &[first_pfn])
            .unwrap();
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

    #[test]
    fn target_completion_coalesces_candidates_across_inflate_batches() {
        let base_memory = GuestMemory::anonymous(0x4000).unwrap();
        let host_page_size = base_memory.host_page_size() as u64;
        let required_subpages = host_page_size / PAGE_SIZE;
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(host_page_size as usize * 4).unwrap();
        let first_pfn = guest_base / PAGE_SIZE;
        let mut handler = BalloonQueueHandler::new();

        handler.record_balloon_inflate(
            &memory,
            guest_base,
            &(0..required_subpages)
                .map(|subpage| first_pfn + subpage)
                .collect::<Vec<_>>(),
        );
        handler.record_balloon_inflate(
            &memory,
            guest_base,
            &(required_subpages..required_subpages * 2)
                .map(|subpage| first_pfn + subpage)
                .collect::<Vec<_>>(),
        );

        assert_eq!(
            handler.balloon_owned_reclaim_candidates(),
            vec![PageRange {
                start: guest_base,
                size: host_page_size * 2,
            }]
        );
    }

    #[derive(Debug, Default)]
    struct RecordingReclaimer {
        ranges: Mutex<Vec<PageRange>>,
        restored_ranges: Mutex<Vec<PageRange>>,
        restore_modes: Mutex<Vec<BalloonRestoreMode>>,
        authorities: Mutex<Vec<ReclaimAuthority>>,
        idle_hard_decommit_ranges: Mutex<Vec<PageRange>>,
        hard_zero: bool,
        reusable: bool,
        fail_restore: bool,
        fail_idle_hard_decommit: bool,
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
                reusable_reclaimed_bytes: if self.reusable
                    && authority == ReclaimAuthority::BalloonOwned
                {
                    reclaimed_bytes
                } else {
                    0
                },
                hard_decommitted_bytes,
                ..ReclaimReport::default()
            }
        }

        fn restore_ranges(
            &self,
            _memory: &GuestMemory,
            _guest_base: u64,
            ranges: &[PageRange],
            mode: BalloonRestoreMode,
        ) -> RestoreReport {
            self.restored_ranges
                .lock()
                .unwrap()
                .extend_from_slice(ranges);
            self.restore_modes.lock().unwrap().push(mode);
            let bytes = ranges.iter().map(|range| range.size).sum();
            if self.fail_restore {
                RestoreReport {
                    restored_bytes: 0,
                    failed_bytes: bytes,
                }
            } else {
                RestoreReport {
                    restored_bytes: bytes,
                    failed_bytes: 0,
                }
            }
        }

        fn hard_decommit_reusable_ranges(
            &self,
            _memory: &GuestMemory,
            _guest_base: u64,
            ranges: &[PageRange],
        ) -> ReclaimReport {
            self.idle_hard_decommit_ranges
                .lock()
                .unwrap()
                .extend_from_slice(ranges);
            let bytes = ranges.iter().map(|range| range.size).sum();
            if self.fail_idle_hard_decommit {
                ReclaimReport {
                    discard_failed_bytes: bytes,
                    ..ReclaimReport::default()
                }
            } else {
                ReclaimReport {
                    discard_advised_bytes: bytes,
                    hard_decommitted_bytes: bytes,
                    ..ReclaimReport::default()
                }
            }
        }
    }

    #[test]
    fn reusable_balloon_memory_is_restored_before_deflate_returns_guest_ownership() {
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
            reusable: true,
            ..RecordingReclaimer::default()
        });
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer.clone());

        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        let reclaimed = handler.metrics();
        assert_eq!(reclaimed.reusable_reclaimed_bytes, host_page_size);
        assert_eq!(reclaimed.current_balloon_reusable_bytes, host_page_size);

        handler
            .record_balloon_deflate(&memory, guest_base, &[first_pfn])
            .unwrap();

        let restored = handler.metrics();
        assert_eq!(restored.reusable_restored_bytes, host_page_size);
        assert_eq!(restored.current_balloon_reusable_bytes, 0);
        assert_eq!(restored.reuse_failures, 0);
        assert_eq!(
            reclaimer.restored_ranges.lock().unwrap().as_slice(),
            &[PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );
        let ledger = handler.memory_ledger_summary(memory.len() as u64, host_page_size);
        assert!(ledger.ok);
        assert_eq!(ledger.discarded_soft_bytes, 0);
        assert_eq!(ledger.guest_owned_bytes, memory.len() as u64);
    }

    #[test]
    fn idle_compaction_converts_reusable_balloon_backing_before_deflate() {
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
            reusable: true,
            ..RecordingReclaimer::default()
        });
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer.clone());

        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        let compacted = handler.hard_decommit_reusable_balloon_backing(&memory, guest_base);
        assert_eq!(compacted.hard_decommitted_bytes, host_page_size);
        assert_eq!(compacted.failed_bytes, 0);

        let metrics = handler.metrics();
        assert_eq!(metrics.current_balloon_reusable_bytes, 0);
        assert_eq!(metrics.idle_hard_decommitted_bytes, host_page_size);
        assert_eq!(metrics.idle_hard_decommit_failures, 0);
        let ledger = handler.memory_ledger_summary(memory.len() as u64, host_page_size);
        assert!(ledger.ok);
        assert_eq!(ledger.discarded_soft_bytes, 0);
        assert_eq!(ledger.discarded_hard_zero_bytes, host_page_size);
        assert_eq!(ledger.cumulative_hard_decommitted_bytes, host_page_size);

        handler
            .record_balloon_deflate(&memory, guest_base, &[first_pfn])
            .unwrap();
        assert_eq!(
            reclaimer.restore_modes.lock().unwrap().as_slice(),
            &[BalloonRestoreMode::HardDecommitted]
        );
        assert_eq!(
            reclaimer
                .idle_hard_decommit_ranges
                .lock()
                .unwrap()
                .as_slice(),
            &[PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );
    }

    #[test]
    fn reusable_restore_failure_keeps_the_balloon_granule_owned() {
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
            reusable: true,
            fail_restore: true,
            ..RecordingReclaimer::default()
        });
        let mut handler = BalloonQueueHandler::with_reclaimer(reclaimer);

        let candidates = handler.record_balloon_inflate(&memory, guest_base, &pfns);
        handler.reclaim_balloon_owned_ranges(&memory, guest_base, candidates);
        let error = handler
            .record_balloon_deflate(&memory, guest_base, &[first_pfn])
            .unwrap_err();

        assert!(matches!(
            error,
            BalloonError::ReusableRestoreFailed { bytes } if bytes == host_page_size
        ));
        let metrics = handler.metrics();
        assert_eq!(metrics.reuse_failures, 1);
        assert_eq!(metrics.current_balloon_reusable_bytes, host_page_size);
        assert_eq!(metrics.current_balloon_owned_bytes, host_page_size);
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
    fn hard_decommitted_balloon_memory_is_remapped_before_deflate_returns() {
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
        handler
            .record_balloon_deflate(&memory, guest_base, &[first_pfn])
            .unwrap();

        assert_eq!(
            reclaimer.restore_modes.lock().unwrap().as_slice(),
            &[BalloonRestoreMode::HardDecommitted]
        );
        assert_eq!(
            reclaimer.restored_ranges.lock().unwrap().as_slice(),
            &[PageRange {
                start: guest_base,
                size: host_page_size,
            }]
        );
        let ledger = handler.memory_ledger_summary(memory.len() as u64, host_page_size);
        assert!(ledger.ok);
        assert_eq!(ledger.guest_owned_bytes, memory.len() as u64);
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
