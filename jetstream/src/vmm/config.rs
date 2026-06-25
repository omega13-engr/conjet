use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::arch::aarch64;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VmAssetManifest {
    pub name: String,
    pub architecture: String,
    pub boot_loader_kind: String,
    pub kernel_path: PathBuf,
    #[serde(default)]
    pub initial_ramdisk_path: Option<PathBuf>,
    pub root_disk_path: PathBuf,
    #[serde(default)]
    pub data_disk_path: Option<PathBuf>,
    #[serde(default)]
    pub swap_disk_path: Option<PathBuf>,
    pub bootstrap_share_path: PathBuf,
    pub serial_log_path: PathBuf,
    pub docker_socket_path: PathBuf,
    #[serde(default)]
    pub kernel_command_line: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BootSource {
    pub name: String,
    pub kernel_path: PathBuf,
    pub initrd_path: Option<PathBuf>,
    pub root_disk_path: PathBuf,
    pub data_disk_path: Option<PathBuf>,
    pub swap_disk_path: Option<PathBuf>,
    pub serial_log_path: PathBuf,
    pub docker_socket_path: PathBuf,
    pub cmdline: String,
}

impl BootSource {
    pub fn from_manifest(manifest: VmAssetManifest) -> Self {
        let cmdline = if manifest.kernel_command_line.trim().is_empty() {
            aarch64::DEFAULT_CMDLINE.to_string()
        } else {
            manifest.kernel_command_line
        };
        Self {
            name: manifest.name,
            kernel_path: manifest.kernel_path,
            initrd_path: manifest
                .initial_ramdisk_path
                .filter(|p| !p.as_os_str().is_empty()),
            root_disk_path: manifest.root_disk_path,
            data_disk_path: manifest.data_disk_path,
            swap_disk_path: manifest.swap_disk_path,
            serial_log_path: manifest.serial_log_path,
            docker_socket_path: manifest.docker_socket_path,
            cmdline,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JetstreamConfig {
    pub memory_mib: u64,
    pub vcpu_count: u8,
    pub boot_source: BootSource,
}
