use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::sync::Arc;

use crate::security::checked;

const ROOT: &str = "/run/conjet/exec-pty";
const MOUNT_POINT: &std::ffi::CStr = c"/run/conjet/exec-pty";

pub(crate) struct Mount(bool);

impl Mount {
    pub(crate) fn open() -> io::Result<Self> {
        fs::DirBuilder::new().mode(0o700).create(ROOT)?;
        if let Err(error) = checked(unsafe {
            libc::mount(
                c"devpts".as_ptr(),
                MOUNT_POINT.as_ptr(),
                c"devpts".as_ptr(),
                libc::MS_NOSUID | libc::MS_NOEXEC,
                c"newinstance,ptmxmode=0600,mode=0600".as_ptr().cast(),
            )
        }) {
            fs::remove_dir(ROOT)?;
            return Err(error);
        }
        Ok(Self(true))
    }

    pub(crate) fn close(&mut self) -> io::Result<()> {
        if self.0 {
            checked(unsafe { libc::umount(MOUNT_POINT.as_ptr()) })?;
            self.0 = false;
            fs::remove_dir(ROOT)?;
        }
        Ok(())
    }
}

impl Drop for Mount {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

pub(crate) fn pair() -> io::Result<(Master, File)> {
    let master = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_NOFOLLOW)
        .open(format!("{ROOT}/ptmx"))?;
    let unlocked = 0i32;
    checked(unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSPTLCK, &unlocked) })?;
    // TIOCGPTPEER opens the kernel's matching slave without following a path.
    let slave = unsafe {
        libc::ioctl(
            master.as_raw_fd(),
            libc::TIOCGPTPEER,
            libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
        )
    };
    if slave < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((Master(Arc::new(master)), unsafe {
        File::from_raw_fd(slave)
    }))
}

#[derive(Clone)]
pub(crate) struct Master(Arc<File>);

impl Master {
    pub(crate) fn resize(&self, height: u16, width: u16) -> io::Result<()> {
        let size = libc::winsize {
            ws_row: height,
            ws_col: width,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        checked(unsafe { libc::ioctl(self.0.as_raw_fd(), libc::TIOCSWINSZ, &size) })
    }
}

impl Read for Master {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        match (&*self.0).read(output) {
            Err(error) if error.raw_os_error() == Some(libc::EIO) => Ok(0),
            result => result,
        }
    }
}
