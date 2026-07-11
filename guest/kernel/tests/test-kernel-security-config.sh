#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
configs=(
  "${repo_root}/guest/kernel/config/conjet-arm64.config"
  "${repo_root}/guest/kernel/config/conjet-fast-arm64.config"
)
enabled=(
  CONFIG_RANDOMIZE_BASE
  CONFIG_STACKPROTECTOR_STRONG
  CONFIG_FORTIFY_SOURCE
  CONFIG_HARDENED_USERCOPY
  CONFIG_SLAB_FREELIST_HARDENED
  CONFIG_SLAB_FREELIST_RANDOM
  CONFIG_SHUFFLE_PAGE_ALLOCATOR
  CONFIG_BPF_UNPRIV_DEFAULT_OFF
  CONFIG_STRICT_KERNEL_RWX
  CONFIG_UNMAP_KERNEL_AT_EL0
  CONFIG_INIT_STACK_ALL_ZERO
  CONFIG_LRU_GEN
  CONFIG_LRU_GEN_ENABLED
)
disabled=(
  CONFIG_DEBUG_FS
  CONFIG_MAGIC_SYSRQ
  CONFIG_USERFAULTFD
)

for config in "${configs[@]}"; do
  for option in "${enabled[@]}"; do
    grep -qx "${option}=y" "${config}"
  done
  for option in "${disabled[@]}"; do
    grep -qx "# ${option} is not set" "${config}"
  done
done

echo "kernel security config regression tests passed"
