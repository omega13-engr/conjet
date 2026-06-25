use std::ffi::CString;
use std::ptr::NonNull;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum VmnetError {
    #[error("vmnet string contains NUL byte")]
    Nul(#[from] std::ffi::NulError),
    #[error("vmnet_start_interface failed with status {0}")]
    Start(u32),
    #[error("vmnet_write failed with status {0}")]
    Write(u32),
    #[error("vmnet_read failed with status {0}")]
    Read(u32),
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod imp {
    use super::{CString, NonNull, VmnetError};

    const VMNET_SUCCESS: u32 = 1000;
    const PACKET_SIZE: usize = 1514;

    #[repr(C)]
    struct JsVmnetPacket {
        data: *mut u8,
        len: usize,
    }

    extern "C" {
        fn js_vmnet_start_shared(
            interface_id: *const libc::c_char,
            mac_address: *const libc::c_char,
            start_address: *const libc::c_char,
            end_address: *const libc::c_char,
            subnet_mask: *const libc::c_char,
            out_status: *mut u32,
        ) -> *mut libc::c_void;
        fn js_vmnet_stop(interface: *mut libc::c_void) -> u32;
        fn js_vmnet_write(
            interface: *mut libc::c_void,
            packets: *const JsVmnetPacket,
            packet_count: *mut libc::c_int,
        ) -> u32;
        fn js_vmnet_read(
            interface: *mut libc::c_void,
            buffer: *mut u8,
            packet_size: usize,
            packet_count: *mut libc::c_int,
            sizes: *mut usize,
        ) -> u32;
    }

    #[derive(Debug)]
    pub struct VmnetSession {
        interface: NonNull<libc::c_void>,
    }

    unsafe impl Send for VmnetSession {}

    impl VmnetSession {
        pub fn start_shared(
            interface_id: &str,
            mac_address: &str,
            start_address: &str,
            end_address: &str,
            subnet_mask: &str,
        ) -> Result<Self, VmnetError> {
            let interface_id = CString::new(interface_id)?;
            let mac_address = CString::new(mac_address)?;
            let start_address = CString::new(start_address)?;
            let end_address = CString::new(end_address)?;
            let subnet_mask = CString::new(subnet_mask)?;
            let mut status = 0;
            let interface = unsafe {
                js_vmnet_start_shared(
                    interface_id.as_ptr(),
                    mac_address.as_ptr(),
                    start_address.as_ptr(),
                    end_address.as_ptr(),
                    subnet_mask.as_ptr(),
                    &mut status,
                )
            };
            let Some(interface) = NonNull::new(interface) else {
                return Err(VmnetError::Start(status));
            };
            if status != VMNET_SUCCESS {
                unsafe {
                    js_vmnet_stop(interface.as_ptr());
                }
                return Err(VmnetError::Start(status));
            }
            Ok(Self { interface })
        }

        pub fn write_packets(&mut self, packets: &[Vec<u8>]) -> Result<usize, VmnetError> {
            if packets.is_empty() {
                return Ok(0);
            }
            let mut packet_refs: Vec<_> = packets
                .iter()
                .map(|packet| JsVmnetPacket {
                    data: packet.as_ptr() as *mut u8,
                    len: packet.len(),
                })
                .collect();
            let mut packet_count = packet_refs.len() as libc::c_int;
            let status = unsafe {
                js_vmnet_write(
                    self.interface.as_ptr(),
                    packet_refs.as_mut_ptr(),
                    &mut packet_count,
                )
            };
            if status != VMNET_SUCCESS {
                return Err(VmnetError::Write(status));
            }
            Ok(packet_count as usize)
        }

        pub fn read_packets(&mut self, max_packets: usize) -> Result<Vec<Vec<u8>>, VmnetError> {
            if max_packets == 0 {
                return Ok(Vec::new());
            }
            let max_packets = max_packets.min(64);
            let mut buffer = vec![0u8; max_packets * PACKET_SIZE];
            let mut sizes = vec![0usize; max_packets];
            let mut packet_count = max_packets as libc::c_int;
            let status = unsafe {
                js_vmnet_read(
                    self.interface.as_ptr(),
                    buffer.as_mut_ptr(),
                    PACKET_SIZE,
                    &mut packet_count,
                    sizes.as_mut_ptr(),
                )
            };
            if status != VMNET_SUCCESS {
                return Err(VmnetError::Read(status));
            }
            let mut packets = Vec::with_capacity(packet_count as usize);
            for (index, size) in sizes.into_iter().take(packet_count as usize).enumerate() {
                if size > 0 {
                    let offset = index * PACKET_SIZE;
                    packets.push(buffer[offset..offset + size.min(PACKET_SIZE)].to_vec());
                }
            }
            Ok(packets)
        }
    }

    impl Drop for VmnetSession {
        fn drop(&mut self) {
            unsafe {
                js_vmnet_stop(self.interface.as_ptr());
            }
        }
    }
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
mod imp {
    use super::VmnetError;

    #[derive(Debug)]
    pub struct VmnetSession;

    impl VmnetSession {
        pub fn start_shared(
            _interface_id: &str,
            _mac_address: &str,
            _start_address: &str,
            _end_address: &str,
            _subnet_mask: &str,
        ) -> Result<Self, VmnetError> {
            Err(VmnetError::Start(0))
        }

        pub fn write_packets(&mut self, _packets: &[Vec<u8>]) -> Result<usize, VmnetError> {
            Ok(0)
        }

        pub fn read_packets(&mut self, _max_packets: usize) -> Result<Vec<Vec<u8>>, VmnetError> {
            Ok(Vec::new())
        }
    }
}

pub use imp::VmnetSession;
