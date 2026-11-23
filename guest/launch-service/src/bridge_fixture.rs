use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::bridge_dns;
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
const OWNED_LINK_GROUP: u32 = 287;
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
        attribute(&mut link, libc::IFLA_GROUP, &OWNED_LINK_GROUP.to_ne_bytes());
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
        self.address_with_prefix(index, address, PREFIX)
    }

    fn address_with_prefix(&mut self, index: u32, address: Ipv4Addr, prefix: u8) -> io::Result<()> {
        let mut message = vec![libc::AF_INET as u8, prefix, 0, libc::RT_SCOPE_UNIVERSE];
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

    fn attach_peer(&mut self, name: &CStr, target: &File) -> io::Result<u32> {
        let mut peer = link_message(0, 0);
        attribute(&mut peer, libc::IFLA_IFNAME, PEER.to_bytes_with_nul());
        attribute(
            &mut peer,
            libc::IFLA_NET_NS_FD,
            &target.as_raw_fd().to_ne_bytes(),
        );
        let mut data = Vec::new();
        attribute(&mut data, VETH_INFO_PEER | NESTED, &peer);
        self.create_link(name, c"veth", &data)
    }

    fn remove_owned_group(&mut self) -> io::Result<()> {
        let mut link = link_message(0, 0);
        attribute(&mut link, libc::IFLA_GROUP, &OWNED_LINK_GROUP.to_ne_bytes());
        self.request(libc::RTM_DELLINK, 0, &link)
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
        links.route.configure_link(bridge, true, &[])?;
        links.route.address(bridge, BRIDGE_IP)?;
        Ok(links)
    }

    fn attach_peer(&mut self, pid: u32) -> io::Result<()> {
        let bridge = self
            .bridge
            .ok_or_else(|| io::Error::other("bridge link is not live"))?;
        let peer_namespace = File::open(format!("/proc/{pid}/ns/net"))?;
        // Register the peer in its final namespace, avoiding the separate
        // namespace move and its network grace period.
        let port = self.route.attach_peer(PORT, &peer_namespace)?;
        self.port = Some(port);
        self.route
            .configure_link(port, true, &[(libc::IFLA_MASTER, &bridge.to_ne_bytes())])?;
        self.peer_namespace = Some(peer_namespace);
        Ok(())
    }

    fn remove(&mut self) -> io::Result<()> {
        if self.bridge.is_some() || self.port.is_some() {
            // Only the bridge and parent veth are tagged in this workload's
            // private network namespace. The kernel unregisters both devices
            // together and the acknowledgement still precedes our checks.
            self.route.remove_owned_group()?;
            self.bridge = None;
            self.port = None;
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
        self.links.attach_peer(pid as u32)?;
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

const SHARED_PREFIX: u8 = 28;

struct BridgePort {
    index: u32,
    name: CString,
    target: File,
    address: Ipv4Addr,
    alias: Option<String>,
}

struct SharedLinks {
    route: Route,
    bridge: u32,
    namespace: File,
    ports: [Option<BridgePort>; 8],
}

impl SharedLinks {
    fn create() -> io::Result<Self> {
        checked(unsafe { libc::unshare(libc::CLONE_NEWNET) })?;
        let mut route = Route::open()?;
        let namespace = File::open("/proc/self/ns/net")?;
        let bridge = route.create_link(BRIDGE, c"bridge", &[])?;
        let mut links = Self {
            route,
            bridge,
            namespace,
            ports: Default::default(),
        };
        links.route.configure_link(bridge, true, &[])?;
        links
            .route
            .address_with_prefix(bridge, BRIDGE_IP, SHARED_PREFIX)?;
        Ok(links)
    }

    fn attach(&mut self, slot: usize, target: File, alias: &str) -> io::Result<Ipv4Addr> {
        if !bridge_dns::valid_name(alias) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid bridge alias",
            ));
        }
        if self.ports.iter().flatten().any(|port| {
            port.alias
                .as_ref()
                .is_some_and(|name| name.eq_ignore_ascii_case(alias))
        }) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "bridge alias is occupied",
            ));
        }
        let owner = self
            .ports
            .get_mut(slot)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid bridge slot"))?;
        if owner.is_some() || target.metadata()?.ino() == self.namespace.metadata()?.ino() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "invalid bridge peer ownership",
            ));
        }
        let name = CString::new(format!("cjport{slot}")).expect("numeric link name");
        let address = Ipv4Addr::new(198, 18, 0, 2 + slot as u8);
        let index = self.route.attach_peer(&name, &target)?;
        *owner = Some(BridgePort {
            index,
            name,
            target,
            address,
            alias: None,
        });
        let port = owner.as_ref().expect("owned bridge port");
        let result = (|| {
            self.route.configure_link(
                index,
                true,
                &[(libc::IFLA_MASTER, &self.bridge.to_ne_bytes())],
            )?;
            let configured = in_namespace(&port.target, || {
                assert_link_absent(BRIDGE)?;
                let mut route = Route::open()?;
                let peer = interface_index(PEER)?;
                route.configure_link(peer, true, &[])?;
                route.address_with_prefix(peer, address, SHARED_PREFIX)
            });
            enter_namespace(&self.namespace)?;
            configured
        })();
        if let Err(error) = result {
            self.detach(slot)?;
            return Err(error);
        }
        owner.as_mut().expect("owned bridge port").alias = Some(alias.to_ascii_lowercase());
        Ok(address)
    }

    fn receive_dns(&self, socket: &UdpSocket) -> io::Result<()> {
        let mut packet = [0; bridge_dns::MAX_MESSAGE + 1];
        let (count, source) = socket.recv_from(&mut packet)?;
        if !self
            .ports
            .iter()
            .flatten()
            .any(|port| port.alias.is_some() && source.ip() == port.address)
        {
            return Ok(());
        }
        let reply = bridge_dns::answer(&packet[..count], |name| {
            self.ports
                .iter()
                .flatten()
                .find_map(|port| (port.alias.as_deref() == Some(name)).then_some(port.address))
        });
        if let Some(reply) = reply
            && socket.send_to(&reply, source)? != reply.len()
        {
            return Err(io::ErrorKind::WriteZero.into());
        }
        Ok(())
    }

    fn detach(&mut self, slot: usize) -> io::Result<()> {
        let owner = self
            .ports
            .get_mut(slot)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid bridge slot"))?;
        let port = owner
            .as_ref()
            .ok_or_else(|| io::Error::other("bridge slot is empty"))?;
        self.route.remove(port.index)?;
        assert_link_absent(&port.name)?;
        let result = in_namespace(&port.target, || {
            assert_link_absent(PEER)?;
            assert_address_absent(port.address)
        });
        enter_namespace(&self.namespace)?;
        result?;
        *owner = None;
        Ok(())
    }

    fn close(mut self) -> io::Result<()> {
        for slot in 0..self.ports.len() {
            if self.ports[slot].is_some() {
                self.detach(slot)?;
            }
        }
        self.route.remove(self.bridge)?;
        self.bridge = 0;
        assert_link_absent(BRIDGE)?;
        assert_address_absent(BRIDGE_IP)
    }
}

impl Drop for SharedLinks {
    fn drop(&mut self) {
        for port in self.ports.iter().flatten() {
            let _ = self.route.remove(port.index);
        }
        if self.bridge != 0 {
            let _ = self.route.remove(self.bridge);
        }
    }
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

pub fn check_available() -> io::Result<()> {
    if unsafe { libc::getppid() } <= 1 {
        return Err(io::Error::other(
            "bridge availability check requires a fixture supervisor",
        ));
    }
    Bridge::create()?.close()?;
    traffic_and_teardown(None, 0)
}

pub fn check() -> Result<(), Box<dyn std::error::Error>> {
    if std::process::id() != 1 {
        return Err("bridge proof requires a disposable guest init".into());
    }
    let _proc = crate::kernel_fixture::ProcMount::new()?;
    checked(unsafe { libc::unshare(libc::CLONE_NEWNET) })?;
    for _ in 0..10 {
        traffic_and_teardown(None, 0)?;
    }
    println!(
        "conjet-launchd verified private bridge address, peer traffic and link teardown across 10 allocations"
    );
    for _ in 0..5 {
        check_concurrent()?;
    }
    println!(
        "conjet-launchd verified overlapping IPv4 and TCP bindings in two simultaneous private bridge scopes across 5 rounds"
    );
    Ok(())
}

struct FixtureProcess {
    child: Child,
    control: UnixStream,
}

impl FixtureProcess {
    fn spawn(mode: &str) -> io::Result<Self> {
        let (control, peer_control) = UnixStream::pair()?;
        control.set_read_timeout(Some(TIMEOUT))?;
        control.set_write_timeout(Some(TIMEOUT))?;
        let mut command = Command::new("/init");
        command
            .arg(mode)
            .arg(std::process::id().to_string())
            .stdin(Stdio::from(OwnedFd::from(peer_control)));
        // Only a raw namespace syscall runs before exec.
        unsafe { command.pre_exec(|| checked(libc::unshare(libc::CLONE_NEWNET))) };
        let child = command.spawn()?;
        Ok(Self { child, control })
    }

    fn finish(&mut self) -> io::Result<()> {
        if !self.child.wait()?.success() {
            return Err(io::Error::other("bridge fixture subprocess failed"));
        }
        Ok(())
    }
}

impl Drop for FixtureProcess {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn fixture_control(parent: u32) -> io::Result<UnixStream> {
    if unsafe { libc::getppid() } as u32 != parent || parent == 0 {
        return Err(io::Error::other("bridge fixture owner identity mismatch"));
    }
    // The launcher supplies FD 0 as this process's private control stream.
    let control = UnixStream::from(unsafe { OwnedFd::from_raw_fd(0) });
    control.set_read_timeout(Some(TIMEOUT))?;
    control.set_write_timeout(Some(TIMEOUT))?;
    Ok(control)
}

fn read_byte(stream: &mut UnixStream) -> io::Result<u8> {
    let mut byte = [0];
    stream.read_exact(&mut byte)?;
    Ok(byte[0])
}

pub fn check_shared() -> io::Result<()> {
    if std::process::id() != 1 {
        return Err(io::Error::other(
            "shared bridge proof requires a disposable guest init",
        ));
    }
    let _proc = crate::kernel_fixture::ProcMount::new()?;
    let untouched = File::open("/proc/self/ns/net")?;
    let mut bridge = SharedLinks::create()?;
    let dns = UdpSocket::bind((BRIDGE_IP, DNS_PORT))?;
    dns.set_read_timeout(Some(TIMEOUT))?;
    let target =
        |process: &FixtureProcess| File::open(format!("/proc/{}/ns/net", process.child.id()));
    let mut server = FixtureProcess::spawn("--check-shared-bridge-peer")?;
    let mut client = FixtureProcess::spawn("--check-shared-bridge-peer")?;
    let failed = FixtureProcess::spawn("--check-shared-bridge-peer")?;
    let configured = in_namespace(&target(&failed)?, || {
        Route::open()?.create_link(BRIDGE, c"bridge", &[])?;
        Ok(())
    });
    enter_namespace(&bridge.namespace)?;
    configured?;
    if bridge.attach(1, target(&failed)?, "client").is_ok() || bridge.ports[1].is_some() {
        return Err(io::Error::other(
            "partial peer allocation did not roll back",
        ));
    }
    let server_ip = bridge.attach(0, target(&server)?, "service")?;
    let client_ip = bridge.attach(1, target(&client)?, "client")?;
    if bridge.attach(1, target(&failed)?, "retry").is_ok()
        || bridge.attach(2, target(&failed)?, "Service").is_ok()
        || server_ip == client_ip
    {
        return Err(io::Error::other(
            "bridge did not preserve distinct address ownership",
        ));
    }
    server.control.write_all(&[1])?;
    if read_byte(&mut server.control)? != 1 {
        return Err(io::Error::other("bridge server did not bind"));
    }
    client.control.write_all(&[2])?;
    bridge.receive_dns(&dns)?;
    bridge.receive_dns(&dns)?;
    if read_byte(&mut client.control)? != 1 || read_byte(&mut server.control)? != 2 {
        return Err(io::Error::other("bridge TCP verification failed"));
    }
    bridge.detach(1)?;
    client.control.write_all(&[3])?;
    client.finish()?;
    // A replacement inherits the free address while the server and its
    // listening socket remain live.
    let mut replacement = FixtureProcess::spawn("--check-shared-bridge-peer")?;
    if bridge.attach(1, target(&replacement)?, "replacement")? != client_ip {
        return Err(io::Error::other("bridge address was not reused"));
    }
    replacement.control.write_all(&[4])?;
    bridge.receive_dns(&dns)?;
    bridge.receive_dns(&dns)?;
    if read_byte(&mut replacement.control)? != 1 || read_byte(&mut server.control)? != 2 {
        return Err(io::Error::other(
            "sibling listener did not survive replacement",
        ));
    }
    drop(dns);
    bridge.close()?;
    for peer in [&mut server, &mut replacement] {
        peer.control.write_all(&[3])?;
        peer.finish()?;
    }
    enter_namespace(&untouched)?;
    assert_link_absent(BRIDGE)?;
    assert_address_absent(BRIDGE_IP)?;
    println!(
        "conjet-launchd verified shared bridge TCP, rollback, address reuse and isolated teardown"
    );
    println!(
        "conjet-launchd verified live DNS aliases, duplicate rejection and removal on peer detach"
    );
    Ok(())
}

fn resolve_peer(name: &[u8], own: Ipv4Addr) -> io::Result<Option<Ipv4Addr>> {
    let dns = UdpSocket::bind((own, 0))?;
    dns.set_read_timeout(Some(TIMEOUT))?;
    dns.connect((BRIDGE_IP, DNS_PORT))?;
    let mut query = vec![0x4a, 0x1b, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, name.len() as u8];
    query.extend_from_slice(name);
    query.extend_from_slice(&[0, 0, 1, 0, 1]);
    dns.send(&query)?;
    let mut reply = [0; bridge_dns::MAX_MESSAGE];
    let count = dns.recv(&mut reply)?;
    if count != query.len() && count != query.len() + 16
        || reply[..2] != query[..2]
        || reply[2] != 0x85
        || reply[12..query.len()] != query[12..]
    {
        return Err(io::Error::other("unexpected DNS canary response"));
    }
    match (reply[3], reply[7], count - query.len()) {
        (0, 1, 16) => Ok(Some(Ipv4Addr::from(
            <[u8; 4]>::try_from(&reply[count - 4..count]).unwrap(),
        ))),
        (3, 0, 0) => Ok(None),
        _ => Err(io::Error::other("unexpected DNS canary answer")),
    }
}

pub fn check_shared_peer(parent: u32) -> io::Result<()> {
    let mut control = fixture_control(parent)?;
    let server = Ipv4Addr::new(198, 18, 0, 2);
    let client = Ipv4Addr::new(198, 18, 0, 3);
    assert_link_absent(BRIDGE)?;
    let role = read_byte(&mut control)?;
    let own = match role {
        1 => {
            let listener = TcpListener::bind((server, CANARY_PORT))?;
            control.write_all(&[1])?;
            for _ in 0..2 {
                wait(
                    listener.as_raw_fd(),
                    libc::POLLIN,
                    None,
                    Some(Instant::now() + TIMEOUT),
                )?;
                let (mut stream, from) = listener.accept()?;
                stream.set_read_timeout(Some(TIMEOUT))?;
                stream.set_write_timeout(Some(TIMEOUT))?;
                let mut request = [0; 4];
                stream.read_exact(&mut request)?;
                if from.ip() != client || &request != b"ping" {
                    return Err(io::Error::other("wrong canary request"));
                }
                stream.write_all(b"pong")?;
                control.write_all(&[2])?;
            }
            server
        }
        2 | 4 => {
            let endpoint = resolve_peer(b"SeRvIcE", client)?
                .filter(|ip| *ip == server)
                .ok_or_else(|| io::Error::other("DNS did not resolve the service peer"))?;
            let expected = (role == 2).then_some(client);
            if resolve_peer(b"client", client)? != expected {
                return Err(io::Error::other("DNS alias did not follow peer detach"));
            }
            let mut stream = TcpStream::connect_timeout(&(endpoint, CANARY_PORT).into(), TIMEOUT)?;
            stream.set_read_timeout(Some(TIMEOUT))?;
            stream.set_write_timeout(Some(TIMEOUT))?;
            stream.write_all(b"ping")?;
            let mut reply = [0; 4];
            stream.read_exact(&mut reply)?;
            if &reply != b"pong" {
                return Err(io::Error::other("wrong canary response"));
            }
            control.write_all(&[1])?;
            client
        }
        _ => return Err(io::Error::other("invalid shared bridge peer role")),
    };
    if read_byte(&mut control)? != 3 {
        return Err(io::Error::other("missing bridge teardown signal"));
    }
    assert_link_absent(PEER)?;
    assert_address_absent(own)
}

fn check_concurrent() -> io::Result<()> {
    let mut first = FixtureProcess::spawn("--check-bridge-scope")?;
    let mut second = FixtureProcess::spawn("--check-bridge-scope")?;
    let namespace_inode = |process: &FixtureProcess| {
        std::fs::metadata(format!("/proc/{}/ns/net", process.child.id())).map(|info| info.ino())
    };
    if namespace_inode(&first)? == namespace_inode(&second)? {
        return Err(io::Error::other(
            "concurrent bridge scopes share a namespace",
        ));
    }
    first.control.write_all(&[0x5a])?;
    second.control.write_all(&[0xa5])?;
    for process in [&mut first, &mut second] {
        if read_byte(&mut process.control)? != 1 {
            return Err(io::Error::other(
                "concurrent bridge scope did not finish binding",
            ));
        }
    }
    // Both bridge IPs and port bindings are alive before either accepts
    // traffic. Their distinct canaries detect any crossing between scopes.
    for process in [&mut first, &mut second] {
        process.control.write_all(&[2])?;
    }
    first.finish()?;
    second.finish()
}

pub fn check_scope(parent: u32) -> io::Result<()> {
    let mut coordinator = fixture_control(parent)?;
    let marker = read_byte(&mut coordinator)?;
    traffic_and_teardown(Some(&mut coordinator), marker)
}

fn traffic_and_teardown(coordinator: Option<&mut UnixStream>, marker: u8) -> io::Result<()> {
    let mut peer = FixtureProcess::spawn("--check-bridge-peer")?;
    let mut links = Links::create()?;
    links.attach_peer(peer.child.id())?;
    let listening_port = if coordinator.is_some() {
        CANARY_PORT
    } else {
        0
    };
    let listener = TcpListener::bind((BRIDGE_IP, listening_port))?;
    if let Some(coordinator) = coordinator {
        coordinator.write_all(&[1])?;
        if read_byte(coordinator)? != 2 {
            return Err(io::Error::other(
                "fixture coordinator did not release bridge peers",
            ));
        }
    }
    let control = &mut peer.control;
    let port_number = listener.local_addr()?.port();
    control.write_all(&port_number.to_le_bytes())?;
    control.write_all(&[marker])?;
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
    let mut request = [0; 5];
    stream.read_exact(&mut request)?;
    if &request[..4] != b"ping" || request[4] != marker {
        return Err(io::Error::other("bridge application canary mismatch"));
    }
    stream.write_all(b"pong")?;
    stream.write_all(&[marker])?;
    if read_byte(control)? != 1 {
        return Err(io::Error::other("bridge peer did not verify the response"));
    }
    drop((listener, stream));
    links.remove()?;
    control.write_all(&[2])?;
    if read_byte(control)? != 2 {
        return Err(io::Error::other("bridge peer did not verify teardown"));
    }
    peer.finish()
}

pub fn check_peer(parent: u32) -> io::Result<()> {
    let mut control = fixture_control(parent)?;
    let mut port = [0; 2];
    control.read_exact(&mut port)?;
    let marker = read_byte(&mut control)?;
    configure_peer()?;
    let endpoint = SocketAddrV4::new(BRIDGE_IP, u16::from_le_bytes(port));
    let mut stream = TcpStream::connect_timeout(&endpoint.into(), TIMEOUT)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.write_all(b"ping")?;
    stream.write_all(&[marker])?;
    let mut response = [0; 5];
    stream.read_exact(&mut response)?;
    if &response[..4] != b"pong" || response[4] != marker {
        return Err(io::Error::other("bridge peer canary mismatch"));
    }
    control.write_all(&[1])?;
    if read_byte(&mut control)? != 2 {
        return Err(io::Error::other(
            "bridge peer did not receive teardown request",
        ));
    }
    assert_link_absent(PEER)?;
    assert_address_absent(PEER_IP)?;
    control.write_all(&[2])
}
