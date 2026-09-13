package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
)

func TestNetworkStartsWithoutHostListeners(t *testing.T) {
	config := configuration()
	if len(config.Forwards) != 0 {
		t.Fatal("host forwarding must stay owned by ConjetNet")
	}
	if _, err := virtualnetwork.New(config); err != nil {
		t.Fatal(err)
	}
}

// Exercise the same inherited descriptor and handshake used by the Rust VMM,
// including an actual Ethernet request through the stack and EOF shutdown.
func TestInheritedTransportARPAndShutdown(t *testing.T) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	local := os.NewFile(uintptr(fds[0]), "network-parent")
	child := os.NewFile(uintptr(fds[1]), "network-child")
	defer child.Close()
	conn, err := net.FileConn(local)
	local.Close()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestNetworkHelperProcess$")
	cmd.Env = append(os.Environ(), "CONJET_NETWORK_TEST_CHILD=1")
	cmd.Stdin = child
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	child.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	ack := make([]byte, len(ready))
	if _, err := io.ReadFull(conn, ack); err != nil || string(ack) != ready {
		t.Fatalf("handshake %q: %v; %s", ack, err, stderr.String())
	}
	// Ethernet broadcast: who has 172.31.64.1? Tell 172.31.64.2.
	frame := []byte{
		255, 255, 255, 255, 255, 255, 2, 67, 74, 69, 84, 1, 8, 6,
		0, 1, 8, 0, 6, 4, 0, 1,
		2, 67, 74, 69, 84, 1, 172, 31, 64, 2,
		0, 0, 0, 0, 0, 0, 172, 31, 64, 1,
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(frame)))
	if _, err := conn.Write(append(header[:], frame...)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		t.Fatal(err)
	}
	size := binary.BigEndian.Uint32(header[:])
	if size < 42 || size > 1514 {
		t.Fatalf("invalid reply length %d", size)
	}
	reply := make([]byte, size)
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(reply[12:14], []byte{8, 6}) || binary.BigEndian.Uint16(reply[20:22]) != 2 ||
		!bytes.Equal(reply[28:32], []byte{172, 31, 64, 1}) {
		t.Fatalf("expected gateway ARP response, got %x", reply)
	}
	conn.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper failed to exit on EOF: %v; %s", err, stderr.String())
	}
}

func TestNetworkHelperProcess(t *testing.T) {
	if os.Getenv("CONJET_NETWORK_TEST_CHILD") != "1" {
		return
	}
	main()
	os.Exit(0)
}
