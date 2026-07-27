package otelboot

import (
	"context"
	"errors"
	"testing"
)

// fakeShutdowner is a minimal shutdowner stand-in — real OTel SDK providers
// are concrete types that dial lazily and rarely fail their constructors
// under test conditions, so the cleanup mechanism itself (shutdownAll) is
// exercised directly here rather than by forcing a real exporter to error.
type fakeShutdowner struct {
	called bool
	err    error
}

func (f *fakeShutdowner) Shutdown(context.Context) error {
	f.called = true
	return f.err
}

// TestShutdownAll_CallsEveryProvider is a regression test for Bootstrap's
// startup-path resource leak: if a later exporter (metrics/logs) failed to
// start, earlier-created providers (e.g. the TracerProvider) were never shut
// down. shutdownAll is the mechanism Bootstrap now uses to clean up whatever
// was already created before returning the error — every already-created
// provider passed in must be shut down.
func TestShutdownAll_CallsEveryProvider(t *testing.T) {
	a := &fakeShutdowner{}
	b := &fakeShutdowner{}

	if err := shutdownAll(context.Background(), a, b); err != nil {
		t.Fatalf("shutdownAll() error = %v, want nil", err)
	}
	if !a.called || !b.called {
		t.Errorf("called = (%v, %v), want (true, true) — every already-created provider must be shut down", a.called, b.called)
	}
}

func TestShutdownAll_JoinsErrors(t *testing.T) {
	boom1 := errors.New("boom1")
	boom2 := errors.New("boom2")
	a := &fakeShutdowner{err: boom1}
	b := &fakeShutdowner{err: boom2}

	err := shutdownAll(context.Background(), a, b)
	if err == nil {
		t.Fatal("shutdownAll() error = nil, want joined errors")
	}
	if !errors.Is(err, boom1) || !errors.Is(err, boom2) {
		t.Errorf("error %v does not join both shutdown failures", err)
	}
}

func TestShutdownAll_NoProviders(t *testing.T) {
	if err := shutdownAll(context.Background()); err != nil {
		t.Errorf("shutdownAll() error = %v, want nil for no providers", err)
	}
}
