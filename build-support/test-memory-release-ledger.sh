#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq -n -e -L "${script_dir}" '
  include "memory-release-ledger";
  {memory_ledger: {ok: true, reclaim_without_authority_bytes: 0,
    guest_owned_reclaimed_bytes: 0, pinned_reclaimed_bytes: 0,
    report_acked_before_reclaim_bytes: 0, cumulative_hard_decommitted_bytes: 4096,
    cumulative_report_authorized_bytes: 4096, cumulative_balloon_authorized_bytes: 0}} as $valid |
  [($valid | authorized_memory_release),
   ($valid | .memory_ledger.pinned_reclaimed_bytes = 4096 | authorized_memory_release | not),
   ($valid | .memory_ledger.report_acked_before_reclaim_bytes = 4096 | authorized_memory_release | not),
   ($valid | .memory_ledger.cumulative_hard_decommitted_bytes = 8192 | authorized_memory_release | not),
   ({} | authorized_memory_release | not)] | all
' >/dev/null
echo "memory release ledger regression tests passed"
