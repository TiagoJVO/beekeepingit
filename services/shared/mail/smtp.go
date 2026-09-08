package mail

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/smtp"
	"net/textproto"
	"strconv"
	"time"
)

// smtpSender is the Sender New builds: cfg is already validated (New's
// contract), so Send only has to validate the per-message fields.
type smtpSender struct {
	cfg Config
}

func (s *smtpSender) Send(ctx context.Context, msg Message) error {
	raw, to, err := buildMessage(s.cfg, msg, time.Now())
	if err != nil {
		return err
	}
	return s.deliver(ctx, to, raw)
}

// StepError names the SMTP protocol step that failed and its numeric
// status code — deliberately never the server's free-text response, which
// is attacker- or operator-controlled on the relay side and can echo back
// arbitrary data (the recipient address, an injected header) straight into
// a message a caller may persist and later show an admin (see mail.go's
// package doc).
type StepError struct {
	Step string
	Code int
}

func (e *StepError) Error() string {
	return fmt.Sprintf("mail: %s failed with SMTP status %d", e.Step, e.Code)
}

// wrapStepError tags err with the SMTP step that produced it. A
// *textproto.Error (the server's own response) is converted to a
// StepError carrying only the numeric code, deliberately dropping the
// server's free-text message; any other error (dial/i/o/context) is safe
// to keep as-is, since its text originates from the Go runtime or the OS,
// not from a remote party or user input.
func wrapStepError(step string, err error) error {
	if err == nil {
		return nil
	}
	var protoErr *textproto.Error
	if errors.As(err, &protoErr) {
		return &StepError{Step: step, Code: protoErr.Code}
	}
	return fmt.Errorf("mail: %s: %w", step, err)
}

// deliver runs one SMTP conversation over a fresh connection: EHLO, an
// optional STARTTLS upgrade, optional AUTH (only when Username is set),
// MAIL FROM, RCPT TO, DATA, QUIT.
func (s *smtpSender) deliver(ctx context.Context, to string, raw []byte) error {
	addr := net.JoinHostPort(s.cfg.Host, strconv.Itoa(s.cfg.Port))

	conn, err := s.dial(ctx, addr)
	if err != nil {
		return wrapStepError("connect", err)
	}
	defer conn.Close()

	if s.cfg.Timeout > 0 {
		if err := conn.SetDeadline(time.Now().Add(s.cfg.Timeout)); err != nil {
			return wrapStepError("connect", err)
		}
	}

	// net/smtp's Client is blocking and ctx-unaware; closing the connection
	// when ctx is done is what makes a cancelled/deadline-exceeded ctx
	// abort an in-flight conversation instead of only relying on the
	// deadline set above.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-stop:
		}
	}()

	client, err := smtp.NewClient(conn, s.cfg.Host)
	if err != nil {
		return wrapStepError("connect", err)
	}
	defer client.Close()

	if err := client.Hello("localhost"); err != nil {
		return wrapStepError("EHLO", err)
	}

	if s.cfg.TLS == TLSStartTLS {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return fmt.Errorf("mail: STARTTLS: server does not advertise support")
		}
		if err := client.StartTLS(&tls.Config{ServerName: s.cfg.Host}); err != nil {
			return wrapStepError("STARTTLS", err)
		}
	}

	if s.cfg.Username != "" {
		if ok, _ := client.Extension("AUTH"); ok {
			auth := smtp.PlainAuth("", s.cfg.Username, s.cfg.Password, s.cfg.Host)
			if err := client.Auth(auth); err != nil {
				return wrapStepError("AUTH", err)
			}
		}
	}

	if err := client.Mail(s.cfg.From); err != nil {
		return wrapStepError("MAIL FROM", err)
	}
	if err := client.Rcpt(to); err != nil {
		return wrapStepError("RCPT TO", err)
	}
	w, err := client.Data()
	if err != nil {
		return wrapStepError("DATA", err)
	}
	if _, err := w.Write(raw); err != nil {
		return wrapStepError("DATA", err)
	}
	if err := w.Close(); err != nil {
		return wrapStepError("DATA", err)
	}
	if err := client.Quit(); err != nil {
		return wrapStepError("QUIT", err)
	}
	return nil
}

// dial connects to addr, applying cfg.TLS: TLSImplicit wraps the
// connection in TLS immediately (SMTPS); TLSNone and TLSStartTLS both dial
// plaintext (STARTTLS, if configured, upgrades later in deliver).
func (s *smtpSender) dial(ctx context.Context, addr string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: s.cfg.Timeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}

	if s.cfg.TLS != TLSImplicit {
		return conn, nil
	}

	tlsConn := tls.Client(conn, &tls.Config{ServerName: s.cfg.Host})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return tlsConn, nil
}
