package mail

// A hand-rolled, in-process SMTP server for exercising the real wire
// protocol without Docker/testcontainers — this package has no external
// service to containerize (unlike dbaccess/objectstore), so a fake transport
// speaking actual bytes over a real net.Listener on 127.0.0.1:0 is the
// equivalent fixture: it proves the client's byte-level framing (dot
// stuffing, header folding, STARTTLS negotiation), not just that a mock
// method was called.

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// newTestListener opens a listener on an ephemeral loopback port, closed
// automatically when the test ends.
func newTestListener(t *testing.T) (net.Listener, error) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	t.Cleanup(func() { _ = ln.Close() })
	return ln, nil
}

// fakeSMTPSession captures everything one accepted connection said and did.
type fakeSMTPSession struct {
	mu       sync.Mutex
	commands []string
	mailFrom string
	rcptTo   []string
	data     []byte
	authUser string
	authPass string
}

func (s *fakeSMTPSession) record(cmd string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.commands = append(s.commands, cmd)
}

func (s *fakeSMTPSession) hasCommandPrefix(prefix string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.commands {
		if strings.HasPrefix(strings.ToUpper(c), strings.ToUpper(prefix)) {
			return true
		}
	}
	return false
}

// fakeSMTPServer is a minimal, configurable SMTP server for tests. It is not
// a mock: it speaks the real protocol over a real socket.
type fakeSMTPServer struct {
	t  *testing.T
	ln net.Listener

	starttls  bool // advertise (and support) STARTTLS
	authPlain bool // advertise AUTH PLAIN
	tlsConfig *tls.Config
	silent    bool // accept the connection but never write anything (dial/read timeout fixture)

	rejectStep string // "MAIL", "RCPT", or "DATA"; "" = accept everything
	rejectCode int
	rejectMsg  string // deliberately may contain data that must NOT leak into client errors

	mu       sync.Mutex
	sessions []*fakeSMTPSession
	done     chan struct{}
}

func newFakeSMTPServer(t *testing.T) *fakeSMTPServer {
	t.Helper()
	ln, err := newTestListener(t)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &fakeSMTPServer{t: t, ln: ln, done: make(chan struct{})}
	t.Cleanup(func() { close(s.done) })
	return s
}

func (s *fakeSMTPServer) addr() string { return s.ln.Addr().String() }

func (s *fakeSMTPServer) hostPort() (string, string) {
	host, port, err := net.SplitHostPort(s.addr())
	if err != nil {
		s.t.Fatalf("split host port: %v", err)
	}
	return host, port
}

func (s *fakeSMTPServer) start() {
	go func() {
		for {
			conn, err := s.ln.Accept()
			if err != nil {
				return
			}
			go s.handle(conn)
		}
	}()
}

func (s *fakeSMTPServer) lastSession() *fakeSMTPSession {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.sessions) == 0 {
		return nil
	}
	return s.sessions[len(s.sessions)-1]
}

func (s *fakeSMTPServer) handle(conn net.Conn) {
	defer conn.Close()

	sess := &fakeSMTPSession{}
	s.mu.Lock()
	s.sessions = append(s.sessions, sess)
	s.mu.Unlock()

	if s.silent {
		<-s.done
		return
	}

	r := bufio.NewReader(conn)
	w := bufio.NewWriter(conn)
	writeLine(w, "220 fake.local ESMTP ready")

	for {
		line, err := readLine(r)
		if err != nil {
			return
		}
		sess.record(line)
		upper := strings.ToUpper(line)

		switch {
		case strings.HasPrefix(upper, "EHLO"):
			var lines []string
			lines = append(lines, "250-fake.local greets you")
			if s.starttls {
				lines = append(lines, "250-STARTTLS")
			}
			if s.authPlain {
				lines = append(lines, "250-AUTH PLAIN")
			}
			lines = append(lines, "250 8BITMIME")
			writeLines(w, lines)

		case upper == "STARTTLS":
			writeLine(w, "220 Go ahead")
			tlsConn := tls.Server(conn, s.tlsConfig)
			if err := tlsConn.Handshake(); err != nil {
				return
			}
			conn = tlsConn
			r = bufio.NewReader(conn)
			w = bufio.NewWriter(conn)

		case strings.HasPrefix(upper, "AUTH PLAIN"):
			fields := strings.Fields(line)
			var b64 string
			if len(fields) >= 3 {
				b64 = fields[2]
			} else {
				writeLine(w, "334 ")
				b64, err = readLine(r)
				if err != nil {
					return
				}
			}
			raw, _ := base64.StdEncoding.DecodeString(b64)
			segs := strings.Split(string(raw), "\x00")
			if len(segs) == 3 {
				sess.authUser, sess.authPass = segs[1], segs[2]
			}
			writeLine(w, "235 Authentication successful")

		case strings.HasPrefix(upper, "MAIL FROM:"):
			if s.rejectStep == "MAIL" {
				writeLine(w, fmt.Sprintf("%d %s", s.rejectCode, s.rejectMsg))
				continue
			}
			sess.mailFrom = line[len("MAIL FROM:"):]
			writeLine(w, "250 OK")

		case strings.HasPrefix(upper, "RCPT TO:"):
			if s.rejectStep == "RCPT" {
				writeLine(w, fmt.Sprintf("%d %s", s.rejectCode, s.rejectMsg))
				continue
			}
			sess.rcptTo = append(sess.rcptTo, line[len("RCPT TO:"):])
			writeLine(w, "250 OK")

		case upper == "DATA":
			if s.rejectStep == "DATA" {
				writeLine(w, fmt.Sprintf("%d %s", s.rejectCode, s.rejectMsg))
				continue
			}
			writeLine(w, "354 Start mail input; end with <CRLF>.<CRLF>")
			data, err := readDotStuffed(r)
			if err != nil {
				return
			}
			sess.data = data
			writeLine(w, "250 OK message accepted")

		case upper == "QUIT":
			writeLine(w, "221 Bye")
			return

		default:
			writeLine(w, "500 unrecognized command")
		}
	}
}

func writeLine(w *bufio.Writer, s string) {
	_, _ = w.WriteString(s)
	_, _ = w.WriteString("\r\n")
	_ = w.Flush()
}

func writeLines(w *bufio.Writer, lines []string) {
	for _, l := range lines {
		_, _ = w.WriteString(l)
		_, _ = w.WriteString("\r\n")
	}
	_ = w.Flush()
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// readDotStuffed reads an SMTP DATA payload, reversing the sender's dot
// stuffing (net/textproto's DotWriter): a line that is exactly "." ends the
// data; any other line beginning with "." has one leading dot removed.
func readDotStuffed(r *bufio.Reader) ([]byte, error) {
	var buf bytes.Buffer
	for {
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		if line == "." {
			return buf.Bytes(), nil
		}
		if strings.HasPrefix(line, "..") {
			line = line[1:]
		}
		buf.WriteString(line)
		buf.WriteString("\r\n")
	}
}

// generateSelfSignedTLSConfig builds an in-memory, self-signed certificate
// for 127.0.0.1 so STARTTLS can be exercised without touching any real CA or
// filesystem. Go's client-side verification will (correctly) reject this
// cert as untrusted — the STARTTLS tests use that to prove the client
// actually negotiates TLS, not to prove a full trusted handshake (this
// package's Config intentionally has no "skip verification" knob).
func generateSelfSignedTLSConfig(t *testing.T) *tls.Config {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	return &tls.Config{Certificates: []tls.Certificate{cert}}
}
