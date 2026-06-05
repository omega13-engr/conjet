# Conjet Networking

ConjetNet publishes Docker ports from the Conjet VM to macOS localhost.

The default policy is `secure-local`: Docker-published ports bind to
`127.0.0.1` and `::1` on the Mac. A Compose or Docker request for
`0.0.0.0:PORT` is mapped to loopback by default so local dashboards, databases,
and development services are not exposed to the LAN by accident.

## Commands

```sh
conjet port list
conjet port list --json
conjet port diagnose 63000/tcp
conjet network status
conjet network status --json
conjet network bridge-test --json
conjet network bridge-switch conjet-netd-c --restart
conjet network repair
conjet doctor --repair-network
```

`conjet status` also includes a concise networking summary when the daemon is
running.

## Bind Policies

`secure-local` is the default.

```sh
conjet network policy set secure-local
```

`docker-strict` preserves Docker bind semantics. A request for `0.0.0.0:PORT`
can be reachable outside the Mac if firewall and network settings allow it.

```sh
conjet network policy set docker-strict
```

`lan-allowlist` allows LAN exposure only when both a port and CIDR are
configured.

```sh
conjet network policy set lan-allowlist \
  --allow-cidr 192.168.1.0/24 \
  --allow-port 8080
```

Restart Conjet after changing policy so running listeners adopt the new
profile configuration.

## Capabilities

The guest bridge advertises networking capabilities. TCP publishing requires
`tcp_proxy=true`. UDP publishing requires `udp_proxy=true`.

If the active guest image is older, Conjet does not create fake UDP listeners.
The port state is reported as `failed_guest_capability`, and `conjet network
status` shows the missing capability.

## Proxy And Bridge Path

ConjetNet can run either the measured fast-path DispatchSource listener or the
SwiftNIO-class host listener. `auto` selects the measured faster
`proxy-gcd-evented` path on current local gates, while `proxy-nio` remains
available for high-concurrency comparisons.

The SwiftNIO-class host listener remains available explicitly:

```sh
CONJET_NET_PROXY_ENGINE=nio conjet start
conjet start --proxy-engine nio
```

The DispatchSource path can also be forced:

```sh
conjet start --proxy-engine gcd-evented
```

Guest bridge selection is explicit and benchmark-visible. New Conjet Core
images include both the Python fallback and the compiled helper. The selector is
written to the host bootstrap share before VM boot so bridge A/B runs do not
silently relabel one bridge as the other.

```sh
conjet start --bridge-engine conjet-netd-c
conjet network bridge-switch python-legacy --restart
conjet network bridge-switch conjet-netd-c --restart
```

ConjetNet reports benchmark-visible bridge metadata:

- `proxy_engine`: `proxy-nio` or `proxy-gcd-evented`
- `bridge_engine`: `python-legacy` or `conjet-netd-c`
- `vsock_mode`: `legacy`, `pooled`, `persistent`, or `mux`
- `guest_bridge_engine`: the active guest helper engine
- `tcp_mux_enabled`: whether TCP stream multiplexing is active
- `udp_frame_format`: `legacy` or `binary-v1`

ConjetNet v2.5 uses the compiled guest helper, `conjet-netd`, when available.
The helper advertises guest echo, metrics, binary frame, UDP binary frame, and
persistent VSOCK capabilities, and preserves Docker API passthrough to
`/var/run/docker.sock`. The host UDP proxy reuses a persistent binary guest
session for the published-port listener. TCP mux is not implemented yet; TCP
still uses the existing pooled/per-connection bridge path. The Python bridge
remains installed as a fallback for older images and for rollback.

The current fast path avoids three classes of avoidable network latency:

- The host Docker socket bridge accepts a deep connection backlog so Docker API
  bursts do not stall at the Unix socket listener.
- Host TCP bridge reads and writes wait with `poll(2)` under backpressure
  instead of micro-sleeping. This reduces tail latency and wasted CPU when many
  clients share the VSOCK bridge.
- The compiled guest helper keeps target registration protected by a global
  registry lock, but UDP send/receive work is serialized only per target. A
  slow or timing-out UDP service no longer blocks unrelated UDP published
  ports.

The v2.4 binary frame protocol is intentionally bounded and capability-gated.
It validates magic, version, frame type, payload length, and truncated frames.
Do not assume binary UDP/TCP is active unless `conjet network status --json` or
benchmark rows show `bridge_engine=conjet-netd-c` and
`udp_frame_format=binary-v1`.

## Tracking And Repair

Conjet starts with an initial reconcile of running containers, subscribes to
Docker container events, and keeps a slower periodic reconcile as a safety
repair path. Container lifecycle events use a targeted inspect path so new
listeners can be started without a broad `docker ps` sweep on the hot path.

The network benchmark separates port publication into two metrics:

- `listener_visible_ms`: elapsed time until the host TCP listener accepts a
  loopback connection.
- `first_connect_success_ms`: elapsed time until the first HTTP request through
  the published port succeeds.

This split keeps listener registration latency visible even when guest service
readiness or target forwarding dominates the first successful request.

Use `conjet network repair` when port state looks stale after VM image changes,
daemon restarts, or Docker metadata repair.

## Claims

ConjetNet provides secure localhost Docker TCP/UDP publishing with visible port
state, conflict reporting, repair commands, guest capability handling, and a
SwiftNIO-class host listener path. Newer Conjet Core images also provide a
compiled guest helper foundation for binary-framed guest echo, metrics, and UDP
fast-path work.

Do not claim Conjet networking beats OrbStack or Colima unless
`conjet-bench network-gate` produces sufficient measured evidence for the
specific workload.
