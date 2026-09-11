//! Darwin accounting supplements RSS with compressed and reusable memory.

extern "C" {
    fn mach_port_deallocate(task: u32, name: u32) -> i32;
    fn mach_vm_page_range_query(
        task: u32,
        address: u64,
        size: u64,
        dispositions: u64,
        count: *mut u64,
    ) -> i32;
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum BackingDiscardError {
    #[error("backing page query failed with Mach error {0}")]
    QueryFailed(i32),
    #[error("backing page query returned {actual} entries, expected {expected}")]
    Incomplete { actual: u64, expected: u64 },
    #[error("backing at host address 0x{address:x} is still nonreusable (disposition 0x{disposition:x})")]
    Retained { address: u64, disposition: u32 },
}

#[allow(deprecated)]
pub(crate) fn ensure_backing_reusable(
    address: *mut libc::c_void,
    size: usize,
    page_size: usize,
) -> Result<(), BackingDiscardError> {
    // MADV_FREE_REUSABLE can silently skip busy/wired pages. Never orphan those
    // pages through MAP_FIXED. Query only the owned range, without faulting it
    // in, and use bounded stack storage (one query per <=64 MiB on Apple Silicon).
    const QUERY_PAGES: usize = 4096;
    const PRESENT: u32 = 0x001;
    const PAGED_OUT: u32 = 0x010;
    const REUSABLE: u32 = 0x800;
    let mut storage = std::mem::MaybeUninit::<[u32; QUERY_PAGES]>::uninit();
    let dispositions = storage.as_mut_ptr().cast::<u32>();
    for offset in (0..size).step_by(QUERY_PAGES * page_size) {
        let bytes = (size - offset).min(QUERY_PAGES * page_size);
        let expected = (bytes / page_size) as u64;
        let mut count = expected;
        let start = address as u64 + offset as u64;
        let rc = unsafe {
            mach_vm_page_range_query(
                libc::mach_task_self(),
                start,
                bytes as u64,
                dispositions as u64,
                &mut count,
            )
        };
        if rc != 0 {
            return Err(BackingDiscardError::QueryFailed(rc));
        }
        if count != expected {
            return Err(BackingDiscardError::Incomplete {
                actual: count,
                expected,
            });
        }
        // Only these entries were initialized by the successful kernel query.
        let entries = unsafe { std::slice::from_raw_parts(dispositions, count as usize) };
        for (index, &disposition) in entries.iter().enumerate() {
            if disposition & PAGED_OUT != 0
                || (disposition & PRESENT != 0 && disposition & REUSABLE == 0)
            {
                return Err(BackingDiscardError::Retained {
                    address: start + (index * page_size) as u64,
                    disposition,
                });
            }
        }
    }
    Ok(())
}

// libc does not expose TASK_VM_INFO's structure. Request only the stable rev1
// prefix from <mach/task_info.h>; Mach counts are 32-bit natural_t units.
#[repr(C)]
#[derive(Default)]
struct TaskVmInfoRev1 {
    virtual_size: u64,
    region_count: i32,
    page_size: i32,
    resident_size: u64,
    resident_size_peak: u64,
    device: u64,
    device_peak: u64,
    internal: u64,
    internal_peak: u64,
    external: u64,
    external_peak: u64,
    reusable: u64,
    reusable_peak: u64,
    purgeable_volatile_pmap: u64,
    purgeable_volatile_resident: u64,
    purgeable_volatile_virtual: u64,
    compressed: u64,
    compressed_peak: u64,
    compressed_lifetime: u64,
    phys_footprint: u64,
}

pub(crate) struct TaskMemory {
    // Logical bytes charged to this task, not the compressor's physical size.
    pub compressed_bytes: u64,
    pub reusable_bytes: u64,
}

#[allow(deprecated)]
pub(crate) fn task_memory() -> Option<TaskMemory> {
    const TASK_VM_INFO: u32 = 22;
    let mut info = TaskVmInfoRev1::default();
    let mut count = (std::mem::size_of::<TaskVmInfoRev1>() / 4) as u32;
    let required_count = count;
    let rc = unsafe {
        libc::task_info(
            libc::mach_task_self(),
            TASK_VM_INFO,
            (&mut info as *mut TaskVmInfoRev1).cast(),
            &mut count,
        )
    };
    (rc == 0 && count >= required_count).then_some(TaskMemory {
        compressed_bytes: info.compressed,
        reusable_bytes: info.reusable,
    })
}

pub(crate) struct SystemCompressor {
    pub physical_bytes: u64,
    pub logical_bytes: u64,
}

#[allow(deprecated)]
pub(crate) fn system_compressor() -> Option<SystemCompressor> {
    let mut info = std::mem::MaybeUninit::<libc::vm_statistics64>::zeroed();
    let mut count = libc::HOST_VM_INFO64_COUNT;
    let host = unsafe { libc::mach_host_self() };
    let rc = unsafe {
        libc::host_statistics64(
            host,
            libc::HOST_VM_INFO64,
            info.as_mut_ptr().cast(),
            &mut count,
        )
    };
    unsafe { mach_port_deallocate(libc::mach_task_self(), host) };
    if rc != 0 || count < libc::HOST_VM_INFO64_COUNT {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if page_size <= 0 {
        return None;
    }
    Some(SystemCompressor {
        physical_bytes: u64::from(info.compressor_page_count) * page_size as u64,
        logical_bytes: info.total_uncompressed_pages_in_compressor * page_size as u64,
    })
}

#[cfg(test)]
#[allow(deprecated)]
pub(crate) fn reusable_backing_pages(
    address: *mut libc::c_void,
    size: usize,
    page_size: usize,
) -> usize {
    let mut entries = vec![0u32; size / page_size];
    let mut count = entries.len() as u64;
    let rc = unsafe {
        mach_vm_page_range_query(
            libc::mach_task_self(),
            address as u64,
            size as u64,
            entries.as_mut_ptr() as u64,
            &mut count,
        )
    };
    assert_eq!(rc, 0, "mach_vm_page_range_query failed: {rc}");
    assert_eq!(count as usize, entries.len());
    entries.iter().filter(|&&entry| entry & 0x800 != 0).count()
}

#[cfg(test)]
#[allow(deprecated)]
pub(crate) fn nonreusable_backing_pages(address: *mut libc::c_void) -> u32 {
    // VM_REGION_TOP_INFO uses the original object's resident count minus its
    // reusable pages, capped to this mapping's size. A large, mostly untouched
    // live neighbor makes retained backing visible after a partial MAP_FIXED.
    #[repr(C)]
    #[derive(Default)]
    struct RegionTopInfo {
        object_id: u32,
        ref_count: u32,
        private_pages_resident: u32,
        shared_pages_resident: u32,
        share_mode: u8,
        padding: [u8; 3],
    }
    extern "C" {
        fn mach_vm_region(
            task: u32,
            address: *mut u64,
            size: *mut u64,
            flavor: i32,
            info: *mut i32,
            count: *mut u32,
            object_name: *mut u32,
        ) -> i32;
    }
    let mut address = address as u64;
    let mut size = 0;
    let mut info = RegionTopInfo::default();
    let mut count = (std::mem::size_of::<RegionTopInfo>() / 4) as u32;
    let mut object = 0;
    let rc = unsafe {
        mach_vm_region(
            libc::mach_task_self(),
            &mut address,
            &mut size,
            12, // VM_REGION_TOP_INFO
            (&mut info as *mut RegionTopInfo).cast(),
            &mut count,
            &mut object,
        )
    };
    if object != 0 {
        unsafe { mach_port_deallocate(libc::mach_task_self(), object) };
    }
    assert_eq!(rc, 0, "mach_vm_region failed: {rc}");
    info.private_pages_resident + info.shared_pages_resident
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_darwin_memory_accounting() {
        assert!(super::task_memory().is_some(), "TASK_VM_INFO unavailable");
        assert!(
            super::system_compressor().is_some(),
            "HOST_VM_INFO64 unavailable"
        );
    }
}
