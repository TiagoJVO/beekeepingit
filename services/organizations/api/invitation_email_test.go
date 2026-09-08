// Unit tests for the invitation email's CONTENT and its handling of
// user-supplied text (#641, FR-ONB-3 AC 2/AC 3). These are deliberately
// package-level tests with no database and no SMTP server: the rest of this
// service's suite runs against a containerized Postgres (main_test.go), which
// cannot run on a machine without Docker, and the rules this file pins --
// which language, what the message says, what happens to a hostile
// organization name -- are exactly the ones worth being able to run anywhere.
package api

import (
	"strings"
	"testing"
)

func TestNormalizeLocale(t *testing.T) {
	cases := map[string]string{
		"pt-PT": localePT,
		"pt_PT": localePT,
		"PT-pt": localePT,
		"pt":    localePT,
		"en-GB": localeEN,
		"en":    localeEN,
		"":      localeEN,
		// A locale this service does not ship must degrade to English rather
		// than fail the send (FR-ONB-3 AC 3 names EN and PT only).
		"fr-FR":     localeEN,
		"  pt-PT  ": localePT,
	}
	for in, want := range cases {
		if got := normalizeLocale(in); got != want {
			t.Errorf("normalizeLocale(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestInvitationEmail_NamesOrganizationInviterAndLinksToSignUp(t *testing.T) {
	msg, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: "Dev Apiary Co.",
		InviterName:      "Ana Admin",
		InviteeEmail:     "invitee@example.com",
		SignUpURL:        "https://app.beekeepingit.local:8443/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail: %v", err)
	}

	if msg.To != "invitee@example.com" {
		t.Errorf("To = %q, want the invited address", msg.To)
	}
	// AC 2: the email identifies the organization and the inviter, and links
	// to the sign-up flow. Assert it in every part a recipient can read.
	for _, part := range []struct{ name, body string }{
		{"subject", msg.Subject},
		{"text", msg.TextBody},
		{"html", msg.HTMLBody},
	} {
		if !strings.Contains(part.body, "Dev Apiary Co.") {
			t.Errorf("%s does not name the organization: %q", part.name, part.body)
		}
	}
	for _, part := range []struct{ name, body string }{
		{"subject", msg.Subject},
		{"text", msg.TextBody},
		{"html", msg.HTMLBody},
	} {
		if !strings.Contains(part.body, "Ana Admin") {
			t.Errorf("%s does not name the inviter: %q", part.name, part.body)
		}
	}
	for _, part := range []struct{ name, body string }{
		{"text", msg.TextBody},
		{"html", msg.HTMLBody},
	} {
		if !strings.Contains(part.body, "https://app.beekeepingit.local:8443/login") {
			t.Errorf("%s does not link to the sign-up flow: %q", part.name, part.body)
		}
		// The invitee must be told WHICH address to use -- accept-on-login
		// matches the verified email claim (auth.md §8.7), so signing up with
		// a different address silently fails to join.
		if !strings.Contains(part.body, "invitee@example.com") {
			t.Errorf("%s does not state the address to sign up with: %q", part.name, part.body)
		}
	}
}

func TestInvitationEmail_PortugueseWhenLocaleIsPT(t *testing.T) {
	pt, err := invitationEmail("pt-PT", invitationEmailData{
		OrganizationName: "Apiário São João",
		InviterName:      "Ana",
		InviteeEmail:     "convidado@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail(pt): %v", err)
	}
	en, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: "Apiário São João",
		InviterName:      "Ana",
		InviteeEmail:     "convidado@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail(en): %v", err)
	}

	if pt.Subject == en.Subject || pt.TextBody == en.TextBody {
		t.Fatalf("pt-PT rendered identically to en-GB — the catalog is not being selected")
	}
	if !strings.Contains(pt.TextBody, "organização") || !strings.Contains(pt.TextBody, "iniciar sessão") {
		t.Errorf("pt body does not read as Portuguese: %q", pt.TextBody)
	}
	if !strings.Contains(en.TextBody, "sign in") {
		t.Errorf("en body does not read as English: %q", en.TextBody)
	}
	// Both catalogs must interpolate every field -- a template typo in one
	// language is otherwise invisible until a Portuguese user is invited.
	for _, body := range []string{pt.Subject, pt.TextBody, pt.HTMLBody} {
		if !strings.Contains(body, "Apiário São João") {
			t.Errorf("pt part does not name the organization: %q", body)
		}
	}
}

// A missing inviter name (identity has no display name for the admin) must
// not render an empty gap or the word "undefined" -- the message falls back to
// an impersonal phrasing that still names the organization.
func TestInvitationEmail_NoInviterName_FallsBackWithoutAGap(t *testing.T) {
	for _, locale := range []string{"en-GB", "pt-PT"} {
		msg, err := invitationEmail(locale, invitationEmailData{
			OrganizationName: "Dev Apiary Co.",
			InviteeEmail:     "invitee@example.com",
			SignUpURL:        "https://app.example/login",
		})
		if err != nil {
			t.Fatalf("invitationEmail(%s): %v", locale, err)
		}
		if strings.Contains(msg.Subject, "  ") || strings.HasPrefix(msg.Subject, " ") {
			t.Errorf("%s subject has a gap where the inviter name would be: %q", locale, msg.Subject)
		}
		if !strings.Contains(msg.Subject, "Dev Apiary Co.") {
			t.Errorf("%s subject lost the organization name: %q", locale, msg.Subject)
		}
		if strings.Contains(msg.TextBody, "<no value>") || strings.Contains(msg.HTMLBody, "<no value>") {
			t.Errorf("%s body rendered a template zero value: %q", locale, msg.TextBody)
		}
	}
}

// SECURITY (#641 review): the organization and inviter names are free text a
// user typed. A name carrying CR/LF must never produce extra header lines --
// here they are collapsed to spaces before the subject is built, and
// services/shared/mail rejects any that survive.
func TestInvitationEmail_HeaderInjectionInNamesIsNeutralized(t *testing.T) {
	msg, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: "Evil Co\r\nBcc: attacker@evil.test",
		InviterName:      "Mallory\nX-Injected: yes",
		InviteeEmail:     "invitee@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail: %v", err)
	}
	if strings.ContainsAny(msg.Subject, "\r\n") {
		t.Fatalf("subject still contains a line break: %q", msg.Subject)
	}
	if strings.Contains(msg.Subject, "Bcc:") && strings.ContainsAny(msg.Subject, "\r\n") {
		t.Fatalf("subject could inject a Bcc header: %q", msg.Subject)
	}
}

// SECURITY: an organization name containing markup must render as TEXT in the
// HTML part, never as live markup (html/template contextual escaping).
func TestInvitationEmail_HTMLPartEscapesUserSuppliedNames(t *testing.T) {
	msg, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: `<script>alert(1)</script>`,
		InviterName:      `<img src=x onerror=alert(2)>`,
		InviteeEmail:     "invitee@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail: %v", err)
	}
	// The escaped text legitimately still CONTAINS the substring "onerror=";
	// what must not survive is a real tag, i.e. an unescaped `<`.
	if strings.Contains(msg.HTMLBody, "<script>") || strings.Contains(msg.HTMLBody, "<img ") {
		t.Fatalf("html body contains unescaped user markup: %q", msg.HTMLBody)
	}
	if !strings.Contains(msg.HTMLBody, "&lt;script&gt;") {
		t.Errorf("html body did not escape the organization name: %q", msg.HTMLBody)
	}
	if !strings.Contains(msg.HTMLBody, "&lt;img") {
		t.Errorf("html body did not escape the inviter name: %q", msg.HTMLBody)
	}
}

// A pathologically long organization name must not produce an unbounded
// Subject header (a knob any admin could turn).
func TestInvitationEmail_LongOrganizationNameIsCapped(t *testing.T) {
	msg, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: strings.Repeat("á", 500),
		InviterName:      "Ana",
		InviteeEmail:     "invitee@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail: %v", err)
	}
	if n := len([]rune(msg.Subject)); n > maxSubjectNameRunes+80 {
		t.Fatalf("subject is %d runes, want it capped near %d", n, maxSubjectNameRunes)
	}
	// Truncation must not slice a multi-byte rune in half.
	if !strings.HasPrefix(msg.Subject, "Ana") {
		t.Errorf("subject = %q, want it to start with the inviter", msg.Subject)
	}
}

// AC: the message must not disclose whether the invited address already has an
// account -- the rendered bytes are identical either way, because nothing in
// the render depends on that fact. Pinned as a test so a future "welcome
// back"/"create your account" split cannot be added without failing here.
func TestInvitationEmail_SaysNothingAboutWhetherTheAddressHasAnAccount(t *testing.T) {
	msg, err := invitationEmail("en-GB", invitationEmailData{
		OrganizationName: "Dev Apiary Co.",
		InviterName:      "Ana",
		InviteeEmail:     "invitee@example.com",
		SignUpURL:        "https://app.example/login",
	})
	if err != nil {
		t.Fatalf("invitationEmail: %v", err)
	}
	for _, leak := range []string{
		"existing account", "already have an account", "your account",
		"no account", "new account for you",
	} {
		if strings.Contains(strings.ToLower(msg.TextBody), leak) {
			t.Errorf("text body leaks account existence via %q: %q", leak, msg.TextBody)
		}
	}
}

func TestSignUpURL_BuiltFromConfiguredBaseOnly(t *testing.T) {
	cases := map[string]string{
		"https://app.example":       "https://app.example/login",
		"https://app.example/":      "https://app.example/login",
		"https://app.example:8443/": "https://app.example:8443/login",
	}
	for base, want := range cases {
		if got := signUpURL(base); got != want {
			t.Errorf("signUpURL(%q) = %q, want %q", base, got, want)
		}
	}
}
