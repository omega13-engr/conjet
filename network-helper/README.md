# Host network helper

`conjet-network` is an unprivileged Ethernet-to-host-socket backend for the Rust
Jetstream VMM. It embeds `github.com/containers/gvisor-tap-vsock` **v0.8.9**;
`go.mod` and `go.sum` pin its dependency graph. Reusing the maintained TCP/IP stack
avoids introducing a custom TCP implementation. This adds Go to source builds,
not to VM execution or the installed machine's tool requirements.

Build from the repository root:

```sh
build-support/build-network-helper.sh /path/to/jetstream-directory/conjet-network
CGO_ENABLED=1 go test -C network-helper -race ./...
```

Jetstream starts the adjacent helper (or `CONJET_NETWORK_HELPER_PATH`) with one
end of a Unix socketpair as stdin and forces `GODEBUG=netdns=cgo`. Build with CGO
enabled to use native Darwin address resolution. No socket pathname, TCP listener,
HTTP administration server, or upstream automatic port forwards are exposed.
ConjetNet continues to own published ports independently over VSOCK.

The helper writes `CJNET1\n` after initialization. Subsequent traffic in both
directions uses QEMU Ethernet framing: a four-byte unsigned big-endian length
followed by an Ethernet frame. Jetstream validates lengths (14–1514 bytes),
retains fragmented frames/partial writes, and caps each direction's queue at
256 frames. Peer EOF or termination ends the helper; Jetstream reaps its child.
Failure never silently falls back to vmnet. That could bypass the user's chosen
network policy.

The subnet is `172.31.64.0/24`, with gateway/DNS `.1`, guest lease `.2`, and Mac
loopback alias `.254`. IPv4 TCP/UDP egress uses normal macOS sockets and new flows
follow route changes. Existing connections may need application reconnection.
External IPv6, raw ICMP, and automatic system HTTP proxy configuration are outside
this backend's current capabilities. See [networking](../docs/networking.md).

Tests exercise real inherited-descriptor startup, Ethernet ARP through the stack,
EOF shutdown, and Rust framing/backpressure. The live VPN and Docker validation
record is in [the feature review](../docs/runtime-feature-review.md).

Upstream source and license: [gvisor-tap-vsock v0.8.9](https://github.com/containers/gvisor-tap-vsock/tree/v0.8.9).
