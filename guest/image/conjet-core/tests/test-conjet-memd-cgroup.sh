#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/conjet-memd-cgroup.XXXXXX")"
trap 'rm -rf "${qa_root}"' EXIT

cc_bin="${CC:-cc}"
test_bin="${qa_root}/conjet-memd-cgroup-regression"

"${cc_bin}" -std=c11 -Wall -Wextra -Werror -pthread \
  "${script_dir}/conjet-memd-cgroup-regression.c" \
  -o "${test_bin}"

"${test_bin}"
