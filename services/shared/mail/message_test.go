package mail

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

func testConfig() Config {
	return Config{
		Host: "smtp.example.org",
		Port: 587,
		From: "no-reply@example.org",
		TLS:  TLSStartTLS,
	}
}

func TestBuildMessage_RejectsHeaderInjection(t *testing.T) {
	decodedLF := "invited\nBcc: attacker@evil.test" // stands in for a %0A-decoded literal

	tests := []struct {
		name string
		msg  func() Message
	}{
		{"To contains CRLF injection", func() Message {
			return Message{To: "victim@example.test\r\nBcc: attacker@evil.test", Subject: "hi", TextBody: "hi"}
		}},
		{"ToName contains bare LF", func() Message {
			return Message{To: "victim@example.test", ToName: decodedLF, Subject: "hi", TextBody: "hi"}
		}},
		{"Subject contains trailing newline", func() Message {
			return Message{To: "victim@example.test", Subject: "hi\n", TextBody: "hi"}
		}},
		{"ReplyTo contains CR", func() Message {
			return Message{To: "victim@example.test", ReplyTo: "a@b.test\rX-Injected: 1", Subject: "hi", TextBody: "hi"}
		}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := buildMessage(testConfig(), tt.msg(), time.Now())
			if !errors.Is(err, ErrInvalidHeader) {
				t.Fatalf("buildMessage() error = %v, want ErrInvalidHeader", err)
			}
		})
	}
}

func TestNew_RejectsHeaderInjectionInFromFields(t *testing.T) {
	cfg := testConfig()
	cfg.FromName = "Org\r\nBcc: attacker@evil.test"

	_, err := New(cfg)
	if !errors.Is(err, ErrInvalidHeader) {
		t.Fatalf("New() error = %v, want ErrInvalidHeader", err)
	}
}

func TestBuildMessage_RejectsInvalidToAddress(t *testing.T) {
	tests := []struct {
		name string
		to   string
	}{
		{"address list", "a@b.test, c@d.test"},
		{"empty", ""},
		{"embedded display name", "Some Name <a@b.test>"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg := Message{To: tt.to, Subject: "hi", TextBody: "hi"}
			_, _, err := buildMessage(testConfig(), msg, time.Now())
			if err == nil {
				t.Fatalf("buildMessage() error = nil for To=%q, want an error", tt.to)
			}
		})
	}
}

func TestBuildMessage_ToAddressIsExactlyOne(t *testing.T) {
	msg := Message{To: "someone@example.test", Subject: "hi", TextBody: "hi"}
	_, to, err := buildMessage(testConfig(), msg, time.Now())
	if err != nil {
		t.Fatalf("buildMessage() error = %v, want nil", err)
	}
	if to != "someone@example.test" {
		t.Errorf("to = %q, want someone@example.test", to)
	}
}

func TestBuildMessage_EncodesNonASCIISubject(t *testing.T) {
	subject := "Convite para a organização Apiário São João"
	msg := Message{To: "someone@example.test", Subject: subject, TextBody: "hi"}

	raw, _, err := buildMessage(testConfig(), msg, time.Now())
	if err != nil {
		t.Fatalf("buildMessage() error = %v, want nil", err)
	}

	headerBlock, _, found := strings.Cut(string(raw), "\r\n\r\n")
	if !found {
		t.Fatal("raw message has no header/body separator")
	}
	for i := 0; i < len(headerBlock); i++ {
		if headerBlock[i] >= 0x80 {
			t.Fatalf("header block contains a raw non-ASCII byte at offset %d: %q", i, headerBlock)
		}
	}

	subjectLine := findHeaderLine(t, headerBlock, "Subject")
	if !strings.Contains(subjectLine, "=?utf-8?") && !strings.Contains(strings.ToLower(subjectLine), "=?utf-8?") {
		t.Fatalf("Subject header not RFC 2047 encoded: %q", subjectLine)
	}

	dec := new(mime.WordDecoder)
	decoded, err := dec.DecodeHeader(strings.TrimPrefix(subjectLine, "Subject: "))
	if err != nil {
		t.Fatalf("DecodeHeader() error = %v", err)
	}
	if decoded != subject {
		t.Errorf("decoded subject = %q, want %q", decoded, subject)
	}
}

func TestBuildMessage_TextOnlyIsPlainTextMessage(t *testing.T) {
	msg := Message{To: "someone@example.test", Subject: "hi", TextBody: "hello there"}
	raw, _, err := buildMessage(testConfig(), msg, time.Now())
	if err != nil {
		t.Fatalf("buildMessage() error = %v, want nil", err)
	}

	m, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("mail.ReadMessage() error = %v", err)
	}

	ct := m.Header.Get("Content-Type")
	if !strings.HasPrefix(ct, "text/plain; charset=utf-8") {
		t.Errorf("Content-Type = %q, want text/plain; charset=utf-8", ct)
	}
	if m.Header.Get("MIME-Version") != "1.0" {
		t.Errorf("MIME-Version = %q, want 1.0", m.Header.Get("MIME-Version"))
	}
	if m.Header.Get("Date") == "" {
		t.Error("Date header is empty")
	}
	if m.Header.Get("Message-Id") == "" {
		t.Error("Message-ID header is empty")
	}

	body, err := io.ReadAll(quotedprintable.NewReader(m.Body))
	if err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if string(body) != "hello there" {
		t.Errorf("body = %q, want %q", body, "hello there")
	}
}

func TestBuildMessage_MultipartAlternative_TextThenHTML(t *testing.T) {
	msg := Message{
		To:       "someone@example.test",
		Subject:  "hi",
		TextBody: "plain body",
		HTMLBody: "<p>html body</p>",
	}
	raw, _, err := buildMessage(testConfig(), msg, time.Now())
	if err != nil {
		t.Fatalf("buildMessage() error = %v, want nil", err)
	}

	m, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("mail.ReadMessage() error = %v", err)
	}

	mediaType, params, err := mime.ParseMediaType(m.Header.Get("Content-Type"))
	if err != nil {
		t.Fatalf("ParseMediaType() error = %v", err)
	}
	if mediaType != "multipart/alternative" {
		t.Fatalf("mediaType = %q, want multipart/alternative", mediaType)
	}
	boundary := params["boundary"]
	if boundary == "" {
		t.Fatal("no boundary param on Content-Type")
	}

	mr := multipart.NewReader(m.Body, boundary)

	part1, err := mr.NextPart()
	if err != nil {
		t.Fatalf("NextPart() 1 error = %v", err)
	}
	if ct := part1.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("part 1 Content-Type = %q, want text/plain prefix", ct)
	}
	body1, err := io.ReadAll(quotedprintable.NewReader(part1))
	if err != nil {
		t.Fatalf("decode part 1: %v", err)
	}
	if string(body1) != "plain body" {
		t.Errorf("part 1 body = %q, want %q", body1, "plain body")
	}

	part2, err := mr.NextPart()
	if err != nil {
		t.Fatalf("NextPart() 2 error = %v", err)
	}
	if ct := part2.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("part 2 Content-Type = %q, want text/html prefix", ct)
	}
	body2, err := io.ReadAll(quotedprintable.NewReader(part2))
	if err != nil {
		t.Fatalf("decode part 2: %v", err)
	}
	if string(body2) != "<p>html body</p>" {
		t.Errorf("part 2 body = %q, want %q", body2, "<p>html body</p>")
	}

	if _, err := mr.NextPart(); err != io.EOF {
		t.Errorf("expected exactly two parts, got a third (err=%v)", err)
	}
}

func TestBuildMessage_BodyEncoding_LoneDotLineAndLongLine(t *testing.T) {
	longLine := strings.Repeat("x", 2000)
	body := "first line\n.\nlast line: " + longLine
	msg := Message{To: "someone@example.test", Subject: "hi", TextBody: body}

	raw, _, err := buildMessage(testConfig(), msg, time.Now())
	if err != nil {
		t.Fatalf("buildMessage() error = %v, want nil", err)
	}

	_, bodyPart, found := strings.Cut(string(raw), "\r\n\r\n")
	if !found {
		t.Fatal("raw message has no header/body separator")
	}

	sc := bufio.NewScanner(strings.NewReader(bodyPart))
	for sc.Scan() {
		line := sc.Text()
		if len(line) > 76 {
			t.Fatalf("encoded body line exceeds 76 octets (%d): %q", len(line), line)
		}
	}

	decoded, err := io.ReadAll(quotedprintable.NewReader(strings.NewReader(bodyPart)))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	// quoted-printable's canonical form is CRLF-terminated lines (RFC
	// 2045): the encoder rewrites a bare "\n" to "\r\n" on the way out, so
	// compare against that canonical form rather than the original bytes.
	wantCanonical := strings.ReplaceAll(body, "\n", "\r\n")
	if string(decoded) != wantCanonical {
		t.Errorf("round-tripped body = %q, want %q", decoded, wantCanonical)
	}
}

// findHeaderLine returns the first unfolded header line starting with
// "name:" from a raw CRLF-delimited header block, failing the test if absent.
func findHeaderLine(t *testing.T, headerBlock, name string) string {
	t.Helper()
	r := textproto.NewReader(bufio.NewReader(strings.NewReader(headerBlock + "\r\n\r\n")))
	hdr, err := r.ReadMIMEHeader()
	if err != nil {
		t.Fatalf("ReadMIMEHeader() error = %v", err)
	}
	v := hdr.Get(name)
	if v == "" {
		t.Fatalf("header %q not found in block: %q", name, headerBlock)
	}
	return name + ": " + v
}
