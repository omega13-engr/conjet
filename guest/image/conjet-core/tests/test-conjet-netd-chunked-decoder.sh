#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/conjet-netd-chunked.XXXXXX")"
trap 'rm -rf "${qa_root}"' EXIT

cc_bin="${CC:-cc}"
plain_bin="${qa_root}/conjet-netd-chunked-regression"

"${cc_bin}" -O0 -g -pthread \
  "${script_dir}/conjet-netd-chunked-decoder-regression.c" \
  -o "${plain_bin}"
"${plain_bin}"

asan_runtime=""
if [ "$(uname -s)" = "Linux" ] && command -v clang >/dev/null 2>&1; then
  asan_runtime="$(clang -print-file-name=libclang_rt.asan-"$(uname -m)".a 2>/dev/null || true)"
fi
if [ -n "$asan_runtime" ] && [ -f "$asan_runtime" ]; then
  sanitized_bin="${qa_root}/conjet-netd-chunked-regression-sanitized"
  clang -O0 -g -fsanitize=address,undefined,unsigned-integer-overflow \
    -fno-sanitize-recover=all -pthread \
    "${script_dir}/conjet-netd-chunked-decoder-regression.c" \
    -o "${sanitized_bin}"
  ASAN_OPTIONS=abort_on_error=1 "${sanitized_bin}"
fi
