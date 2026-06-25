#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the Conjet Phase 9 network-proof initramfs without the macOS Conjet CLI.

Usage:
  guest/kernel/scripts/build-network-proof-initramfs.sh --busybox PATH --output PATH [options]

Options:
  --busybox PATH            Static ARM64 Linux BusyBox binary to embed.
  --output PATH             Output .cpio.gz path.
  --proof-url URL           Guest outbound HTTP proof URL. Default: http://example.com
  --guest-service-port PORT BusyBox httpd proof service port. Default: 8080
  --check-tools             Validate prerequisites without building.
  -h, --help                Show this help.

The generated archive is intentionally tiny: BusyBox configures DHCP, proves
DNS/outbound TCP, starts httpd, and emits console markers consumed by Conjet's
Phase 9 network proof importer and runner.
USAGE
}

busybox_path=""
output_path=""
proof_url="${PROOF_URL:-http://example.com}"
guest_service_port="${GUEST_SERVICE_PORT:-8080}"
check_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --busybox)
      if [ "$#" -lt 2 ]; then
        echo "error: --busybox requires a value" >&2
        exit 64
      fi
      busybox_path="$2"
      shift 2
      ;;
    --output)
      if [ "$#" -lt 2 ]; then
        echo "error: --output requires a value" >&2
        exit 64
      fi
      output_path="$2"
      shift 2
      ;;
    --proof-url)
      if [ "$#" -lt 2 ]; then
        echo "error: --proof-url requires a value" >&2
        exit 64
      fi
      proof_url="$2"
      shift 2
      ;;
    --guest-service-port)
      if [ "$#" -lt 2 ]; then
        echo "error: --guest-service-port requires a value" >&2
        exit 64
      fi
      guest_service_port="$2"
      shift 2
      ;;
    --check-tools)
      check_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

require_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "error: required command not found: ${name}" >&2
    exit 69
  fi
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"
}

shell_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

validate_common_tools() {
  for command_name in cat chmod cp cpio find gzip ln mkdir mktemp rm sed sort wc; do
    require_command "${command_name}"
  done
}

validate_port() {
  case "${guest_service_port}" in
    ''|*[!0-9]*)
      echo "error: --guest-service-port must be numeric" >&2
      exit 64
      ;;
  esac
  if [ "${guest_service_port}" -lt 1 ] || [ "${guest_service_port}" -gt 65535 ]; then
    echo "error: --guest-service-port must be 1...65535" >&2
    exit 64
  fi
}

install_busybox_links() {
  local root="$1"
  local applet
  for applet in sh mount mkdir sleep ip udhcpc nslookup wget httpd route cat ifconfig; do
    ln -sf busybox "${root}/bin/${applet}"
  done
}

write_runtime_files() {
  local root="$1"
  local proof_url_literal
  proof_url_literal="$(shell_single_quote "${proof_url}")"

  mkdir -p \
    "${root}/bin" \
    "${root}/dev" \
    "${root}/etc/udhcpc" \
    "${root}/proc" \
    "${root}/run/conjet" \
    "${root}/sys" \
    "${root}/tmp" \
    "${root}/www"

  cp "${busybox_path}" "${root}/bin/busybox"
  chmod 0755 "${root}/bin/busybox"
  install_busybox_links "${root}"

  cat > "${root}/etc/udhcpc/default.script" <<'SCRIPT'
#!/bin/busybox sh
case "$1" in
  bound|renew)
    echo "CONJET_NETWORK_DHCP_BOUND interface=${interface} ip=${ip} router=${router:-} dns=${dns:-}"
    /bin/busybox ifconfig "${interface}" "${ip}" netmask "${subnet:-255.255.255.0}" up 2>/dev/null || true
    : > /run/conjet/dhcp.bound
    : > /etc/resolv.conf
    : > /run/conjet/dns.servers
    first_dns=""
    for server in ${dns:-}; do
      echo "nameserver ${server}" >> /etc/resolv.conf
      echo "${server}" >> /run/conjet/dns.servers
      if [ -z "${first_dns}" ]; then
        first_dns="${server}"
      fi
    done
    if [ -n "${first_dns}" ]; then
      echo "${first_dns}" > /run/conjet/dns.server
    fi
    if [ -n "${router:-}" ]; then
      /bin/busybox route add default gw "${router}" dev "${interface}" 2>/dev/null || true
    fi
    ;;
esac
SCRIPT
  chmod 0755 "${root}/etc/udhcpc/default.script"

  cat > "${root}/init" <<SCRIPT
#!/bin/busybox sh
set -u

bb=/bin/busybox
PATH=/bin
proof_url=${proof_url_literal}
guest_service_port=${guest_service_port}

\${bb} mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
\${bb} mount -t proc proc /proc 2>/dev/null || true
\${bb} mount -t sysfs sysfs /sys 2>/dev/null || true
\${bb} mkdir -p /run/conjet /tmp /www
\${bb} --install -s /bin 2>/dev/null || true

echo "conjet-network-proof-initramfs"
echo "CONJET_NETWORK_PROOF_BEGIN"
echo "CONJET_INIT_READY"

interface=""
for candidate in eth0 enp0s1 ens3; do
  if [ -d "/sys/class/net/\${candidate}" ]; then
    interface="\${candidate}"
    break
  fi
done

if [ -z "\${interface}" ]; then
  echo "CONJET_NETWORK_INTERFACE_MISSING"
  echo "CONJET_INIT_READY"
  while true; do \${bb} sleep 60; done
fi

echo "CONJET_NETWORK_INTERFACE_FOUND interface=\${interface}"
\${bb} ip link set lo up 2>/dev/null || true
\${bb} ip link set "\${interface}" up 2>/dev/null || true
echo "CONJET_NETWORK_LINK_SET_UP interface=\${interface}"
\${bb} ip addr show dev "\${interface}" 2>/dev/null || true
echo "CONJET_NETWORK_DHCP_START interface=\${interface}"
\${bb} udhcpc -q -n -t 10 -T 1 -i "\${interface}" -s /etc/udhcpc/default.script &
dhcp_pid="\$!"
echo "CONJET_NETWORK_DHCP_PID pid=\${dhcp_pid}"
dhcp_ok=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  echo "CONJET_NETWORK_DHCP_WAIT tick=\${_}"
  if [ -f /run/conjet/dhcp.bound ]; then
    dhcp_ok=true
    break
  fi
  \${bb} sleep 1
done
if [ "\${dhcp_ok}" = true ]; then
  echo "CONJET_NETWORK_DHCP_OK interface=\${interface}"
else
  echo "CONJET_NETWORK_DHCP_FAILED interface=\${interface}"
fi
\${bb} ip addr show dev "\${interface}" 2>/dev/null || true
\${bb} ip route show 2>/dev/null || true

dns_server="\$(\${bb} cat /run/conjet/dns.server 2>/dev/null || true)"
if [ -n "\${dns_server}" ]; then
  \${bb} nslookup example.com "\${dns_server}" >/tmp/conjet-nslookup.out 2>&1
  dns_status="\$?"
else
  \${bb} nslookup example.com >/tmp/conjet-nslookup.out 2>&1
  dns_status="\$?"
fi
if [ "\${dns_status}" = 0 ]; then
  echo "CONJET_NETWORK_DNS_RESOLVED name=example.com"
else
  echo "CONJET_NETWORK_DNS_FAILED name=example.com"
  \${bb} cat /tmp/conjet-nslookup.out 2>/dev/null || true
fi

if \${bb} wget -T 10 -O /tmp/conjet-outbound-proof "\${proof_url}" >/tmp/conjet-wget.out 2>&1; then
  echo "CONJET_NETWORK_OUTBOUND_TCP_OK url=\${proof_url}"
else
  echo "CONJET_NETWORK_OUTBOUND_TCP_FAILED url=\${proof_url}"
  \${bb} cat /tmp/conjet-wget.out 2>/dev/null || true
fi

proof_token=""
if [ -r /proc/sys/kernel/random/boot_id ]; then
  proof_token="\$(\${bb} cat /proc/sys/kernel/random/boot_id)"
fi
if [ -z "\${proof_token}" ]; then
  proof_token="pid-\$\$"
fi
echo "CONJET_NETWORK_SERVICE_TOKEN token=\${proof_token}"
echo "CONJET_NETWORK_FORWARDED_PORT_OK token=\${proof_token}" > /www/index.html

if \${bb} httpd -p "0.0.0.0:\${guest_service_port}" -h /www; then
  echo "CONJET_NETWORK_GUEST_SERVICE_READY port=\${guest_service_port}"
else
  echo "CONJET_NETWORK_GUEST_SERVICE_FAILED port=\${guest_service_port}"
fi

echo "CONJET_INIT_READY"
while true; do \${bb} sleep 60; done
SCRIPT
  chmod 0755 "${root}/init"

  printf 'nameserver 1.1.1.1\n' > "${root}/etc/resolv.conf"
  printf 'CONJET_NETWORK_FORWARDED_PORT_OK\n' > "${root}/www/index.html"
  printf 'conjet-network-proof-initramfs\n' > "${root}/etc/conjet-release"
}

add_device_nodes_if_possible() {
  local root="$1"
  if ! command -v mknod >/dev/null 2>&1; then
    return
  fi

  mknod -m 0600 "${root}/dev/console" c 5 1 2>/dev/null || true
  mknod -m 0666 "${root}/dev/null" c 1 3 2>/dev/null || true
  mknod -m 0600 "${root}/dev/kmsg" c 1 11 2>/dev/null || true
  mknod -m 0600 "${root}/dev/ttyAMA0" c 204 64 2>/dev/null || true
}

write_archive() {
  local root="$1"
  local archive="$2"
  local stderr_path="$3"

  if command -v fakeroot >/dev/null 2>&1; then
    ROOT_DIR="${root}" ARCHIVE="${archive}" STDERR_PATH="${stderr_path}" fakeroot bash -c '
      set -euo pipefail
      mknod -m 0600 "${ROOT_DIR}/dev/console" c 5 1 2>/dev/null || true
      mknod -m 0666 "${ROOT_DIR}/dev/null" c 1 3 2>/dev/null || true
      mknod -m 0600 "${ROOT_DIR}/dev/kmsg" c 1 11 2>/dev/null || true
      mknod -m 0600 "${ROOT_DIR}/dev/ttyAMA0" c 204 64 2>/dev/null || true
      cd "${ROOT_DIR}"
      find . -mindepth 1 | sed "s#^\./##" | LC_ALL=C sort | cpio -o -H newc 2>"${STDERR_PATH}" > "${ARCHIVE}"
    '
    return
  fi

  add_device_nodes_if_possible "${root}"
  (
    cd "${root}"
    find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort | cpio -o -H newc 2>"${stderr_path}"
  ) > "${archive}"
}

validate_common_tools
validate_port

if [ "${check_only}" = true ]; then
  printf 'Conjet network-proof initramfs prerequisites OK'
  if command -v fakeroot >/dev/null 2>&1; then
    printf ' with fakeroot device-node support'
  else
    printf ' without fakeroot; device nodes may be omitted on unprivileged hosts'
  fi
  printf '\n'
  exit 0
fi

if [ -z "${busybox_path}" ] || [ -z "${output_path}" ]; then
  usage >&2
  exit 64
fi
if [ ! -f "${busybox_path}" ]; then
  echo "error: BusyBox binary not found: ${busybox_path}" >&2
  exit 66
fi
if [ ! -s "${busybox_path}" ]; then
  echo "error: BusyBox binary is empty: ${busybox_path}" >&2
  exit 65
fi
if [ -z "${proof_url//[[:space:]]/}" ]; then
  echo "error: --proof-url must not be empty" >&2
  exit 64
fi

mkdir -p "$(dirname "${output_path}")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/conjet-network-initramfs.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

root="${work_dir}/root"
archive="${work_dir}/initramfs.cpio"
stderr_path="${work_dir}/cpio.stderr"

write_runtime_files "${root}"
write_archive "${root}" "${archive}" "${stderr_path}"
gzip -n -c "${archive}" > "${output_path}"

uncompressed_bytes="$(wc -c < "${archive}" | tr -d ' ')"
compressed_bytes="$(wc -c < "${output_path}" | tr -d ' ')"
entry_count="$(cd "${root}" && find . -mindepth 1 | wc -l | tr -d ' ')"

cat <<JSON
{
  "outputPath": "$(json_escape "${output_path}")",
  "uncompressedBytes": ${uncompressed_bytes},
  "compressedBytes": ${compressed_bytes},
  "entryCount": ${entry_count},
  "proofURL": "$(json_escape "${proof_url}")",
  "guestServicePort": ${guest_service_port}
}
JSON
