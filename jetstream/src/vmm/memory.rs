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
    #[error("madvise({advice}) failed: {source}")]
    AdviceFailed {
        advice: libc::c_int,
        source: std::io::Error,
    },
    #[cfg(target_os = "macos")]
    #[error("backing discard could not be completed: {0}")]
    BackingDiscard(String),
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
        self.advise_at(guest_base, guest_address, size, free_advice())
    }

    pub fn advise_reusable_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<(), GuestMemoryError> {
        self.advise_at(guest_base, guest_address, size, reusable_advice())
    }

    pub fn advise_reuse_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<(), GuestMemoryError> {
        #[cfg(target_os = "macos")]
        {
            self.advise_at(guest_base, guest_address, size, libc::MADV_FREE_REUSE)
        }
        #[cfg(not(target_os = "macos"))]
        {
            self.validate_host_page_aligned(guest_base, guest_address, size)?;
            self.host_address_at(guest_base, guest_address, size)?;
            Ok(())
        }
    }

    pub fn advise_zero_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<(), GuestMemoryError> {
        #[cfg(target_os = "macos")]
        {
            self.advise_at(guest_base, guest_address, size, libc::MADV_ZERO)
        }
        #[cfg(not(target_os = "macos"))]
        {
            self.validate_host_page_aligned(guest_base, guest_address, size)?;
            let address = self.host_address_at(guest_base, guest_address, size)?;
            unsafe {
                std::ptr::write_bytes(address.cast::<u8>(), 0, size);
            }
            Ok(())
        }
    }

    pub fn decommit_zero_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
    ) -> Result<*mut libc::c_void, GuestMemoryError> {
        self.replace_backing_at(guest_base, guest_address, size, |address| {
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
                Err(GuestMemoryError::MapFailed(std::io::Error::last_os_error()))
            } else {
                Ok(result)
            }
        })
    }

    fn replace_backing_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
        replace: impl FnOnce(*mut libc::c_void) -> Result<*mut libc::c_void, GuestMemoryError>,
    ) -> Result<*mut libc::c_void, GuestMemoryError> {
        self.validate_host_page_aligned(guest_base, guest_address, size)?;
        let address = self.host_address_at(guest_base, guest_address, size)?;
        // The caller owns these pages and has detached their HVF mappings.
        // MAP_FIXED alone drops task accounting, but neighboring mappings can
        // keep the original VM object's dirty/compressed pages alive. Discard
        // that backing first: Darwin clears compressor slots and makes resident
        // pages clean and reusable without faulting them in or zeroing them.
        #[cfg(target_os = "macos")]
        if let Err(error) = self.advise_reusable_at(guest_base, guest_address, size) {
            self.cancel_backing_discard(guest_base, guest_address, size);
            return Err(error);
        }
        #[cfg(target_os = "macos")]
        if let Err(error) =
            super::macos_memory::ensure_backing_reusable(address, size, self.host_page_size())
        {
            self.cancel_backing_discard(guest_base, guest_address, size);
            return Err(GuestMemoryError::BackingDiscard(error.to_string()));
        }

        let result = match replace(address) {
            Ok(result) => result,
            Err(error) => {
                // The original mapping remains on replacement failure. Undo
                // reusability before a caller can restore HVF and ACK a report.
                #[cfg(target_os = "macos")]
                self.cancel_backing_discard(guest_base, guest_address, size);
                return Err(error);
            }
        };
        if result != address {
            unsafe {
                libc::munmap(result, size);
            }
            eprintln!("fatal guest memory fixed remap returned {result:p} instead of {address:p}");
            std::process::abort();
        }
        Ok(result)
    }

    #[cfg(target_os = "macos")]
    fn cancel_backing_discard(&self, guest_base: u64, guest_address: u64, size: usize) {
        if let Err(error) = self.advise_reuse_at(guest_base, guest_address, size) {
            eprintln!("fatal guest backing discard rollback failed: {error}");
            std::process::abort();
        }
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

    fn advise_at(
        &self,
        guest_base: u64,
        guest_address: u64,
        size: usize,
        advice: libc::c_int,
    ) -> Result<(), GuestMemoryError> {
        self.validate_host_page_aligned(guest_base, guest_address, size)?;
        let address = self.host_address_at(guest_base, guest_address, size)?;
        let result = unsafe { libc::madvise(address, size, advice) };
        if result == 0 {
            Ok(())
        } else {
            Err(GuestMemoryError::AdviceFailed {
                advice,
                source: std::io::Error::last_os_error(),
            })
        }
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

#[cfg(target_os = "macos")]
fn reusable_advice() -> libc::c_int {
    libc::MADV_FREE_REUSABLE
}

#[cfg(not(target_os = "macos"))]
fn reusable_advice() -> libc::c_int {
    libc::MADV_DONTNEED
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    fn partial_decommit_discards_original_nonreusable_backing() {
        use crate::vmm::macos_memory::nonreusable_backing_pages;

        let size = 8 * 1024 * 1024;
        let page = page_size();
        let memory = GuestMemory::anonymous(2 * size + page).unwrap();
        let base = 0x4000_0000;
        memory.write(0, &[0x5a]);
        memory.write(2 * size, &[0xa5]);
        for _ in 0..3 {
            for offset in (size..2 * size).step_by(page) {
                memory.write(offset, &[0x7f]);
            }
            memory
                .decommit_zero_at(base, base + size as u64, size)
                .unwrap();
            let retained = nonreusable_backing_pages(memory.as_ptr());
            assert!(
                retained <= 2,
                "original backing retains {retained} nonreusable pages after partial decommit"
            );
            assert_eq!(
                resident_pages_at(&memory, base, base + size as u64, size),
                0
            );
            assert_eq!(memory.read_at(base, base, 1).unwrap(), [0x5a]);
            assert_eq!(
                memory.read_at(base, base + (2 * size) as u64, 1).unwrap(),
                [0xa5]
            );
            assert_eq!(
                memory.read_at(base, base + size as u64, size).unwrap(),
                vec![0; size]
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn failed_replacement_cancels_reusability_before_returning() {
        use crate::vmm::macos_memory::{nonreusable_backing_pages, reusable_backing_pages};

        let page = page_size();
        let memory = GuestMemory::anonymous(page * 4).unwrap();
        for offset in (0..memory.len()).step_by(page) {
            memory.write(offset, &[0x7f]);
        }
        let error = memory
            .replace_backing_at(0, 0, memory.len(), |_| {
                assert_eq!(nonreusable_backing_pages(memory.as_ptr()), 0);
                Err(GuestMemoryError::MapFailed(
                    std::io::Error::from_raw_os_error(libc::ENOMEM),
                ))
            })
            .unwrap_err();
        assert!(matches!(error, GuestMemoryError::MapFailed(_)));
        // A restored HVF mapping must never expose still-reusable live pages.
        // Some pages may already have been evicted while reusable, so inspect
        // their disposition instead of assuming they all remain resident.
        assert_eq!(
            reusable_backing_pages(memory.as_ptr(), memory.len(), page),
            0
        );
        memory.write(0, &[0x5a]);
        assert_eq!(memory.read_at(0, 0, 1).unwrap(), [0x5a]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn wired_page_cannot_be_orphaned_after_advice_succeeds() {
        let page = page_size();
        let memory = GuestMemory::anonymous(page * 2).unwrap();
        memory.write(0, &[0x5a]);
        assert_eq!(unsafe { libc::mlock(memory.as_ptr(), page) }, 0);
        let result =
            memory.replace_backing_at(0, 0, page, |_| panic!("wired backing reached replacement"));
        assert_eq!(unsafe { libc::munlock(memory.as_ptr(), page) }, 0);
        assert!(matches!(result, Err(GuestMemoryError::BackingDiscard(_))));
        assert_eq!(memory.read_at(0, 0, 1).unwrap(), [0x5a]);
    }

    #[test]
    fn invalid_decommit_never_replaces_backing() {
        let page = page_size();
        let memory = GuestMemory::anonymous(page * 2).unwrap();
        for (address, size) in [
            (1, page),
            (0, 0),
            (0, page + 1),
            (page as u64, page * 2),
            (u64::MAX, page),
        ] {
            assert!(memory
                .replace_backing_at(0, address, size, |_| panic!(
                    "invalid range reached replacement"
                ))
                .is_err());
        }
    }

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

    #[test]
    fn decommit_zero_at_preserves_neighboring_pages() {
        let guest_base = 0x4000_0000;
        let page_size = page_size();
        let memory = GuestMemory::anonymous(page_size * 3).unwrap();
        let reclaim_address = guest_base + page_size as u64;

        memory
            .write_at(guest_base, guest_base, &[0x11; 64])
            .unwrap();
        memory
            .write_at(guest_base, reclaim_address, &[0x22; 64])
            .unwrap();
        memory
            .write_at(guest_base, guest_base + (page_size * 2) as u64, &[0x33; 64])
            .unwrap();

        memory
            .decommit_zero_at(guest_base, reclaim_address, page_size)
            .unwrap();

        assert_eq!(
            memory.read_at(guest_base, guest_base, 64).unwrap(),
            vec![0x11; 64]
        );
        assert_eq!(
            memory.read_at(guest_base, reclaim_address, 64).unwrap(),
            vec![0; 64]
        );
        assert_eq!(
            memory
                .read_at(guest_base, guest_base + (page_size * 2) as u64, 64)
                .unwrap(),
            vec![0x33; 64]
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

    #[cfg(target_os = "macos")]
    #[test]
    fn advise_reusable_at_requires_reuse_before_guest_access() {
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
            .advise_reusable_at(guest_base, guest_address, page_size)
            .unwrap();
        memory
            .advise_reuse_at(guest_base, guest_address, page_size)
            .unwrap();
        memory
            .write_at(guest_base, guest_address, &[0xa5; 64])
            .unwrap();
        let after = memory
            .host_address_at(guest_base, guest_address, page_size)
            .unwrap();

        assert_eq!(after, before);
        assert_eq!(
            memory.read_at(guest_base, guest_address, 64).unwrap(),
            vec![0xa5; 64]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn decommit_zero_replaces_reusable_backing_without_refaulting_it() {
        let guest_base = 0x4000_0000;
        let page_size = page_size();
        let memory = GuestMemory::anonymous(page_size * 2).unwrap();
        let guest_address = guest_base + page_size as u64;
        memory
            .write_at(guest_base, guest_address, &[0x5a; 64])
            .unwrap();
        memory
            .advise_reusable_at(guest_base, guest_address, page_size)
            .unwrap();

        memory
            .decommit_zero_at(guest_base, guest_address, page_size)
            .unwrap();

        assert_eq!(
            resident_pages_at(&memory, guest_base, guest_address, page_size),
            0
        );
        assert_eq!(
            memory.read_at(guest_base, guest_address, 64).unwrap(),
            vec![0; 64]
        );
    }

    #[test]
    fn advise_zero_at_discards_existing_contents_without_moving_the_mapping() {
        let page_size = page_size();
        let guest_base = 0x4000_0000;
        let memory = GuestMemory::anonymous(page_size * 2).unwrap();
        let address = guest_base + page_size as u64;
        memory.write_at(guest_base, address, &[0x5a; 64]).unwrap();
        let before = memory
            .host_address_at(guest_base, address, page_size)
            .unwrap();

        memory
            .advise_zero_at(guest_base, address, page_size)
            .unwrap();

        assert_eq!(
            memory
                .host_address_at(guest_base, address, page_size)
                .unwrap(),
            before
        );
        assert_eq!(
            memory.read_at(guest_base, address, 64).unwrap(),
            vec![0; 64]
        );
    }
}
