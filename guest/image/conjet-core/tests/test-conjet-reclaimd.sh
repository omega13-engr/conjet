#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/conjet-reclaimd.XXXXXX")"
trap 'rm -rf "${qa_root}"' EXIT

cc_bin="${CC:-cc}"
test_bin="${qa_root}/conjet-reclaimd-regression"

"${cc_bin}" -std=c11 -Wall -Wextra -Werror \
  "${script_dir}/conjet-reclaimd-regression.c" \
  -o "${test_bin}"

"${test_bin}"
