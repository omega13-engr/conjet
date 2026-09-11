#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "usage: $0 <Linux-6.12.86-source-directory>" >&2
  exit 64
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qa_root="$(mktemp -d "${TMPDIR:-/tmp}/conjet-kernel-patch.XXXXXX")"
trap 'rm -rf "${qa_root}"' EXIT
mkdir -p "${qa_root}/mm"
cp "$1/mm/page_reporting.c" "${qa_root}/mm/"
bash "${script_dir}/../scripts/apply-memory-patches.sh" "${qa_root}" 6.12.86
cp "${qa_root}/mm/page_reporting.c" "${qa_root}/expected.c"
bash "${script_dir}/../scripts/apply-memory-patches.sh" "${qa_root}" 6.12.86
cmp "${qa_root}/expected.c" "${qa_root}/mm/page_reporting.c"
if bash "${script_dir}/../scripts/apply-memory-patches.sh" "${qa_root}" 6.12.87 >/dev/null 2>&1; then
  echo "error: unexpected kernel version accepted" >&2
  exit 1
fi
printf '\n/* unexpected local edit */\n' >> "${qa_root}/mm/page_reporting.c"
if bash "${script_dir}/../scripts/apply-memory-patches.sh" "${qa_root}" 6.12.86 >/dev/null 2>&1; then
  echo "error: unexpected source content accepted" >&2
  exit 1
fi
echo "kernel memory patch regression tests passed"
