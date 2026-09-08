package mail

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"
)

func configFor(t *testing.T, s *fakeSMTPServer) Config {
	t.Helper()
	host, port := s.hostPort()
	p, err := strconv.Atoi(port)
	if err != nil {
		t.Fatalf("parse port %q: %v", port, err)
	}
	return Config{
		Host:    host,
		Port:    p,
		From:    "no-reply@example.org",
		TLS:     TLSNone,
		Timeout: 5 * time.Second,
	}
}

func TestSend_HappyPath_ConversationOrderAndEnvelope(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.start()
	cfg := configFor(t, srv)

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	msg := Message{To: "someone@example.test", Subject: "hi", TextBody: "hello"}
	if err := sender.Send(ctx, msg); err != nil {
		t.Fatalf("Send() error = %v, want nil", err)
	}

	sess := srv.lastSession()
	if sess == nil {
		t.Fatal("no session recorded")
	}

	order := commandVerbs(sess.commands)
	want := []string{"EHLO", "MAIL", "RCPT", "DATA", "QUIT"}
	if !hasSubsequence(order, want) {
		t.Fatalf("command order = %v, want a subsequence matching %v", order, want)
	}

	// The server advertises 8BITMIME, so net/smtp's Client.Mail appends
	// " BODY=8BITMIME" after the closing '>' — extract just the address.
	if got := addressInAngleBrackets(sess.mailFrom); got != cfg.From {
		t.Errorf("MAIL FROM = %q, want %q", got, cfg.From)
	}
	if len(sess.rcptTo) != 1 {
		t.Fatalf("RCPT TO count = %d, want exactly 1 (got %v)", len(sess.rcptTo), sess.rcptTo)
	}
	if got := addressInAngleBrackets(sess.rcptTo[0]); got != msg.To {
		t.Errorf("RCPT TO = %q, want %q", got, msg.To)
	}
	if len(sess.data) == 0 {
		t.Error("DATA payload is empty")
	}
}

func TestSend_AuthOnlyWhenUsernameConfigured(t *testing.T) {
	t.Run("no username: AUTH is never sent", func(t *testing.T) {
		srv := newFakeSMTPServer(t)
		srv.authPlain = true
		srv.start()
		cfg := configFor(t, srv)

		sender, err := New(cfg)
		if err != nil {
			t.Fatalf("New() error = %v", err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"}); err != nil {
			t.Fatalf("Send() error = %v, want nil", err)
		}

		sess := srv.lastSession()
		if sess.hasCommandPrefix("AUTH") {
			t.Errorf("commands = %v, AUTH must not be sent when Username is empty", sess.commands)
		}
	})

	t.Run("username set: AUTH PLAIN is sent with the configured credentials", func(t *testing.T) {
		srv := newFakeSMTPServer(t)
		srv.authPlain = true
		srv.start()
		cfg := configFor(t, srv)
		cfg.Username = "svc-invitations"
		cfg.Password = "s3cr3t"

		sender, err := New(cfg)
		if err != nil {
			t.Fatalf("New() error = %v", err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"}); err != nil {
			t.Fatalf("Send() error = %v, want nil", err)
		}

		sess := srv.lastSession()
		if !sess.hasCommandPrefix("AUTH") {
			t.Fatalf("commands = %v, want an AUTH command", sess.commands)
		}
		if sess.authUser != cfg.Username || sess.authPass != cfg.Password {
			t.Errorf("auth = (%q, %q), want (%q, %q)", sess.authUser, sess.authPass, cfg.Username, cfg.Password)
		}
	})
}

func TestSend_TLSNone_NeverAttemptsSTARTTLS(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.starttls = true // server advertises it; client must still ignore it under TLSNone
	srv.tlsConfig = generateSelfSignedTLSConfig(t)
	srv.start()
	cfg := configFor(t, srv)
	cfg.TLS = TLSNone

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"}); err != nil {
		t.Fatalf("Send() error = %v, want nil", err)
	}

	sess := srv.lastSession()
	if sess.hasCommandPrefix("STARTTLS") {
		t.Errorf("commands = %v, STARTTLS must not be sent under TLSNone", sess.commands)
	}
	if !sess.hasCommandPrefix("QUIT") {
		t.Errorf("commands = %v, want a completed conversation ending in QUIT", sess.commands)
	}
}

func TestSend_STARTTLS_IsAttemptedWhenConfigured(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.starttls = true
	srv.tlsConfig = generateSelfSignedTLSConfig(t)
	srv.start()
	cfg := configFor(t, srv)
	cfg.TLS = TLSStartTLS

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// The fake server's certificate is self-signed and untrusted, and this
	// package's Config deliberately has no "skip verification" knob — so a
	// real TLS handshake here is expected to fail. That failure is exactly
	// the proof STARTTLS was attempted for real, not skipped.
	err = sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"})
	if err == nil {
		t.Fatal("Send() error = nil, want a TLS verification error against an untrusted self-signed cert")
	}
	if !strings.Contains(err.Error(), "STARTTLS") {
		t.Errorf("error = %v, want it to name the STARTTLS step", err)
	}

	sess := srv.lastSession()
	if !sess.hasCommandPrefix("STARTTLS") {
		t.Errorf("commands = %v, want STARTTLS to have been issued", sess.commands)
	}
}

func TestSend_ServerRejection_NamesStepAndStatusNotUserData(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.rejectStep = "RCPT"
	srv.rejectCode = 550
	srv.rejectMsg = "5.1.1 <victim@example.test> user unknown" // must never reach the caller
	srv.start()
	cfg := configFor(t, srv)

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err = sender.Send(ctx, Message{To: "victim@example.test", Subject: "hi", TextBody: "hi"})
	if err == nil {
		t.Fatal("Send() error = nil, want a rejection error")
	}
	if !strings.Contains(err.Error(), "RCPT") {
		t.Errorf("error = %v, want it to name the RCPT TO step", err)
	}
	if !strings.Contains(err.Error(), "550") {
		t.Errorf("error = %v, want it to include the SMTP status 550", err)
	}
	if strings.Contains(err.Error(), "victim") || strings.Contains(err.Error(), "@") {
		t.Errorf("error = %v, must not echo the recipient address or server free text", err)
	}
}

func TestSend_ContextCancelled_ReturnsPromptly(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.start()
	cfg := configFor(t, srv)

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled before Send is even called

	start := time.Now()
	err = sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"})
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Send() error = nil, want an error for a cancelled context")
	}
	if elapsed > 2*time.Second {
		t.Errorf("Send() took %v to fail on a cancelled context, want well under 2s", elapsed)
	}
}

func TestSend_DialOrReadTimeout_ReturnsPromptly(t *testing.T) {
	srv := newFakeSMTPServer(t)
	srv.silent = true // accepts the TCP connection but never speaks
	srv.start()
	cfg := configFor(t, srv)
	cfg.Timeout = 200 * time.Millisecond

	sender, err := New(cfg)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	start := time.Now()
	err = sender.Send(ctx, Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"})
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Send() error = nil, want a timeout error")
	}
	if elapsed > 2*time.Second {
		t.Errorf("Send() took %v against a silent server with a 200ms timeout, want well under 2s", elapsed)
	}
}

// addressInAngleBrackets returns the substring between the first '<' and
// the following '>' (net/smtp's MAIL FROM/RCPT TO wire format may carry
// trailing ESMTP parameters like " BODY=8BITMIME" after the address).
func addressInAngleBrackets(s string) string {
	start := strings.Index(s, "<")
	if start < 0 {
		return s
	}
	end := strings.Index(s[start:], ">")
	if end < 0 {
		return s
	}
	return s[start+1 : start+end]
}

// commandVerbs extracts the leading command word from each recorded line
// (e.g. "MAIL FROM:<a@b>" -> "MAIL"), uppercased.
func commandVerbs(commands []string) []string {
	out := make([]string, 0, len(commands))
	for _, c := range commands {
		fields := strings.Fields(c)
		if len(fields) == 0 {
			continue
		}
		out = append(out, strings.ToUpper(fields[0]))
	}
	return out
}

// hasSubsequence reports whether want appears, in order (not necessarily
// contiguously), within got.
func hasSubsequence(got, want []string) bool {
	i := 0
	for _, g := range got {
		if i < len(want) && g == want[i] {
			i++
		}
	}
	return i == len(want)
}
