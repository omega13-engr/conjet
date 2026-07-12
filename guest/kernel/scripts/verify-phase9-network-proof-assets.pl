#!/usr/bin/env perl
use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Spec;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use JSON::PP qw(decode_json);

my @required_kernel_builtins = qw(
  CONFIG_RANDOMIZE_BASE
  CONFIG_STACKPROTECTOR
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
  CONFIG_ARM64_4K_PAGES
  CONFIG_OF
  CONFIG_BLK_DEV_INITRD
  CONFIG_BLK_DEV_LOOP
  CONFIG_RD_GZIP
  CONFIG_DEVTMPFS
  CONFIG_DEVTMPFS_MOUNT
  CONFIG_TMPFS
  CONFIG_TMPFS_POSIX_ACL
  CONFIG_DUMMY_CONSOLE
  CONFIG_SERIAL_AMBA_PL011
  CONFIG_SERIAL_AMBA_PL011_CONSOLE
  CONFIG_ARM_AMBA
  CONFIG_ARM_GIC
  CONFIG_ARM_GIC_V3
  CONFIG_ARM_ARCH_TIMER
  CONFIG_VIRTIO
  CONFIG_VIRTIO_MENU
  CONFIG_VIRTIO_MMIO
  CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
  CONFIG_VIRTIO_BLK
  CONFIG_VIRTIO_NET
  CONFIG_VIRTIO_CONSOLE
  CONFIG_VIRTIO_BALLOON
  CONFIG_PAGE_REPORTING
  CONFIG_HW_RANDOM
  CONFIG_HW_RANDOM_VIRTIO
  CONFIG_VSOCKETS
  CONFIG_VIRTIO_VSOCKETS
  CONFIG_VIRTIO_VSOCKETS_COMMON
  CONFIG_BLOCK
  CONFIG_BLK_DEV
  CONFIG_PCI
  CONFIG_PCI_HOST_GENERIC
  CONFIG_NVME_CORE
  CONFIG_BLK_DEV_NVME
  CONFIG_PARTITION_ADVANCED
  CONFIG_EFI_PARTITION
  CONFIG_MSDOS_PARTITION
  CONFIG_EXT4_FS
  CONFIG_EXT4_USE_FOR_EXT2
  CONFIG_EXT4_FS_POSIX_ACL
  CONFIG_EXT4_FS_SECURITY
  CONFIG_OVERLAY_FS
  CONFIG_HUGETLBFS
  CONFIG_MISC_FILESYSTEMS
  CONFIG_SQUASHFS
  CONFIG_ISO9660_FS
  CONFIG_VFAT_FS
  CONFIG_NLS
  CONFIG_NLS_CODEPAGE_437
  CONFIG_NLS_ISO8859_1
  CONFIG_FUSE_FS
  CONFIG_VIRTIO_FS
  CONFIG_SWAP
  CONFIG_NAMESPACES
  CONFIG_SYSVIPC
  CONFIG_UTS_NS
  CONFIG_IPC_NS
  CONFIG_USER_NS
  CONFIG_PID_NS
  CONFIG_NET_NS
  CONFIG_CGROUPS
  CONFIG_PERF_EVENTS
  CONFIG_BPF_SYSCALL
  CONFIG_BPF_JIT
  CONFIG_CGROUP_BPF
  CONFIG_CGROUP_CPUACCT
  CONFIG_CGROUP_PIDS
  CONFIG_CGROUP_FREEZER
  CONFIG_CGROUP_DEVICE
  CONFIG_CGROUP_HUGETLB
  CONFIG_CGROUP_PERF
  CONFIG_CGROUP_NET_CLASSID
  CONFIG_CGROUP_NET_PRIO
  CONFIG_CPUSETS
  CONFIG_MEMCG
  CONFIG_LRU_GEN
  CONFIG_LRU_GEN_ENABLED
  CONFIG_BLK_CGROUP
  CONFIG_BLK_DEV_THROTTLING
  CONFIG_CGROUP_SCHED
  CONFIG_CFS_BANDWIDTH
  CONFIG_FAIR_GROUP_SCHED
  CONFIG_SECCOMP
  CONFIG_SECCOMP_FILTER
  CONFIG_KEYS
  CONFIG_POSIX_MQUEUE
  CONFIG_BINFMT_ELF
  CONFIG_BINFMT_SCRIPT
  CONFIG_BINFMT_MISC
  CONFIG_AUDIT
  CONFIG_AUDITSYSCALL
  CONFIG_SECURITY
  CONFIG_SECURITYFS
  CONFIG_SECURITY_NETWORK
  CONFIG_SECURITY_APPARMOR
  CONFIG_SECURITY_SELINUX
  CONFIG_IKCONFIG
  CONFIG_IKCONFIG_PROC
  CONFIG_COMPACTION
  CONFIG_BALLOON_COMPACTION
  CONFIG_PSI
  CONFIG_ZSMALLOC
  CONFIG_ZRAM
  CONFIG_ZRAM_WRITEBACK
  CONFIG_NET
  CONFIG_INET
  CONFIG_IPV6
  CONFIG_PACKET
  CONFIG_UNIX
  CONFIG_NET_SCHED
  CONFIG_NET_CLS
  CONFIG_NET_CLS_ACT
  CONFIG_NET_CLS_CGROUP
  CONFIG_NET_CLS_BPF
  CONFIG_NET_ACT_BPF
  CONFIG_NETDEVICES
  CONFIG_NET_CORE
  CONFIG_IP_SCTP
  CONFIG_TUN
  CONFIG_DUMMY
  CONFIG_MACVLAN
  CONFIG_IPVLAN
  CONFIG_VXLAN
  CONFIG_VLAN_8021Q
  CONFIG_VETH
  CONFIG_BRIDGE
  CONFIG_BRIDGE_NETFILTER
  CONFIG_BRIDGE_VLAN_FILTERING
  CONFIG_NETFILTER
  CONFIG_NETFILTER_ADVANCED
  CONFIG_NF_CONNTRACK
  CONFIG_NF_CONNTRACK_FTP
  CONFIG_NF_CONNTRACK_TFTP
  CONFIG_NF_NAT
  CONFIG_NF_NAT_FTP
  CONFIG_NF_NAT_TFTP
  CONFIG_NF_TABLES
  CONFIG_NF_TABLES_INET
  CONFIG_NF_TABLES_IPV4
  CONFIG_NF_TABLES_IPV6
  CONFIG_NFT_CT
  CONFIG_NFT_FIB
  CONFIG_NFT_FIB_INET
  CONFIG_NFT_FIB_IPV4
  CONFIG_NFT_FIB_IPV6
  CONFIG_NFT_NAT
  CONFIG_NFT_MASQ
  CONFIG_NFT_REDIR
  CONFIG_NFT_COMPAT
  CONFIG_NETFILTER_XTABLES
  CONFIG_NETFILTER_XT_NAT
  CONFIG_NETFILTER_XT_MARK
  CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
  CONFIG_NETFILTER_XT_MATCH_BPF
  CONFIG_NETFILTER_XT_MATCH_COMMENT
  CONFIG_NETFILTER_XT_MATCH_CONNTRACK
  CONFIG_NETFILTER_XT_MATCH_IPVS
  CONFIG_NETFILTER_XT_MATCH_MULTIPORT
  CONFIG_NETFILTER_XT_MATCH_STATE
  CONFIG_NETFILTER_XT_TARGET_MARK
  CONFIG_NETFILTER_XT_TARGET_REDIRECT
  CONFIG_IP_SET
  CONFIG_IP_SET_HASH_IP
  CONFIG_IP_SET_HASH_NET
  CONFIG_IP_SET_HASH_IPPORT
  CONFIG_IP_SET_HASH_NETPORT
  CONFIG_IP_SET_LIST_SET
  CONFIG_IP_VS
  CONFIG_IP_VS_NFCT
  CONFIG_IP_VS_PROTO_TCP
  CONFIG_IP_VS_PROTO_UDP
  CONFIG_IP_VS_RR
  CONFIG_IP_NF_IPTABLES
  CONFIG_IP_NF_FILTER
  CONFIG_IP_NF_MANGLE
  CONFIG_IP_NF_NAT
  CONFIG_IP_NF_RAW
  CONFIG_IP_NF_TARGET_REJECT
  CONFIG_IP_NF_TARGET_MASQUERADE
  CONFIG_IP_NF_TARGET_REDIRECT
  CONFIG_IP6_NF_IPTABLES
  CONFIG_IP6_NF_FILTER
  CONFIG_IP6_NF_MANGLE
  CONFIG_IP6_NF_NAT
  CONFIG_IP6_NF_RAW
  CONFIG_IP6_NF_TARGET_REJECT
  CONFIG_IP6_NF_TARGET_MASQUERADE
  CONFIG_CRYPTO
  CONFIG_CRYPTO_AEAD
  CONFIG_CRYPTO_GCM
  CONFIG_CRYPTO_SEQIV
  CONFIG_CRYPTO_GHASH
  CONFIG_XFRM
  CONFIG_XFRM_USER
  CONFIG_XFRM_ALGO
  CONFIG_INET_ESP
  CONFIG_BTRFS_FS
  CONFIG_BTRFS_FS_POSIX_ACL
  CONFIG_INOTIFY_USER
  CONFIG_FANOTIFY
  CONFIG_EPOLL
  CONFIG_PROC_FS
  CONFIG_SYSFS
  CONFIG_PRINTK
);

sub usage {
  print STDERR <<'USAGE';
Verify a Conjet Phase 9 network-proof asset bundle offline.

Usage:
  guest/kernel/scripts/verify-phase9-network-proof-assets.pl --manifest PATH
  guest/kernel/scripts/verify-phase9-network-proof-assets.pl --check-tools

This verifier does not start Conjet, Docker, vmnet, or an HVF VM. It validates
the bundle manifest, checksums, ARM64 Linux Image header, kernel config manifest,
network-proof initramfs markers, and embedded static AArch64 BusyBox ELF.
USAGE
}

sub fail {
  my ($message) = @_;
  print STDERR "error: $message\n";
  exit 65;
}

sub check_tools {
  eval {
    sha256_hex('');
    decode_json('{"ok":true}');
    my $unused = $GunzipError;
    1;
  } or do {
    print STDERR "error: required Perl core modules are unavailable: $@\n";
    exit 69;
  };
  print "Conjet Phase 9 bundle verifier prerequisites OK\n";
}

my $manifest_path = '';
my $check_only = 0;
while (@ARGV) {
  my $arg = shift @ARGV;
  if ($arg eq '--manifest') {
    @ARGV or do { usage(); exit 64; };
    $manifest_path = shift @ARGV;
  } elsif ($arg eq '--check-tools') {
    $check_only = 1;
  } elsif ($arg eq '-h' || $arg eq '--help') {
    usage();
    exit 0;
  } else {
    usage();
    exit 64;
  }
}

if ($check_only) {
  check_tools();
  exit 0;
}

if ($manifest_path eq '') {
  usage();
  exit 64;
}

sub read_file_bytes {
  my ($path) = @_;
  open my $fh, '<:raw', $path or fail("cannot read $path: $!");
  local $/;
  my $data = <$fh>;
  close $fh or fail("cannot close $path: $!");
  return defined($data) ? $data : '';
}

sub read_json_file {
  my ($path, $label) = @_;
  my $data = read_file_bytes($path);
  my $decoded = eval { decode_json($data) };
  fail("$label is not valid JSON: $@") if $@;
  return $decoded;
}

sub sha256_file {
  my ($path) = @_;
  return sha256_hex(read_file_bytes($path));
}

sub resolve_asset {
  my ($manifest_dir, $raw, $field) = @_;
  defined($raw) or fail("bundle field '$field' is missing");
  $raw =~ s/^\s+|\s+$//g;
  fail("bundle field '$field' is empty") if $raw eq '';
  my $path = File::Spec->file_name_is_absolute($raw)
    ? $raw
    : File::Spec->catfile($manifest_dir, $raw);
  $path = File::Spec->rel2abs($path);
  -f $path or fail("bundle asset '$field' is missing at $path");
  return $path;
}

sub require_sha256 {
  my ($path, $expected, $label) = @_;
  defined($expected) && $expected =~ /^[0-9a-fA-F]{64}$/
    or fail("$label SHA-256 must be a 64-character hex digest");
  my $actual = sha256_file($path);
  lc($expected) eq $actual
    or fail("$label checksum mismatch: expected " . lc($expected) . ", got $actual");
}

sub validate_arm64_linux_image {
  my ($path) = @_;
  open my $fh, '<:raw', $path or fail("cannot read kernel Image $path: $!");
  read($fh, my $header, 64) == 64
    or fail("kernel Image header is too small");
  close $fh or fail("cannot close kernel Image $path: $!");
  my $magic = unpack('V', substr($header, 0x38, 4));
  $magic == 0x644d5241
    or fail("kernel must be an uncompressed ARM64 Linux Image with ARM64 Image header magic");
}

sub u16le {
  my ($data, $offset, $label) = @_;
  length($data) >= $offset + 2 or fail("$label is truncated");
  return unpack('v', substr($data, $offset, 2));
}

sub u32le {
  my ($data, $offset, $label) = @_;
  length($data) >= $offset + 4 or fail("$label is truncated");
  return unpack('V', substr($data, $offset, 4));
}

sub u64le {
  my ($data, $offset, $label) = @_;
  length($data) >= $offset + 8 or fail("$label is truncated");
  my ($low, $high) = unpack('VV', substr($data, $offset, 8));
  my $value = $low + ($high * 4294967296);
  return $value;
}

sub validate_static_arm64_linux_elf {
  my ($data, $label) = @_;
  length($data) >= 64 or fail("$label must be an ELF64 AArch64 Linux binary; file is too small");
  substr($data, 0, 4) eq "\x7fELF" or fail("$label must be an ELF64 AArch64 Linux binary");
  ord(substr($data, 4, 1)) == 2 or fail("$label must be ELF64");
  ord(substr($data, 5, 1)) == 1 or fail("$label must be little-endian ELF");
  ord(substr($data, 6, 1)) == 1 or fail("$label has an unsupported ELF version");

  my $object_type = u16le($data, 16, $label);
  ($object_type == 2 || $object_type == 3)
    or fail("$label must be an executable or PIE ELF");
  my $machine = u16le($data, 18, $label);
  $machine == 183 or fail("$label must target AArch64; ELF machine is $machine");
  my $version = u32le($data, 20, $label);
  $version == 1 or fail("$label has an unsupported ELF object version");

  my $phoff = u64le($data, 32, $label);
  my $phentsize = u16le($data, 54, $label);
  my $phnum = u16le($data, 56, $label);
  $phoff > 0 && $phentsize >= 56 && $phnum > 0
    or fail("$label must contain a valid ELF program header table");
  $phoff + ($phentsize * $phnum) <= length($data)
    or fail("$label ELF program header table is truncated");

  my $has_load = 0;
  for my $index (0 .. $phnum - 1) {
    my $offset = $phoff + ($index * $phentsize);
    my $program_type = u32le($data, $offset, $label);
    if ($program_type == 1) {
      my $segment_offset = u64le($data, $offset + 8, $label);
      my $file_size = u64le($data, $offset + 32, $label);
      $segment_offset + $file_size <= length($data)
        or fail("$label ELF load segment is truncated");
      $has_load = 1;
    }
    if ($program_type == 3) {
      fail("$label must be statically linked; ELF PT_INTERP segment was found");
    }
  }
  $has_load or fail("$label must contain a loadable ELF segment");
}

sub gunzip_file {
  my ($path) = @_;
  my $output = '';
  gunzip $path => \$output
    or fail("cannot gunzip $path: $GunzipError");
  return $output;
}

sub align4 {
  my ($value) = @_;
  my $remainder = $value % 4;
  return $remainder == 0 ? $value : $value + (4 - $remainder);
}

sub parse_newc {
  my ($archive) = @_;
  my %entries;
  my $offset = 0;
  my $saw_trailer = 0;
  while ($offset + 110 <= length($archive)) {
    my $header = substr($archive, $offset, 110);
    substr($header, 0, 6) eq '070701'
      or fail("initramfs is not a valid newc archive");
    my $file_size = hex(substr($header, 54, 8));
    my $name_size = hex(substr($header, 94, 8));
    $name_size > 0 or fail("initramfs has an invalid newc entry name size");

    my $name_start = $offset + 110;
    my $name_end = $name_start + $name_size - 1;
    $name_end <= length($archive)
      or fail("initramfs newc entry name is truncated");
    my $name = substr($archive, $name_start, $name_size - 1);
    $offset = align4($name_start + $name_size);
    $offset + $file_size <= length($archive)
      or fail("initramfs newc entry '$name' is truncated");
    my $data = substr($archive, $offset, $file_size);
    $entries{$name} = $data;
    $offset = align4($offset + $file_size);
    if ($name eq 'TRAILER!!!') {
      $saw_trailer = 1;
      last;
    }
  }
  $saw_trailer or fail("initramfs newc archive is missing TRAILER!!!");
  return \%entries;
}

sub validate_initramfs {
  my ($path) = @_;
  my $data = gunzip_file($path);
  for my $marker (
    'conjet-network-proof-initramfs',
    'CONJET_NETWORK_PROOF_BEGIN',
    'CONJET_NETWORK_OUTBOUND_TCP_OK',
    'CONJET_NETWORK_GUEST_SERVICE_READY',
    'CONJET_NETWORK_FORWARDED_PORT_OK'
  ) {
    index($data, $marker) >= 0
      or fail("network-proof initramfs is missing marker '$marker'");
  }
  my $entries = parse_newc($data);
  exists $entries->{'bin/busybox'}
    or fail("network-proof initramfs is missing bin/busybox");
  exists $entries->{'bin/sh'}
    or fail("network-proof initramfs is missing bin/sh BusyBox applet link");
  ($entries->{'bin/sh'} eq 'busybox' || $entries->{'bin/sh'} eq '/bin/busybox')
    or fail("network-proof initramfs bin/sh must point to embedded BusyBox");
  validate_static_arm64_linux_elf($entries->{'bin/busybox'}, 'embedded BusyBox');
}

my $manifest_abs = File::Spec->rel2abs($manifest_path);
-f $manifest_abs or fail("bundle manifest is missing: $manifest_abs");
my $manifest = read_json_file($manifest_abs, 'bundle manifest');
my $manifest_dir = dirname($manifest_abs);

($manifest->{schemaVersion} // 0) == 1
  or fail("unsupported bundle schema version " . ($manifest->{schemaVersion} // '<missing>'));
my $name = $manifest->{name} // '';
$name =~ /\S/ or fail("bundle name must not be empty");
my $architecture = lc($manifest->{architecture} // '');
($architecture eq 'arm64' || $architecture eq 'aarch64')
  or fail("bundle architecture must be arm64/aarch64, got '$architecture'");
my $proof_url = $manifest->{proofURL} // '';
$proof_url =~ /\S/ or fail("bundle proofURL must not be empty");
my $guest_port = $manifest->{guestServicePort} // 0;
$guest_port =~ /^[0-9]+$/ && $guest_port >= 1 && $guest_port <= 65535
  or fail("bundle guestServicePort must be 1...65535");

my $kernel = resolve_asset($manifest_dir, $manifest->{kernelImage}, 'kernelImage');
my $kernel_manifest_path = resolve_asset($manifest_dir, $manifest->{kernelBuildManifest}, 'kernelBuildManifest');
my $busybox = resolve_asset($manifest_dir, $manifest->{busybox}, 'busybox');
my $initramfs = resolve_asset($manifest_dir, $manifest->{initramfs}, 'initramfs');

require_sha256($kernel, $manifest->{kernelImageSha256}, 'kernelImage');
require_sha256($kernel_manifest_path, $manifest->{kernelBuildManifestSha256}, 'kernelBuildManifest');
require_sha256($busybox, $manifest->{busyboxSha256}, 'busybox');
require_sha256($initramfs, $manifest->{initramfsSha256}, 'initramfs');

validate_arm64_linux_image($kernel);
validate_static_arm64_linux_elf(read_file_bytes($busybox), 'bundle BusyBox');
validate_initramfs($initramfs);

my $kernel_manifest = read_json_file($kernel_manifest_path, 'kernel build manifest');
my $manifest_image_sha = lc($kernel_manifest->{imageSha256} // '');
$manifest_image_sha eq lc($manifest->{kernelImageSha256})
  or fail("kernel build manifest imageSha256 does not match bundle kernelImageSha256");
my %builtins = map { $_ => 1 } @{ $kernel_manifest->{requiredBuiltIns} // [] };
for my $required (@required_kernel_builtins) {
  $builtins{$required}
    or fail("kernel build manifest is missing required built-in $required");
}

print "Conjet Phase 9 network-proof bundle OK: $manifest_abs\n";
