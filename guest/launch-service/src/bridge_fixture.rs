use std::ffi::CStr;
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::security::checked;
use crate::socket::wait;

const TIMEOUT: Duration = Duration::from_secs(3);
const BRIDGE: &CStr = c"cjbridge0";
const PORT: &CStr = c"cjport0";
const PEER: &CStr = c"cjpeer0";
const BRIDGE_IP: Ipv4Addr = Ipv4Addr::new(198, 18, 0, 1);
const PEER_IP: Ipv4Addr = Ipv4Addr::new(198, 18, 0, 2);
const PREFIX: u8 = 30;
const DNS_PORT: u16 = 53;
const CANARY_PORT: u16 = 8080;
pub(crate) const RESOLVER_CONFIG: &str = "nameserver 198.18.0.1\n";
const DNS_QUERY: &[u8] = b"\x39\xf2\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x05probe\x06conjet\x04test\x00\x00\x01\x00\x01";

fn kernel_address() -> libc::sockaddr_nl {
    // All optional fields, including multicast groups and destination port
    // ID, stay zero. The request addresses only the kernel.
    let mut address: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
    address.nl_family = libc::AF_NETLINK as libc::sa_family_t;
    address
}

struct Route {
    socket: OwnedFd,
    sequence: u32,
}

impl Route {
    fn open() -> io::Result<Self> {
        let descriptor = unsafe {
            libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC,
                libc::NETLINK_ROUTE,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            socket: unsafe { OwnedFd::from_raw_fd(descriptor) },
            sequence: 0,
        })
    }

    fn request(&mut self, kind: u16, flags: u16, payload: &[u8]) -> io::Result<()> {
        const HEADER: usize = 16;
        self.sequence += 1;
        let sequence = self.sequence;
        let mut message = Vec::with_capacity(HEADER + payload.len());
        message.extend_from_slice(&((HEADER + payload.len()) as u32).to_ne_bytes());
        message.extend_from_slice(&kind.to_ne_bytes());
        message.extend_from_slice(
            &(flags | libc::NLM_F_REQUEST as u16 | libc::NLM_F_ACK as u16).to_ne_bytes(),
        );
        message.extend_from_slice(&sequence.to_ne_bytes());
        message.extend_from_slice(&0u32.to_ne_bytes());
        message.extend_from_slice(payload);
        let fd = self.socket.as_raw_fd();
        let kernel = kernel_address();
        let count = unsafe {
            libc::sendto(
                fd,
                message.as_ptr().cast(),
                message.len(),
                0,
                (&kernel as *const libc::sockaddr_nl).cast(),
                size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            )
        };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        if count as usize != message.len() {
            return Err(io::ErrorKind::WriteZero.into());
        }
        wait(fd, libc::POLLIN, None, Some(Instant::now() + TIMEOUT))?;
        let mut reply = [0u8; 512];
        let mut sender = kernel_address();
        let mut length = size_of::<libc::sockaddr_nl>() as libc::socklen_t;
        let count = unsafe {
            libc::recvfrom(
                fd,
                reply.as_mut_ptr().cast(),
                reply.len(),
                libc::MSG_TRUNC | libc::MSG_DONTWAIT,
                (&mut sender as *mut libc::sockaddr_nl).cast(),
                &mut length,
            )
        };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        let size = u32::from_ne_bytes(reply[0..4].try_into().unwrap()) as usize;
        if length as usize != size_of::<libc::sockaddr_nl>()
            || sender.nl_family as libc::c_int != libc::AF_NETLINK
            || sender.nl_pid != 0
            || sender.nl_groups != 0
            || count as usize > reply.len()
            || !(HEADER + 4..=count as usize).contains(&size)
            || u16::from_ne_bytes(reply[4..6].try_into().unwrap()) != libc::NLMSG_ERROR as u16
            || u32::from_ne_bytes(reply[8..12].try_into().unwrap()) != sequence
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid route netlink ACK",
            ));
        }
        let status = i32::from_ne_bytes(reply[16..20].try_into().unwrap());
        match status {
            0 => Ok(()),
            status if status < 0 && status != i32::MIN => {
                Err(io::Error::from_raw_os_error(-status))
            }
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid route netlink status",
            )),
        }
    }

    fn create_link(&mut self, name: &CStr, kind: &CStr, data: &[u8]) -> io::Result<u32> {
        let mut link = link_message(0, 0);
        attribute(&mut link, libc::IFLA_IFNAME, name.to_bytes_with_nul());
        let mut info = Vec::new();
        attribute(&mut info, libc::IFLA_INFO_KIND, kind.to_bytes_with_nul());
        if !data.is_empty() {
            attribute(&mut info, libc::IFLA_INFO_DATA | NESTED, data);
        }
        attribute(&mut link, libc::IFLA_LINKINFO | NESTED, &info);
        self.request(
            libc::RTM_NEWLINK,
            (libc::NLM_F_CREATE | libc::NLM_F_EXCL) as u16,
            &link,
        )?;
        interface_index(name)
    }

    fn configure_link(&mut self, index: u32, up: bool, attrs: &[(u16, &[u8])]) -> io::Result<()> {
        let mut link = link_message(index, if up { libc::IFF_UP as u32 } else { 0 });
        for &(kind, data) in attrs {
            attribute(&mut link, kind, data);
        }
        self.request(libc::RTM_NEWLINK, 0, &link)
    }

    fn address(&mut self, index: u32, address: Ipv4Addr) -> io::Result<()> {
        let mut message = vec![libc::AF_INET as u8, PREFIX, 0, libc::RT_SCOPE_UNIVERSE];
        message.extend_from_slice(&index.to_ne_bytes());
        attribute(&mut message, libc::IFA_LOCAL, &address.octets());
        attribute(&mut message, libc::IFA_ADDRESS, &address.octets());
        self.request(
            libc::RTM_NEWADDR,
            (libc::NLM_F_CREATE | libc::NLM_F_EXCL) as u16,
            &message,
        )
    }

    fn remove(&mut self, index: u32) -> io::Result<()> {
        self.request(libc::RTM_DELLINK, 0, &link_message(index, 0))
    }
}

const NESTED: u16 = 1 << 15;
const VETH_INFO_PEER: u16 = 1;

fn attribute(message: &mut Vec<u8>, kind: u16, value: &[u8]) {
    let length = 4 + value.len();
    message.extend_from_slice(&(length as u16).to_ne_bytes());
    message.extend_from_slice(&kind.to_ne_bytes());
    message.extend_from_slice(value);
    message.resize(message.len() + (length.next_multiple_of(4) - length), 0);
}

fn link_message(index: u32, flags: u32) -> Vec<u8> {
    let mut message = vec![0; 4]; // AF_UNSPEC, pad, hardware type.
    message.extend_from_slice(&index.to_ne_bytes());
    message.extend_from_slice(&flags.to_ne_bytes());
    message.extend_from_slice(&flags.to_ne_bytes());
    message
}

fn interface_index(name: &CStr) -> io::Result<u32> {
    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
    if index == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(index)
    }
}

struct Links {
    route: Route,
    bridge: Option<u32>,
    port: Option<u32>,
    peer_namespace: Option<File>,
}

impl Links {
    fn create() -> io::Result<Self> {
        let mut links = Self {
            route: Route::open()?,
            bridge: None,
            port: None,
            peer_namespace: None,
        };
        let bridge = links.route.create_link(BRIDGE, c"bridge", &[])?;
        links.bridge = Some(bridge);
        let mut other = link_message(0, 0);
        attribute(&mut other, libc::IFLA_IFNAME, PEER.to_bytes_with_nul());
        let mut data = Vec::new();
        attribute(&mut data, VETH_INFO_PEER | NESTED, &other);
        let port = links.route.create_link(PORT, c"veth", &data)?;
        links.port = Some(port);
        links
            .route
            .configure_link(port, true, &[(libc::IFLA_MASTER, &bridge.to_ne_bytes())])?;
        links.route.configure_link(bridge, true, &[])?;
        links.route.address(bridge, BRIDGE_IP)?;
        Ok(links)
    }

    fn move_peer(&mut self, pid: u32) -> io::Result<()> {
        let peer_namespace = File::open(format!("/proc/{pid}/ns/net"))?;
        self.route.configure_link(
            interface_index(PEER)?,
            false,
            &[(
                libc::IFLA_NET_NS_FD,
                &peer_namespace.as_raw_fd().to_ne_bytes(),
            )],
        )?;
        self.peer_namespace = Some(peer_namespace);
        Ok(())
    }

    fn remove(&mut self) -> io::Result<()> {
        if let Some(port) = self.port {
            self.route.remove(port)?;
            self.port = None;
        }
        if let Some(bridge) = self.bridge {
            self.route.remove(bridge)?;
            self.bridge = None;
        }
        for link in [PORT, BRIDGE, PEER] {
            assert_link_absent(link)?;
        }
        assert_address_absent(BRIDGE_IP)
    }
}

impl Drop for Links {
    fn drop(&mut self) {
        if let Some(port) = self.port {
            let _ = self.route.remove(port);
        }
        if let Some(bridge) = self.bridge {
            let _ = self.route.remove(bridge);
        }
    }
}

fn assert_link_absent(name: &CStr) -> io::Result<()> {
    match interface_index(name) {
        Err(error) if error.raw_os_error() == Some(libc::ENODEV) => Ok(()),
        Ok(_) => Err(io::Error::other(
            "fixture network interface remained after cleanup",
        )),
        Err(error) => Err(error),
    }
}

fn assert_address_absent(address: Ipv4Addr) -> io::Result<()> {
    match TcpListener::bind((address, 0)) {
        Err(error) if error.kind() == io::ErrorKind::AddrNotAvailable => Ok(()),
        _ => Err(io::Error::other("fixture address remained usable")),
    }
}

pub(crate) struct Bridge {
    links: Links,
    dns: UdpSocket,
    canary: TcpListener,
}

impl Bridge {
    pub(crate) fn create() -> io::Result<Self> {
        // Only the dedicated single-threaded helper enters a new namespace.
        checked(unsafe { libc::unshare(libc::CLONE_NEWNET) })?;
        let links = Links::create()?;
        let dns = UdpSocket::bind((BRIDGE_IP, DNS_PORT))?;
        let canary = TcpListener::bind((BRIDGE_IP, CANARY_PORT))?;
        dns.set_nonblocking(true)?;
        canary.set_nonblocking(true)?;
        Ok(Self { links, dns, canary })
    }

    pub(crate) fn attach(&mut self, pid: libc::pid_t) -> io::Result<()> {
        self.links.move_peer(pid as u32)?;
        let peer = self.links.peer_namespace.as_ref().expect("moved peer");
        let original = File::open("/proc/self/ns/net")?;
        let result = in_namespace(peer, configure_peer);
        // Restore the helper's namespace even when peer configuration failed.
        enter_namespace(&original)?;
        result
    }

    pub(crate) fn poll_fds(&self) -> [libc::pollfd; 2] {
        [self.dns.as_raw_fd(), self.canary.as_raw_fd()].map(|fd| libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        })
    }

    pub(crate) fn receive_dns(&self) -> io::Result<()> {
        let mut packet = [0; 512];
        let (count, source) = self.dns.recv_from(&mut packet)?;
        if source.ip() != PEER_IP || &packet[..count] != DNS_QUERY {
            return Err(io::Error::other("unexpected DNS fixture query"));
        }
        let reply = dns_reply();
        if self.dns.send_to(&reply, source)? != reply.len() {
            return Err(io::ErrorKind::WriteZero.into());
        }
        Ok(())
    }

    pub(crate) fn receive_tcp(&self) -> io::Result<()> {
        let (mut stream, source) = self.canary.accept()?;
        if source.ip() != PEER_IP {
            return Err(io::Error::other("unexpected TCP fixture source"));
        }
        stream.set_read_timeout(Some(TIMEOUT))?;
        stream.set_write_timeout(Some(TIMEOUT))?;
        let mut request = [0; 4];
        stream.read_exact(&mut request)?;
        if &request != b"ping" {
            return Err(io::Error::other("bridge TCP fixture canary mismatch"));
        }
        stream.write_all(b"pong")
    }

    pub(crate) fn close(self) -> io::Result<()> {
        let Self {
            mut links,
            dns,
            canary,
        } = self;
        drop((dns, canary));
        links.remove()?;
        if let Some(peer) = &links.peer_namespace {
            let original = File::open("/proc/self/ns/net")?;
            let result = in_namespace(peer, || {
                assert_link_absent(PEER)?;
                assert_address_absent(PEER_IP)
            });
            enter_namespace(&original)?;
            result?;
        }
        Ok(())
    }
}

fn enter_namespace(target: &File) -> io::Result<()> {
    checked(unsafe { libc::setns(target.as_raw_fd(), libc::CLONE_NEWNET) })
}

fn in_namespace<T>(target: &File, work: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    enter_namespace(target)?;
    work()
}

fn configure_peer() -> io::Result<()> {
    let mut route = Route::open()?;
    let peer = interface_index(PEER)?;
    route.configure_link(peer, true, &[])?;
    route.address(peer, PEER_IP)?;
    assert_link_absent(BRIDGE)?;
    assert_link_absent(PORT)
}

fn dns_reply() -> Vec<u8> {
    let mut response = DNS_QUERY.to_vec();
    response[2..4].copy_from_slice(&[0x81, 0x80]); // Response, no error.
    response[7] = 1; // One answer.
    response.extend_from_slice(b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04");
    response.extend_from_slice(&BRIDGE_IP.octets());
    response
}

pub fn verify_workload() -> io::Result<()> {
    let raw = unsafe { libc::socket(libc::AF_INET, libc::SOCK_RAW | libc::SOCK_CLOEXEC, 0) };
    if raw >= 0 {
        unsafe { libc::close(raw) };
        return Err(io::Error::other(
            "bridge fixture unexpectedly opened a raw socket",
        ));
    }
    if io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
        return Err(io::Error::other(
            "unexpected restriction result for raw socket",
        ));
    }
    let configuration = std::fs::read_to_string("/etc/resolv.conf")?;
    if configuration != RESOLVER_CONFIG {
        return Err(io::Error::other(
            "unexpected private bridge resolver configuration",
        ));
    }
    let dns = UdpSocket::bind((PEER_IP, 0))?;
    dns.set_read_timeout(Some(TIMEOUT))?;
    dns.send_to(DNS_QUERY, (BRIDGE_IP, DNS_PORT))?;
    let mut packet = [0; 512];
    let (count, source) = dns.recv_from(&mut packet)?;
    if source != (BRIDGE_IP, DNS_PORT).into() || packet[..count] != dns_reply() {
        return Err(io::Error::other(
            "private bridge DNS response did not match",
        ));
    }
    let endpoint = SocketAddrV4::new(BRIDGE_IP, CANARY_PORT);
    let mut stream = TcpStream::connect(endpoint)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.write_all(b"ping")?;
    let mut response = [0; 4];
    stream.read_exact(&mut response)?;
    if &response != b"pong" {
        return Err(io::Error::other(
            "private bridge TCP response did not match",
        ));
    }
    println!("conjet-launchd workload verified private DNS and TCP");
    Ok(())
}

pub fn check() -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("bridge proof requires a disposable guest init".into());
    }
    let _proc = crate::kernel_fixture::ProcMount::new()?;
    checked(unsafe { libc::unshare(libc::CLONE_NEWNET) })?;
    for _ in 0..10 {
        traffic_and_teardown()?;
    }
    println!(
        "conjet-launchd verified private bridge address, peer traffic and link teardown across 10 allocations"
    );
    Ok(())
}

fn traffic_and_teardown() -> io::Result<()> {
    let (mut control, peer_control) = UnixStream::pair()?;
    control.set_read_timeout(Some(TIMEOUT))?;
    control.set_write_timeout(Some(TIMEOUT))?;
    let mut command = Command::new("/init");
    command
        .arg("--check-bridge-peer")
        .stdin(Stdio::from(OwnedFd::from(peer_control)));
    // Only a raw namespace syscall runs before exec.
    unsafe { command.pre_exec(|| checked(libc::unshare(libc::CLONE_NEWNET))) };
    let mut peer = command.spawn()?;
    let result = (|| {
        let peer_namespace = File::open(format!("/proc/{}/ns/net", peer.id()))?;
        let mut route = Route::open()?;
        let bridge = route.create_link(BRIDGE, c"bridge", &[])?;
        let mut other = link_message(0, 0);
        attribute(&mut other, libc::IFLA_IFNAME, PEER.to_bytes_with_nul());
        let mut data = Vec::new();
        attribute(&mut data, VETH_INFO_PEER | NESTED, &other);
        let port = route.create_link(PORT, c"veth", &data)?;
        let peer_link = interface_index(PEER)?;
        route.configure_link(
            peer_link,
            false,
            &[(
                libc::IFLA_NET_NS_FD,
                &peer_namespace.as_raw_fd().to_ne_bytes(),
            )],
        )?;
        route.configure_link(port, true, &[(libc::IFLA_MASTER, &bridge.to_ne_bytes())])?;
        route.configure_link(bridge, true, &[])?;
        route.address(bridge, BRIDGE_IP)?;
        let listener = TcpListener::bind((BRIDGE_IP, 0))?;
        let port_number = listener.local_addr()?.port();
        control.write_all(&port_number.to_le_bytes())?;
        wait(
            listener.as_raw_fd(),
            libc::POLLIN,
            None,
            Some(Instant::now() + TIMEOUT),
        )?;
        let (mut stream, source) = listener.accept()?;
        if source.ip() != PEER_IP {
            return Err(io::Error::other(
                "bridge traffic used the wrong source address",
            ));
        }
        stream.set_read_timeout(Some(TIMEOUT))?;
        stream.set_write_timeout(Some(TIMEOUT))?;
        let mut request = [0; 4];
        stream.read_exact(&mut request)?;
        if &request != b"ping" {
            return Err(io::Error::other("bridge application canary mismatch"));
        }
        stream.write_all(b"pong")?;
        let mut checked_reply = [0];
        control.read_exact(&mut checked_reply)?;
        if checked_reply != [1] {
            return Err(io::Error::other("bridge peer did not verify the response"));
        }
        drop((listener, stream));
        route.remove(port)?;
        route.remove(bridge)?;
        for interface in [PORT, BRIDGE, PEER] {
            if interface_index(interface).is_ok() {
                return Err(io::Error::other(
                    "fixture network interface remained after cleanup",
                ));
            }
        }
        control.write_all(&[2])?;
        control.read_exact(&mut checked_reply)?;
        if checked_reply != [2] {
            return Err(io::Error::other("bridge peer did not verify teardown"));
        }
        match TcpListener::bind((BRIDGE_IP, 0)) {
            Err(error) if error.kind() == io::ErrorKind::AddrNotAvailable => Ok(()),
            _ => Err(io::Error::other("fixture bridge address remained usable")),
        }
    })();
    if result.is_err() {
        peer.kill()?;
    }
    let status = peer.wait()?;
    result?;
    if !status.success() {
        return Err(io::Error::other("bridge fixture peer failed"));
    }
    Ok(())
}

pub fn check_peer() -> io::Result<()> {
    if unsafe { libc::getppid() } != 1 {
        return Err(io::Error::other(
            "bridge peer requires the disposable guest init",
        ));
    }
    let mut control = UnixStream::from(unsafe { OwnedFd::from_raw_fd(0) });
    control.set_read_timeout(Some(TIMEOUT))?;
    control.set_write_timeout(Some(TIMEOUT))?;
    let mut port = [0; 2];
    control.read_exact(&mut port)?;
    let mut route = Route::open()?;
    let peer = interface_index(PEER)?;
    route.configure_link(peer, true, &[])?;
    route.address(peer, PEER_IP)?;
    if interface_index(BRIDGE).is_ok() || interface_index(PORT).is_ok() {
        return Err(io::Error::other(
            "bridge leaked parent-side links into its peer",
        ));
    }
    let endpoint = SocketAddrV4::new(BRIDGE_IP, u16::from_le_bytes(port));
    let mut stream = TcpStream::connect_timeout(&endpoint.into(), TIMEOUT)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.write_all(b"ping")?;
    let mut response = [0; 4];
    stream.read_exact(&mut response)?;
    if &response != b"pong" {
        return Err(io::Error::other("bridge peer canary mismatch"));
    }
    control.write_all(&[1])?;
    let mut check_teardown = [0];
    control.read_exact(&mut check_teardown)?;
    if check_teardown != [2] || interface_index(PEER).is_ok() {
        return Err(io::Error::other(
            "veth peer remained after parent removed link",
        ));
    }
    match TcpListener::bind((PEER_IP, 0)) {
        Err(error) if error.kind() == io::ErrorKind::AddrNotAvailable => control.write_all(&[2]),
        _ => Err(io::Error::other("fixture peer address remained usable")),
    }
}
