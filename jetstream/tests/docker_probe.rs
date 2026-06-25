use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use std::time::Duration;

use jetstream::vmm::docker_probe::DockerSocketReadinessProbe;

#[test]
fn docker_socket_probe_accepts_ping_response() {
    let dir = tempfile::tempdir().unwrap();
    let socket_path = dir.path().join("docker.sock");
    let listener = UnixListener::bind(&socket_path).unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let server_hits = hits.clone();

    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0u8; 256];
        let count = stream.read(&mut request).unwrap();
        assert!(String::from_utf8_lossy(&request[..count]).contains("GET /_ping HTTP/1.1"));
        server_hits.fetch_add(1, Ordering::SeqCst);
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
            .unwrap();
    });

    let report = DockerSocketReadinessProbe::new(&socket_path).wait_ready(
        Duration::from_secs(2),
        Duration::from_millis(10),
        || {},
    );

    server.join().unwrap();
    assert!(report.ok, "{report:?}");
    assert_eq!(report.status_code, Some(200));
    assert_eq!(report.response_body, "OK");
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}
