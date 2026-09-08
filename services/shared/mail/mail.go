// Package mail is the outbound-email abstraction (NFR-ARC-2): a small,
// standard-library-only SMTP sender behind a Config, so a domain service
// (starting with organizations, invitation email, FR-ONB-3) never talks to
// net/smtp directly and never has to special-case "no relay configured yet"
// as a startup failure.
//
// Dev/CI/staging point Config at the in-cluster Mailpit sink — no dev/CI/
// staging mail can ever reach a real inbox (ADR-0019 §4). A real
// staging/prod relay, with real credentials, is issue #417's deploy-time
// job; this package only needs a Config to talk to whichever endpoint that
// issue provisions, per ../README.md's "seam: switching endpoints is a
// config change, not a code change".
//
// Security note (the point of this package): the recipient address, the
// display names and the subject all originate from user-supplied data (an
// org admin types the invited address; org and inviter names are
// user-typed strings). Every header-bound value is validated for CR/LF
// header-injection *before* it is used and rejected outright — never
// silently stripped — and non-ASCII header values are RFC 2047
// encoded-words, never raw UTF-8 bytes in a header. See message.go.
//
// Errors returned by Send never include the recipient address or any other
// caller-supplied text: the calling service persists a Send failure reason
// in a database column an org admin later reads, and a real SMTP relay's
// free-text response can itself echo back attacker- or user-supplied data
// (e.g. "550 <injected> user unknown"). Errors instead name the failing
// protocol step and, where applicable, the SMTP status code. See
// StepError in smtp.go.
package mail

import (
	"context"
	"errors"
)

// Sender is the seam a domain service depends on to deliver one email.
type Sender interface {
	Send(ctx context.Context, msg Message) error
}

// Message is one outbound email. HTMLBody may be empty (text-only); To must
// be a single bare address (no display name, no list) — use ToName for the
// recipient's display name.
type Message struct {
	To       string // a single recipient address
	ToName   string // optional display name; may be ""
	Subject  string
	TextBody string
	HTMLBody string
	ReplyTo  string // optional; may be ""
}

// TLSMode selects how the connection to the SMTP relay is secured.
type TLSMode string

const (
	// TLSNone is plaintext SMTP end to end — the in-cluster Mailpit dev/CI
	// sink, which never sees a real inbox on the other end (ADR-0019 §4).
	TLSNone TLSMode = "none"
	// TLSStartTLS connects in plaintext and upgrades via STARTTLS.
	TLSStartTLS TLSMode = "starttls"
	// TLSImplicit is TLS from the first byte (SMTPS, conventionally :465).
	TLSImplicit TLSMode = "tls"
)

// ErrNotConfigured is returned by LoadConfig when no SMTP relay is
// provisioned yet, and by Unconfigured's Sender on every Send — a normal,
// non-fatal state (an environment with no relay provisioned), never a
// crash.
var ErrNotConfigured = errors.New("mail: no SMTP relay configured")

// ErrInvalidHeader is returned when an address, display name, subject or
// Reply-To would inject an additional header or body into the message (a
// bare CR or LF). The offending value is rejected, never sanitized.
var ErrInvalidHeader = errors.New("mail: header value contains a line break")
