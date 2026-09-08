// Package api (this file) -- the invitation email itself: what it says, in
// which language, and how user-supplied text gets into it safely (#641,
// FR-ONB-3, FR-TEN-2, D-3).
//
// WHY THIS LIVES HERE AND NOT IN THE IdP. Authentik already sends mail
// (ADR-0019: verification/enrollment links, `AUTHENTIK_EMAIL__*` into the
// config Secret, the in-cluster Mailpit sink for dev/CI). It was still the
// wrong home for this one: an invitation is an ORGANIZATIONS-domain event --
// it names an organization and an inviter this service owns and the IdP has
// never heard of, it fires on an app API call rather than inside a flow, and
// its per-invitation delivery outcome has to land in a column this service
// reads back to the admin. Putting it in Authentik would have meant custom
// template volume mounts on the external gitops HelmRelease (ADR-0019 §5
// records that cost) plus a way to report a send result back across the
// boundary. The relay is shared infrastructure; the message is ours.
//
// LANGUAGE (FR-ONB-3 AC 3, NFR-I18N-1). The recipient's own profile locale
// wins when identity knows the address; otherwise the organization's locale
// (organizations.organizations.locale, migration 00008). Both narrow to the
// two locales the app ships, en-GB and pt-PT, and anything else normalizes to
// en-GB rather than failing a send over a language tag.
//
// UNTRUSTED INPUT. The organization name and the inviter's display name are
// free text a user typed; the invited address is free text an admin typed.
// They reach three different sinks with three different rules:
//   - the Subject header -- control characters and line breaks collapsed to
//     spaces and the whole thing length-capped here, with services/shared/mail
//     REJECTING any leftover CR/LF as a header injection (defense in depth:
//     sanitize where a weird-but-legitimate org name should still send, reject
//     at the boundary where it must never get through);
//   - the HTML part -- html/template's contextual auto-escaping;
//   - the text part -- no escaping needed (a body cannot inject a header once
//     the mailer encodes it), only the same control-character scrub so a name
//     cannot forge extra lines of message text.
//
// The link is built from server configuration alone (APP_BASE_URL + a fixed
// path), never from anything in the request, so there is no open-redirect or
// attacker-chosen-target surface: see signUpURL.
package api

import (
	"bytes"
	"fmt"
	htmltemplate "html/template"
	"strings"
	texttemplate "text/template"
	"unicode"

	"github.com/TiagoJVO/beekeepingit/services/shared/mail"
)

// Locales this service renders email in -- the app's two shipped languages
// (NFR-I18N-1). Same domain as identity.users.locale and
// organizations.organizations.locale, so a value read from either column is
// always renderable.
const (
	localeEN = "en-GB"
	localePT = "pt-PT"
)

// maxSubjectNameRunes caps how much of a user-typed organization name is
// allowed into the Subject header. Long headers get folded or truncated
// unpredictably by receiving MTAs, and an unbounded name in a header is a
// gratuitous denial-of-service knob on a path an admin can trigger; the
// organization-name column itself is far longer than any subject line should be.
const maxSubjectNameRunes = 80

// invitationEmailData is everything the templates below interpolate. Every
// string field except SignUpURL originates from user input -- see the package
// comment for how each sink handles that.
type invitationEmailData struct {
	OrganizationName string
	// InviterName is the inviting admin's display name, or "" when identity
	// has no name for them (an incomplete profile). The templates fall back
	// to an impersonal phrasing rather than rendering an empty name.
	InviterName  string
	InviteeEmail string
	SignUpURL    string
}

// normalizeLocale maps a stored or resolved locale onto one this service can
// actually render, defaulting to en-GB. Accepts the loose forms a locale can
// arrive in (`pt`, `pt_PT`, `PT-pt`) because the fallback chain crosses a
// service boundary (identity's profile locale) and a language tag is never
// worth failing a send over.
func normalizeLocale(locale string) string {
	l := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(locale), "_", "-"))
	if l == "pt" || strings.HasPrefix(l, "pt-") {
		return localePT
	}
	return localeEN
}

// sanitizeHeaderText scrubs user-typed text destined for a header or a plain
// text body: every Unicode control character (CR and LF included) becomes a
// space, runs of whitespace collapse to one, and the result is trimmed. This
// is the SANITIZING half of the two-layer defense described in the package
// comment -- services/shared/mail still rejects a CR/LF that reaches it, so a
// bug here fails the send rather than injecting a header.
func sanitizeHeaderText(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if unicode.IsControl(r) {
			b.WriteRune(' ')
			continue
		}
		b.WriteRune(r)
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// truncateRunes shortens s to at most n runes, appending an ellipsis when it
// actually had to cut. Rune-based, not byte-based, so a Portuguese name is
// never sliced through the middle of a multi-byte character.
func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return strings.TrimSpace(string(runes[:n])) + "…"
}

// signUpURL builds the link the invitation points at: the app's own sign-in /
// sign-up entry (client/lib/routing/app_router.dart's `/login`, which is where
// the IdP enrollment link is surfaced -- auth.md §8.11).
//
// SECURITY: composed from the service's own APP_BASE_URL configuration plus a
// constant path, with NOTHING from the request or the database in it. There is
// deliberately no token, no invitation id and no email in the URL:
//
//   - acceptance is still the accept-on-login step (auth.md §8.7) -- the
//     invitation is claimed by the JWT's VERIFIED email claim, so a link that
//     leaked (forwarded mail, a proxy log, a shared inbox) grants nothing on
//     its own. Adding a bearer-style accept token would have created exactly
//     the credential-in-a-URL this design does not need;
//   - with no caller-controlled component there is no open-redirect or
//     attacker-chosen-target surface to allow-list against. The one URL this
//     service can ever emit is the one its operator configured.
func signUpURL(appBaseURL string) string {
	return strings.TrimSuffix(appBaseURL, "/") + "/login"
}

// invitationEmail renders the invitation message for locale. Returns a
// mail.Message ready to send: subject sanitized and capped, a text/plain part
// and an HTML part.
func invitationEmail(locale string, d invitationEmailData) (mail.Message, error) {
	t := invitationTexts[normalizeLocale(locale)]

	orgName := truncateRunes(sanitizeHeaderText(d.OrganizationName), maxSubjectNameRunes)
	inviterName := truncateRunes(sanitizeHeaderText(d.InviterName), maxSubjectNameRunes)

	view := struct {
		OrganizationName string
		InviterName      string
		InviteeEmail     string
		SignUpURL        string
		HasInviter       bool
	}{
		OrganizationName: orgName,
		InviterName:      inviterName,
		InviteeEmail:     d.InviteeEmail,
		SignUpURL:        d.SignUpURL,
		HasInviter:       inviterName != "",
	}

	subject, err := renderText(t.subject, view)
	if err != nil {
		return mail.Message{}, fmt.Errorf("render invitation subject: %w", err)
	}
	text, err := renderText(t.text, view)
	if err != nil {
		return mail.Message{}, fmt.Errorf("render invitation text body: %w", err)
	}
	html, err := renderHTML(t.html, view)
	if err != nil {
		return mail.Message{}, fmt.Errorf("render invitation html body: %w", err)
	}

	return mail.Message{
		To:       d.InviteeEmail,
		Subject:  sanitizeHeaderText(subject),
		TextBody: text,
		HTMLBody: html,
	}, nil
}

func renderText(tpl string, view any) (string, error) {
	t, err := texttemplate.New("m").Parse(tpl)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, view); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}
	return buf.String(), nil
}

// renderHTML uses html/template (never text/template) so the user-typed
// organization and inviter names are contextually auto-escaped -- an org
// literally named `<script>alert(1)</script>` renders as text in the mail
// client, not as markup.
func renderHTML(tpl string, view any) (string, error) {
	t, err := htmltemplate.New("m").Parse(tpl)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, view); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}
	return buf.String(), nil
}

type invitationText struct {
	subject string
	text    string
	html    string
}

// invitationTexts holds the EN/PT catalogs. They are Go templates rather than
// gen-l10n ARB entries on purpose: ARB is the Flutter client's catalog, and
// this message is composed server-side, in a service that has no Flutter
// runtime. Keeping the two strings side by side here is what makes it obvious
// when one language is edited and the other is not.
//
// Deliberate content choices, both of them #641 acceptance criteria:
//   - the message names the ORGANIZATION and the INVITER (AC 2), and points at
//     the sign-up flow;
//   - it says "sign in or create an account" and never anything conditional on
//     whether the address already has one. The wording is byte-identical for a
//     known and an unknown address, so the mail cannot be used to probe whether
//     someone has a BeekeepingIT account (account-enumeration, #641 security
//     review).
var invitationTexts = map[string]invitationText{
	localeEN: {
		subject: `{{if .HasInviter}}{{.InviterName}} invited you to join {{.OrganizationName}} on BeekeepingIT{{else}}You have been invited to join {{.OrganizationName}} on BeekeepingIT{{end}}`,
		text: `{{if .HasInviter}}{{.InviterName}} has invited you{{else}}You have been invited{{end}}` +
			` to join the organization "{{.OrganizationName}}" on BeekeepingIT.

To accept, open BeekeepingIT and sign in — or create an account if you do not
have one yet:

    {{.SignUpURL}}

Use this email address: {{.InviteeEmail}}
You will join "{{.OrganizationName}}" automatically the first time you sign in
with that address; there is nothing else to click here.

If you were not expecting this invitation, you can ignore this message. Nothing
happens until you sign in yourself.

— BeekeepingIT
`,
		html: `<!-- BeekeepingIT organization invitation (#641, FR-ONB-3) -->
<p>{{if .HasInviter}}<strong>{{.InviterName}}</strong> has invited you{{else}}You have been invited{{end}} to join the organization <strong>{{.OrganizationName}}</strong> on BeekeepingIT.</p>
<p>To accept, open BeekeepingIT and sign in — or create an account if you do not have one yet:</p>
<p><a href="{{.SignUpURL}}">{{.SignUpURL}}</a></p>
<p>Use this email address: <strong>{{.InviteeEmail}}</strong><br>
You will join &quot;{{.OrganizationName}}&quot; automatically the first time you sign in with that address; there is nothing else to click here.</p>
<p>If you were not expecting this invitation, you can ignore this message. Nothing happens until you sign in yourself.</p>
<p>— BeekeepingIT</p>
`,
	},
	localePT: {
		subject: `{{if .HasInviter}}{{.InviterName}} convidou-o para a organização {{.OrganizationName}} no BeekeepingIT{{else}}Foi convidado para a organização {{.OrganizationName}} no BeekeepingIT{{end}}`,
		text: `{{if .HasInviter}}{{.InviterName}} convidou-o{{else}}Foi convidado{{end}}` +
			` para se juntar à organização "{{.OrganizationName}}" no BeekeepingIT.

Para aceitar, abra o BeekeepingIT e inicie sessão — ou crie uma conta, caso
ainda não tenha:

    {{.SignUpURL}}

Utilize este endereço de email: {{.InviteeEmail}}
Passará a fazer parte de "{{.OrganizationName}}" automaticamente na primeira vez
que iniciar sessão com esse endereço; não há mais nada a fazer aqui.

Se não estava à espera deste convite, pode ignorar esta mensagem. Nada acontece
enquanto não iniciar sessão.

— BeekeepingIT
`,
		html: `<!-- Convite para organização BeekeepingIT (#641, FR-ONB-3) -->
<p>{{if .HasInviter}}<strong>{{.InviterName}}</strong> convidou-o{{else}}Foi convidado{{end}} para se juntar à organização <strong>{{.OrganizationName}}</strong> no BeekeepingIT.</p>
<p>Para aceitar, abra o BeekeepingIT e inicie sessão — ou crie uma conta, caso ainda não tenha:</p>
<p><a href="{{.SignUpURL}}">{{.SignUpURL}}</a></p>
<p>Utilize este endereço de email: <strong>{{.InviteeEmail}}</strong><br>
Passará a fazer parte de &quot;{{.OrganizationName}}&quot; automaticamente na primeira vez que iniciar sessão com esse endereço; não há mais nada a fazer aqui.</p>
<p>Se não estava à espera deste convite, pode ignorar esta mensagem. Nada acontece enquanto não iniciar sessão.</p>
<p>— BeekeepingIT</p>
`,
	},
}
