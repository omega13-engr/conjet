use std::ptr::NonNull;

use bitflags::bitflags;
use thiserror::Error;

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct GuestMemoryFlags: u64 {
        const READ = 1;
        const WRITE = 2;
        const EXECUTE = 4;
    }
}

#[derive(Debug, Error)]
pub enum GuestMemoryError {
    #[error("guest memory size must be page aligned and non-zero")]
    InvalidSize,
    #[error("mmap failed: {0}")]
    MapFailed(std::io::Error),
    #[error("guest memory access at 0x{guest_address:x}+{size} exceeds RAM")]
    AccessOutOfRange { guest_address: u64, size: usize },
    #[error("guest memory range at 0x{guest_address:x}+{size} is not aligned to host page size {host_page_size}")]
    UnalignedHostRange {
        guest_address: u64,
        size: usize,
        host_page_size: usize,
    },
}

#[derive(Debug)]
pub struct GuestMemory {
    ptr: NonNull<libc::c_void>,
    len: usize,
}

unsafe impl Send for GuestMemory {}

impl GuestMemory {
    pub fn anonymous(len: usize) -> Result<Self, GuestMemoryError> {
        if len == 0 || len % page_size() != 0 {
            return Err(GuestMemoryError::InvalidSize);
        }
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                anonymous_mapping_flags(),
                -1,
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(GuestMemoryError::MapFailed(std::io::Error::last_os_error()));
        }
        Ok(Self {
            ptr: NonNull::new(ptr).expect("mmap returned null"),
            len,
        })
    }

    pub fn as_ptr(&self) -> *mut libc::c_void {
        self.ptr.as_ptr()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn host_page_size(&self) -> usize {
        page_size()
    }

    pub fn write(&self, offset: usize, bytes: &[u8]) {
        assert!(offset + bytes.len() <= self.len);
        unsafe {
            std::ptr::copy_nonoverlapping(
                bytes.as_ptr(),
                (self.ptr.as_ptr() as *mut u8).add(offset),
                bytes.len(),
            );
        }
    }

    pub fn read_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<Vec<u8>, GuestMemoryError> {
        let offset = self.offset_of(guest_base, guest_address, size)?;
        let mut out = vec![0u8; size];
        unsafe {
            std::ptr::copy_nonoverlapping(
                (self.ptr.as_ptr() as *const u8).add(offset),
                out.as_mut_ptr(),
                size,
            );
        }
        Ok(out)
    }

    pub fn write_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        bytes: &[u8],
    ) -> Result<(), GuestMemoryError> {
        let offset = self.offset_of(guest_base, guest_address, bytes.len())?;
        self.write(offset, bytes);
        Ok(())
    }

    pub fn read_le_u16(
        &self,
        guest_base: u64,
        guest_address: u64,
    ) -> Result<u16, GuestMemoryError> {
        let bytes = self.read_at(guest_base, guest_address, 2)?;
        Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
    }

    pub fn write_le_u16(
        &self,
        guest_base: u64,
        guest_address: u64,
        value: u16,
    ) -> Result<(), GuestMemoryError> {
        self.write_at(guest_base, guest_address, &value.to_le_bytes())
    }

    pub fn write_le_u32(
        &self,
        guest_base: u64,
        guest_address: u64,
        value: u32,
    ) -> Result<(), GuestMemoryError> {
        self.write_at(guest_base, guest_address, &value.to_le_bytes())
    }

    pub fn read_u32(&self, offset: usize) -> u32 {
        assert!(offset + std::mem::size_of::<u32>() <= self.len);
        unsafe {
            std::ptr::read_unaligned((self.ptr.as_ptr() as *const u8).add(offset) as *const u32)
        }
    }

    pub fn load_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        bytes: &[u8],
    ) -> Result<(), GuestMemoryError> {
        let offset = self.offset_of(guest_base, guest_address, bytes.len())?;
        self.write(offset, bytes);
        Ok(())
    }

    pub fn advise_free_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<(), GuestMemoryError> {
        self.validate_host_page_aligned(guest_base, guest_address, size)?;
        let address = self.host_address_at(guest_base, guest_address, size)?;
        let result = unsafe { libc::madvise(address, size, free_advice()) };
        if result == 0 {
            Ok(())
        } else {
            Err(GuestMemoryError::MapFailed(std::io::Error::last_os_error()))
        }
    }

    pub fn decommit_zero_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<*mut libc::c_void, GuestMemoryError> {
        self.validate_host_page_aligned(guest_base, guest_address, size)?;
        let address = self.host_address_at(guest_base, guest_address, size)?;
        if unsafe { libc::munmap(address, size) } != 0 {
            return Err(GuestMemoryError::MapFailed(std::io::Error::last_os_error()));
        }
        let result = unsafe {
            libc::mmap(
                address,
                size,
                libc::PROT_READ | libc::PROT_WRITE,
                anonymous_mapping_flags() | libc::MAP_FIXED,
                -1,
                0,
            )
        };
        if result == libc::MAP_FAILED {
            eprintln!(
                "fatal guest memory fixed remap failure after decommit at {address:p}+{size}: {}",
                std::io::Error::last_os_error()
            );
            std::process::abort();
        }
        if result != address {
            unsafe {
                libc::munmap(result, size);
            }
            eprintln!("fatal guest memory fixed remap returned {result:p} instead of {address:p}");
            std::process::abort();
        }
        Ok(result)
    }

    pub fn host_address_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<*mut libc::c_void, GuestMemoryError> {
        let offset = self.offset_of(guest_base, guest_address, size)?;
        Ok(unsafe { (self.ptr.as_ptr() as *mut u8).add(offset) as *mut libc::c_void })
    }

    fn offset_of(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<usize, GuestMemoryError> {
        let Some(offset) = guest_address.checked_sub(guest_base) else {
            return Err(GuestMemoryError::AccessOutOfRange {
                guest_address,
                size,
            });
        };
        let end = offset
            .checked_add(size as u64)
            .ok_or(GuestMemoryError::AccessOutOfRange {
                guest_address,
                size,
            })?;
        if end > self.len as u64 || offset > usize::MAX as u64 {
            return Err(GuestMemoryError::AccessOutOfRange {
                guest_address,
                size,
            });
        }
        Ok(offset as usize)
    }

    pub fn validate_host_page_aligned(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<(), GuestMemoryError> {
        let offset = self.offset_of(guest_base, guest_address, size)?;
        let host_page_size = self.host_page_size();
        if size == 0 || offset % host_page_size != 0 || size % host_page_size != 0 {
            return Err(GuestMemoryError::UnalignedHostRange {
                guest_address,
                size,
                host_page_size,
            });
        }
        Ok(())
    }
}

impl Drop for GuestMemory {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.ptr.as_ptr(), self.len);
        }
    }
}

fn page_size() -> usize {
    unsafe { libc::sysconf(libc::_SC_PAGESIZE) as usize }
}

fn anonymous_mapping_flags() -> libc::c_int {
    #[cfg(target_os = "macos")]
    {
        libc::MAP_PRIVATE | libc::MAP_ANON | libc::MAP_NORESERVE
    }
    #[cfg(not(target_os = "macos"))]
    {
        libc::MAP_PRIVATE | libc::MAP_ANON
    }
}

#[cfg(target_os = "macos")]
fn free_advice() -> libc::c_int {
    libc::MADV_FREE
}

#[cfg(not(target_os = "macos"))]
fn free_advice() -> libc::c_int {
    libc::MADV_DONTNEED
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    fn resident_pages_at(
        memory: &GuestMemory,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> usize {
        let address = memory
            .host_address_at(guest_base, guest_address, size)
            .unwrap();
        let page_count = size.div_ceil(page_size());
        let mut residency = vec![0i8; page_count];
        let rc = unsafe { libc::mincore(address, size, residency.as_mut_ptr()) };
        assert_eq!(rc, 0, "mincore failed: {}", std::io::Error::last_os_error());
        residency.iter().filter(|entry| **entry & 1 != 0).count()
    }

    #[test]
    fn decommit_zero_at_preserves_mapping_address_and_zeroes_range() {
        let guest_base = 0x4000_0000;
        let page_size = page_size();
        let memory = GuestMemory::anonymous(page_size * 2).unwrap();
        let guest_address = guest_base + page_size as u64;
        memory
            .write_at(guest_base, guest_address, &[0x5a; 64])
            .unwrap();

        let before = memory
            .host_address_at(guest_base, guest_address, page_size)
            .unwrap();
        let after = memory
            .decommit_zero_at(guest_base, guest_address, page_size)
            .unwrap();

        assert_eq!(after, before);
        assert_eq!(
            memory.read_at(guest_base, guest_address, 64).unwrap(),
            vec![0; 64]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn decommit_zero_at_drops_host_residency_until_refaulted() {
        let guest_base = 0x4000_0000;
        let page_size = page_size();
        let page_count = 4;
        let size = page_size * page_count;
        let memory = GuestMemory::anonymous(size).unwrap();
        let guest_address = guest_base;

        for page in 0..page_count {
            memory
                .write_at(
                    guest_base,
                    guest_address + (page * page_size) as u64,
                    &[0x5a],
                )
                .unwrap();
        }
        assert_eq!(
            resident_pages_at(&memory, guest_base, guest_address, size),
            page_count
        );

        memory
            .decommit_zero_at(guest_base, guest_address, size)
            .unwrap();

        assert_eq!(
            resident_pages_at(&memory, guest_base, guest_address, size),
            0
        );
        assert_eq!(
            memory
                .read_at(guest_base, guest_address, page_size)
                .unwrap(),
            vec![0; page_size]
        );
    }

    #[test]
    fn advise_free_at_preserves_mapping_address() {
        let guest_base = 0x4000_0000;
        let page_size = page_size();
        let memory = GuestMemory::anonymous(page_size * 2).unwrap();
        let guest_address = guest_base + page_size as u64;
        memory
            .write_at(guest_base, guest_address, &[0x5a; 64])
            .unwrap();

        let before = memory
            .host_address_at(guest_base, guest_address, page_size)
            .unwrap();
        memory
            .advise_free_at(guest_base, guest_address, page_size)
            .unwrap();
        let after = memory
            .host_address_at(guest_base, guest_address, page_size)
            .unwrap();

        assert_eq!(after, before);
    }
}
