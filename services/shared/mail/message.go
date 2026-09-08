package mail

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"strings"
	"time"
)

// buildMessage renders msg (using cfg's From/FromName) into a raw RFC 5322
// message ready to hand to an SMTP DATA phase, and returns the single bare
// recipient address alongside it. now is threaded through (rather than
// calling time.Now internally) so tests can pin the Date/Message-ID.
//
// Every header-bound value is validated for a bare CR/LF *before* anything
// else — header injection is rejected outright, never sanitized (see
// mail.go's package doc). Only after that check passes do we validate
// address shape and build headers/body.
func buildMessage(cfg Config, msg Message, now time.Time) (raw []byte, to string, err error) {
	headerFields := []struct {
		name  string
		value string
	}{
		{"to", msg.To},
		{"to name", msg.ToName},
		{"subject", msg.Subject},
		{"reply-to", msg.ReplyTo},
		{"from", cfg.From},
		{"from name", cfg.FromName},
	}
	for _, f := range headerFields {
		if strings.ContainsAny(f.value, "\r\n") {
			return nil, "", fmt.Errorf("mail: %s: %w", f.name, ErrInvalidHeader)
		}
	}

	toAddr, err := parseSingleAddress(msg.To)
	if err != nil {
		return nil, "", fmt.Errorf("mail: to: %w", err)
	}
	fromAddr, err := parseSingleAddress(cfg.From)
	if err != nil {
		return nil, "", fmt.Errorf("mail: from: %w", err)
	}

	var headers bytes.Buffer
	writeHeader(&headers, "From", (&mail.Address{Name: cfg.FromName, Address: fromAddr}).String())
	writeHeader(&headers, "To", (&mail.Address{Name: msg.ToName, Address: toAddr}).String())
	if msg.ReplyTo != "" {
		replyAddr, err := parseSingleAddress(msg.ReplyTo)
		if err != nil {
			return nil, "", fmt.Errorf("mail: reply-to: %w", err)
		}
		writeHeader(&headers, "Reply-To", (&mail.Address{Address: replyAddr}).String())
	}
	writeHeader(&headers, "Subject", mime.QEncoding.Encode("utf-8", msg.Subject))
	writeHeader(&headers, "Date", now.Format(time.RFC1123Z))
	writeHeader(&headers, "Message-ID", newMessageID(fromAddr, now))
	writeHeader(&headers, "MIME-Version", "1.0")

	bodyHeaders, body, err := buildBody(msg)
	if err != nil {
		return nil, "", err
	}
	for _, hl := range bodyHeaders {
		headers.WriteString(hl)
		headers.WriteString("\r\n")
	}

	var out bytes.Buffer
	out.Write(headers.Bytes())
	out.WriteString("\r\n")
	out.Write(body)

	return out.Bytes(), toAddr, nil
}

func writeHeader(buf *bytes.Buffer, name, value string) {
	buf.WriteString(name)
	buf.WriteString(": ")
	buf.WriteString(value)
	buf.WriteString("\r\n")
}

// parseSingleAddress requires raw to be exactly one bare address (no
// display name embedded, no address list) — the shape both Message.To and
// Config.From must have, since a display name is carried in a separate
// field (ToName/FromName).
func parseSingleAddress(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return "", fmt.Errorf("mail: address is required")
	}
	addr, err := mail.ParseAddress(raw)
	if err != nil {
		return "", fmt.Errorf("mail: %w", err)
	}
	if addr.Name != "" {
		return "", fmt.Errorf("mail: address must not include a display name")
	}
	return addr.Address, nil
}

// newMessageID generates a Message-ID using fromAddr's domain, so it at
// least identifies the sending system without depending on any global
// counter or clock precision guarantee.
func newMessageID(fromAddr string, now time.Time) string {
	domain := "localhost"
	if i := strings.LastIndex(fromAddr, "@"); i >= 0 && i+1 < len(fromAddr) {
		domain = fromAddr[i+1:]
	}
	var b [16]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("<%d.%s@%s>", now.UnixNano(), hex.EncodeToString(b[:]), domain)
}

// buildBody renders msg's TextBody/HTMLBody as either a single
// text/plain part (HTMLBody empty) or a multipart/alternative with
// text/plain first, text/html second (both present). Every part is
// quoted-printable encoded: a body line can then never be mistaken for a
// header (QP escapes control bytes), never exceed the 76-column wrap SMTP
// expects, and a lone "." body line is indistinguishable, post-encoding,
// from ".=0A" — actual DATA-phase dot-transparency is still net/smtp's
// job (textproto.Writer.DotWriter, used in smtp.go), this just keeps every
// encoded line short and printable.
func buildBody(msg Message) (headerLines []string, body []byte, err error) {
	if msg.HTMLBody == "" {
		qp, err := encodeQP(msg.TextBody)
		if err != nil {
			return nil, nil, fmt.Errorf("mail: encode text body: %w", err)
		}
		return []string{
			"Content-Type: text/plain; charset=utf-8",
			"Content-Transfer-Encoding: quoted-printable",
		}, []byte(qp), nil
	}

	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	if err := w.SetBoundary(newBoundary()); err != nil {
		return nil, nil, fmt.Errorf("mail: set multipart boundary: %w", err)
	}

	textQP, err := encodeQP(msg.TextBody)
	if err != nil {
		return nil, nil, fmt.Errorf("mail: encode text body: %w", err)
	}
	textPart, err := w.CreatePart(textproto.MIMEHeader{
		"Content-Type":              {"text/plain; charset=utf-8"},
		"Content-Transfer-Encoding": {"quoted-printable"},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("mail: create text part: %w", err)
	}
	if _, err := textPart.Write([]byte(textQP)); err != nil {
		return nil, nil, fmt.Errorf("mail: write text part: %w", err)
	}

	htmlQP, err := encodeQP(msg.HTMLBody)
	if err != nil {
		return nil, nil, fmt.Errorf("mail: encode html body: %w", err)
	}
	htmlPart, err := w.CreatePart(textproto.MIMEHeader{
		"Content-Type":              {"text/html; charset=utf-8"},
		"Content-Transfer-Encoding": {"quoted-printable"},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("mail: create html part: %w", err)
	}
	if _, err := htmlPart.Write([]byte(htmlQP)); err != nil {
		return nil, nil, fmt.Errorf("mail: write html part: %w", err)
	}

	if err := w.Close(); err != nil {
		return nil, nil, fmt.Errorf("mail: close multipart writer: %w", err)
	}

	return []string{
		fmt.Sprintf("Content-Type: multipart/alternative; boundary=%q", w.Boundary()),
	}, buf.Bytes(), nil
}

func encodeQP(s string) (string, error) {
	var buf bytes.Buffer
	w := quotedprintable.NewWriter(&buf)
	if _, err := w.Write([]byte(s)); err != nil {
		return "", err
	}
	if err := w.Close(); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func newBoundary() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return "beekeepingit-" + hex.EncodeToString(b[:])
}
