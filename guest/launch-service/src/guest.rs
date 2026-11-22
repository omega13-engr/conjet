use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::Path;
use std::sync::Arc;
use std::thread;

use crate::handshake::MAX_CONNECTIONS;
use crate::server::Server;
use crate::socket::{Stream, read_key, wait};

const SERVICE_PORT: u32 = 2380;

fn listener() -> io::Result<OwnedFd> {
    let fd = unsafe {
        libc::socket(
            libc::AF_VSOCK,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // The successful socket call returned a new descriptor; this is its sole owner.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    // sockaddr_vm is a C integer record, including zero-initialized reserved bytes.
    let mut address: libc::sockaddr_vm = unsafe { zeroed() };
    address.svm_family = libc::AF_VSOCK as libc::sa_family_t;
    address.svm_cid = libc::VMADDR_CID_ANY;
    address.svm_port = SERVICE_PORT;
    let bound = unsafe {
        libc::bind(
            fd.as_raw_fd(),
            (&address as *const libc::sockaddr_vm).cast(),
            size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        )
    };
    if bound != 0 || unsafe { libc::listen(fd.as_raw_fd(), MAX_CONNECTIONS as i32) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fd)
}

fn accept(listener: &OwnedFd) -> io::Result<Option<OwnedFd>> {
    let mut address: libc::sockaddr_vm = unsafe { zeroed() };
    let mut size = size_of::<libc::sockaddr_vm>() as libc::socklen_t;
    // accept4 writes only to the bounded sockaddr and returns an independent descriptor.
    let descriptor = unsafe {
        libc::accept4(
            listener.as_raw_fd(),
            (&mut address as *mut libc::sockaddr_vm).cast(),
            &mut size,
            libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
        )
    };
    if descriptor < 0 {
        let error = io::Error::last_os_error();
        return if matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
        ) {
            Ok(None)
        } else {
            Err(error)
        };
    }
    let fd = unsafe { OwnedFd::from_raw_fd(descriptor) };
    if size as usize != size_of::<libc::sockaddr_vm>()
        || i32::from(address.svm_family) != libc::AF_VSOCK
        || address.svm_cid != libc::VMADDR_CID_HOST
    {
        return Ok(None);
    }
    Ok(Some(fd))
}

pub fn serve(key_path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let server = Server::new(read_key(key_path)?)?;
    let shutdown = server.shutdown();
    let listener = listener()?;
    let mut workers: Vec<thread::JoinHandle<()>> = Vec::with_capacity(MAX_CONNECTIONS);
    println!("conjet-launchd ready");
    let result = loop {
        match wait(listener.as_raw_fd(), libc::POLLIN, Some(&shutdown), None) {
            Ok(()) => {}
            Err(_) if shutdown.requested() => break Ok(()),
            Err(error) => break Err(error),
        }
        let socket = match accept(&listener) {
            Ok(Some(socket)) => socket,
            Ok(None) => continue,
            Err(error) => break Err(error),
        };
        let mut index = 0;
        while index < workers.len() {
            if workers[index].is_finished() {
                let worker = workers.swap_remove(index);
                if worker.join().is_err() {
                    eprintln!("launch transport worker panicked");
                }
            } else {
                index += 1;
            }
        }
        if workers.len() == MAX_CONNECTIONS {
            // Admission is bounded even when a peer has sent no hello yet.
            continue;
        }
        let stream = Stream::nonblocking(socket, Some(Arc::clone(&shutdown)));
        let worker_server = Arc::clone(&server);
        match thread::Builder::new()
            .name("launch-connection".into())
            .spawn(move || {
                if let Err(error) = worker_server.serve(stream)
                    && !worker_server.shutdown().requested()
                {
                    eprintln!("launch connection closed: {error}");
                }
            }) {
            Ok(worker) => workers.push(worker),
            Err(error) => break Err(error),
        }
    };
    drop(listener);
    shutdown.request()?;
    for worker in workers {
        if worker.join().is_err() {
            eprintln!("launch transport worker panicked");
        }
    }
    Ok(result?)
}
