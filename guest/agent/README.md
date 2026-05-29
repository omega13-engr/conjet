# Guest Agent

The guest agent will manage workspace placement, inotify/fanotify replay,
containerd/BuildKit health checks, and guest-side metrics.

The host-side initramfs packager now exists:

```sh
conjet vm build-initramfs --init /path/to/linux-arm64-static-init
```

The missing piece is the actual static Linux `/init` executable. This workspace
does not currently have a Go toolchain, and Rust only has the Darwin target
installed, so the agent build recipe still needs a Linux arm64 static toolchain
or a vendored prebuilt bootstrap binary.
