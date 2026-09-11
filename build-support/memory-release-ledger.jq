# A release may happen during active service operation only with guest ownership.
def authorized_memory_release:
  .memory_ledger as $ledger |
  $ledger.ok == true and
  $ledger.reclaim_without_authority_bytes == 0 and
  $ledger.guest_owned_reclaimed_bytes == 0 and
  $ledger.pinned_reclaimed_bytes == 0 and
  $ledger.report_acked_before_reclaim_bytes == 0 and
  $ledger.cumulative_hard_decommitted_bytes != null and
  $ledger.cumulative_report_authorized_bytes != null and
  $ledger.cumulative_balloon_authorized_bytes != null and
  ($ledger.cumulative_hard_decommitted_bytes <=
    ($ledger.cumulative_report_authorized_bytes + $ledger.cumulative_balloon_authorized_bytes));
