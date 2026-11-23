#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod bridge_fixture;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod cgroups;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod exec_fixture;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod fresh_fixture;
#[cfg(target_os = "linux")]
pub mod guest;
pub mod handshake;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod image_store;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod kernel_fixture;
pub mod oci;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod recovery_fixture;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub mod sandbox_fixture;
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod security;
pub mod server;
pub mod socket;
pub mod spec;
pub mod wire;

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
mod output;

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
mod intent;

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
mod prepared;

#[cfg(any(test, all(target_os = "linux", target_arch = "aarch64")))]
mod memory;
