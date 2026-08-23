package dbaccess_test

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// TestMigrate_WaitsForAServerThatStartsLate is the regression test for the
// helm-e2e failure that #551's first attempt caused. The migrate Job raced a
// CNPG instance that was still starting and died three times in a row with
// `connection refused`, because lowering the Job's backoffLimit removed the
// pod-restart loop that had been absorbing Postgres' startup by accident.
//
// The listener here is closed at first and only opens partway through, which is
// exactly that race: nothing is listening on the port when Migrate is called.
// Migrate must keep probing rather than fail on the first refusal.
//
// It asserts reaching the SERVER, not a completed migration — once something
// accepts the connection, the fake speaks no Postgres protocol and the attempt
// fails on the handshake. That is the correct boundary for this test: whether
// goose can migrate is covered elsewhere; what is at stake here is only whether
// a refused dial ends the run.
func TestMigrate_WaitsForAServerThatStartsLate(t *testing.T) {
	// Reserve a port, then close it so connections are actively refused.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	addr := probe.Addr().String()
	_ = probe.Close()

	opened := make(chan struct{})
	go func() {
		time.Sleep(3 * time.Second) // longer than one probe interval
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return
		}
		close(opened)
		defer func() { _ = ln.Close() }()
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close() // accept, then hang up: reachable, but not Postgres
		}
	}()

	host, port, _ := net.SplitHostPort(addr)
	dsn := fmt.Sprintf("postgres://u:p@%s:%s/db?sslmode=disable&connect_timeout=1", host, port)

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()

	start := time.Now()
	err = dbaccess.Migrate(ctx, dsn, fstest.MapFS{
		"00001_noop.sql": &fstest.MapFile{Data: []byte("-- +goose Up\nSELECT 1;\n")},
	})
	elapsed := time.Since(start)

	select {
	case <-opened:
	default:
		t.Fatal("listener never opened — test is not exercising what it claims")
	}

	if err == nil {
		t.Fatal("want an error from the fake server's handshake, got nil")
	}

	// THE PROPERTY: it must not have given up on the initial refusals. Returning
	// before the listener opened is precisely the regression that failed
	// helm-e2e three times.
	if elapsed < 3*time.Second {
		t.Fatalf("Migrate returned after %s, before the server opened — it gave up on `connection refused` instead of waiting, which is the exact regression this guards", elapsed)
	}

	// And it must have got PAST the refusals to a real conversation. The fake
	// accepts and immediately hangs up, so the surviving error is a protocol
	// failure ("unexpected EOF"), never a refused dial. Asserting on the absence
	// of "connection refused" is what distinguishes "waited, then reached the
	// server" from "waited, and was still being refused at the deadline".
	if strings.Contains(err.Error(), "connection refused") {
		t.Fatalf("Migrate was still being refused when the deadline hit — it never reached the listener that opened at 3s: %v", err)
	}
}
