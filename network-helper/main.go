// Conjet's unprivileged host-socket network backend. VM execution stays in Rust.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
)

const ready = "CJNET1\n"

func configuration() *types.Configuration {
	return &types.Configuration{
		MTU:               1500,
		Subnet:            "172.31.64.0/24",
		GatewayIP:         "172.31.64.1",
		GatewayMacAddress: "02:43:4a:45:54:fe",
		GatewayVirtualIPs: []string{"172.31.64.254"},
		NAT:               map[string]string{"172.31.64.254": "127.0.0.1"},
		DHCPStaticLeases:  map[string]string{"172.31.64.2": "02:43:4a:45:54:01"},
		DNS: []types.Zone{{Name: "docker.internal.", Records: []types.Record{
			{Name: "host", IP: net.ParseIP("172.31.64.254")},
			{Name: "gateway", IP: net.ParseIP("172.31.64.1")},
		}}},
	}
}

func run(ctx context.Context) error {
	// fd 0 is one end of a socketpair inherited directly from Jetstream. There
	// is no filesystem listener or HTTP API that another process/container can
	// use to configure host port forwards.
	conn, err := net.FileConn(os.Stdin)
	if err != nil {
		return fmt.Errorf("expected an inherited Unix stream socket: %w", err)
	}
	_ = os.Stdin.Close()
	defer conn.Close()
	if _, ok := conn.(*net.UnixConn); !ok {
		return errors.New("network transport must be a Unix socket")
	}
	vn, err := virtualnetwork.New(configuration())
	if err != nil {
		return fmt.Errorf("initialize network: %w", err)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if _, err := io.WriteString(conn, ready); err != nil {
		return err
	}
	// Use the Ethernet framing protocol only; do not serve vn.Mux(), which
	// would expose upstream port-forwarding administration to the guest.
	err = vn.AcceptQemu(ctx, conn)
	if ctx.Err() != nil || errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("conjet-network gvisor-tap-vsock v0.8.9 protocol CJNET1")
		return
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "conjet-network:", err)
		os.Exit(1)
	}
}
