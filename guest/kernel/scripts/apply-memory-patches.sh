#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <kernel-source-directory> <kernel-version>" >&2
  exit 64
fi

source_dir="$1"
version="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${source_dir}/mm/page_reporting.c"
patch_file="${script_dir}/../patches/0001-bounded-prompt-page-reporting.patch"

if [ "${version}" != "6.12.86" ]; then
  echo "error: the Conjet memory patch must be reviewed for Linux ${version}" >&2
  exit 65
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${source_file}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${source_file}" | awk '{print $1}')"
fi
original=c96d1a8f6e0ecb0780b845f40b3dbfe245f87c548cd922c2e366a79ef82b11dc
patched=051145aae8bcbfe3abd8da3cccac75d4c03446b3f71e5cbcffca50b4773c1f3e
if [ "${actual}" = "${patched}" ]; then
  exit 0
fi
if [ "${actual}" != "${original}" ]; then
  echo "error: unexpected page_reporting.c content; refusing a fuzzy memory patch" >&2
  exit 65
fi

patch -d "${source_dir}" -p1 -F0 < "${patch_file}"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${source_file}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${source_file}" | awk '{print $1}')"
fi
if [ "${actual}" != "${patched}" ]; then
  echo "error: memory patch output checksum mismatch" >&2
  exit 65
fi
