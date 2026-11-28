use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::FileTypeExt;

pub(crate) const FD_ENV: &str = "CONJET_WORKLOAD_INPUT_FD";
pub(crate) const CHUNK: usize = 4096;

pub(crate) fn pipe() -> io::Result<(File, File)> {
    let mut descriptors = [-1; 2];
    crate::security::checked(unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) })?;
    let [reader, writer] = descriptors.map(|fd| unsafe { File::from_raw_fd(fd) });
    crate::security::checked(unsafe {
        libc::fcntl(writer.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK)
    })?;
    Ok((reader, writer))
}

pub(crate) fn inherited(expected: bool, tty: bool) -> io::Result<Option<File>> {
    match (expected, std::env::var_os(FD_ENV)) {
        (false, None) => Ok(None),
        (true, Some(value)) => {
            let fd = value
                .to_str()
                .and_then(|value| value.parse::<i32>().ok())
                .filter(|fd| *fd >= 3)
                .ok_or_else(|| io::Error::other("invalid inherited workload input"))?;
            crate::security::checked(unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) })?;
            // Only the supervisor's socket-owned setup can supply this inherited descriptor.
            let reader = unsafe { File::from_raw_fd(fd) };
            let valid = if tty {
                reader.metadata()?.file_type().is_char_device()
                    && unsafe { libc::isatty(reader.as_raw_fd()) } == 1
            } else {
                reader.metadata()?.file_type().is_fifo()
            };
            if !valid {
                return Err(io::Error::other("invalid inherited workload input type"));
            }
            Ok(Some(reader))
        }
        _ => Err(io::Error::other(
            "workload input did not match the launch spec",
        )),
    }
}

pub(crate) fn write(writer: &mut File, data: &[u8]) -> io::Result<bool> {
    match writer.write(data) {
        Ok(count) if count == data.len() => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
        Err(error) => Err(error),
        _ => Err(io::Error::other("partial workload input write")),
    }
}
