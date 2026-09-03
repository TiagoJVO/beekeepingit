{{- define "gateway.fullname" -}}
{{- printf "%s-gateway" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
gateway.assertPublicHostnames — refuse to render a publicly-issued TLS cert, a
credentialed CORS origin or an OIDC redirect URI for a loopback hostname
(#556, NFR-SEC-1).

Why this exists: staging's `beekeepingit-gateway-tls` Certificate carried this
chart's DEV DEFAULT `admin.beekeepingit.local` in its SAN, because the deployed
values live in the beekeepingit-gitops repo (D-27, ADR-0018) and were never given
`gateway.adminHost` when #449/#454 added the admin host — this repo's
`environments/staging.yaml` mirror got it, the gitops copy didn't, and the two
hand-synced copies drifted. Let's Encrypt then answered every renewal with
`400 urn:ietf:params:acme:error:rejectedIdentifier` ("Domain name does not end
with a valid public suffix"), so renewal was silently dead for five weeks.

Why the ORIGINS too and not just the TLS hosts: `global.appOrigin` /
`global.adminOrigin` are the SAME hand-synced values one layer up — the `services`
subchart builds each service's `CORS_ALLOWED_ORIGINS` from them and
`charts/authentik`'s blueprint templates the OAuth2 providers' redirect_uris and
CORS-allowed-origins from them (ADR-0016/ADR-0020). The same staging drift left
every Go service advertising `https://admin.beekeepingit.local:8443` as a
credentialed cross-origin allowlist entry and registered it as an OIDC redirect
URI. Guarding only the TLS hosts would let an operator silence this template by
setting `gateway.adminHost` alone and still ship that — silently, deploy-green.

Why a loud `fail` rather than quietly dropping or defaulting a value: a silent
fallback would still produce a certificate that doesn't cover the origin the admin
app is actually served from, and the operator would learn about it from a browser
TLS error in production. Failing the render surfaces the drift at `helm template`
/ Flux reconcile time — where it's cheap — and names every values key to fix.

Why ONE failure listing every offender: an operator fixing three drifted keys
should need one render cycle, not three. Offenders accumulate into a list and
`fail` runs once, at the end.

Why only `.local` / `.localhost` / bare `localhost` and NOT a real public-suffix
check: prod's `*.beekeepingit.example` hosts are deliberate placeholders
(ADR-0017/ADR-0020) and `.example` is likewise a reserved TLD, so a genuine PSL
check would break the prod overlay's render. These are the suffixes this chart's
own dev defaults use, which is exactly the drift that bit us.

Why normalize before matching: `ADMIN.BEEKEEPINGIT.LOCAL` and the trailing-dot
FQDN form `admin.beekeepingit.local.` are the same name to DNS and to a CA, so a
raw `hasSuffix` waves both through. Each value is lowercased and its root dot
trimmed once, up front, and a nil/absent value is normalized to "" rather than
reaching sprig as a nil (`--set gateway.appHost=null` used to die with a raw
template type error instead of this template's message).

Nil-safety: this subchart is also rendered against its OWN values.yaml (standalone,
without the umbrella), and that file supplies only `global: {namespace: ...}` — so
`.Values.global.appOrigin`/`.adminOrigin` are legitimately absent there. That mode
leaves `certManager.enabled` false and the whole guard inert, but every lookup
below is nil-tolerant regardless.
*/}}
{{- define "gateway.assertPublicHostnames" -}}
{{- if (.Values.certManager | default dict).enabled -}}
{{- $global := .Values.global | default dict -}}
{{- $offenders := list -}}

{{/*
appHost/authHost are REQUIRED: ingress.yaml renders them unconditionally, so an
empty one yields an Ingress rule with no host (a catch-all) and an empty TLS SAN
entry. Report that with this template's own message instead of letting the
invalid object travel to the API server.
*/}}
{{- range $key, $raw := (dict "gateway.appHost" .Values.appHost "gateway.authHost" .Values.authHost) -}}
{{- $h := $raw | default "" | toString | lower | trimSuffix "." -}}
{{- if eq $h "" -}}
{{- $offenders = append $offenders (printf "%s is empty or null, but cert-manager is enabled and this host is required — it is rendered as both an Ingress rule host and a certificate SAN entry" $key) -}}
{{- else if or (hasSuffix ".local" $h) (hasSuffix ".localhost" $h) (eq $h "localhost") -}}
{{- $offenders = append $offenders (printf "%s = %q is a loopback hostname (goes into the certificate SAN); no public CA can issue for it" $key $raw) -}}
{{- end -}}
{{- end -}}

{{/* adminHost is optional — ingress.yaml renders that host conditionally. */}}
{{- $adminHost := .Values.adminHost | default "" | toString | lower | trimSuffix "." -}}
{{- if and (ne $adminHost "") (or (hasSuffix ".local" $adminHost) (hasSuffix ".localhost" $adminHost) (eq $adminHost "localhost")) -}}
{{- $offenders = append $offenders (printf "gateway.adminHost = %q is a loopback hostname (goes into the certificate SAN); no public CA can issue for it" .Values.adminHost) -}}
{{- end -}}

{{/*
The browser-facing origins, one layer up. Host part only: strip the scheme, then
take everything before the first `/`, `:`, `?` or `#`. A port is legitimate
(dev's :8443 is k3d's host-port mapping) and is not what is being judged here.
*/}}
{{- $origins := dict -}}
{{- if $global.appOrigin -}}
{{- $_ := set $origins "global.appOrigin" $global.appOrigin -}}
{{- end -}}
{{- if $global.adminOrigin -}}
{{- $_ := set $origins "global.adminOrigin" $global.adminOrigin -}}
{{- end -}}
{{- range $key, $raw := $origins -}}
{{- $h := $raw | toString | lower | trimPrefix "https://" | trimPrefix "http://" | splitList "/" | first | splitList "?" | first | splitList "#" | first | splitList ":" | first | trimSuffix "." -}}
{{- if or (hasSuffix ".local" $h) (hasSuffix ".localhost" $h) (eq $h "localhost") -}}
{{- $offenders = append $offenders (printf "%s = %q has the loopback host %q; it is advertised to browsers as a credentialed CORS allowlist entry and registered as an OIDC redirect URI (ADR-0016/ADR-0020)" $key $raw $h) -}}
{{- end -}}
{{- end -}}

{{/*
The silent escape hatch: setting `gateway.adminHost: ""` in the gitops values is
the obvious way to make this template stop failing, and it would leave the admin
app permanently unreachable (no Ingress host serves it) while
`global.adminOrigin` still advertises an origin nothing answers on.
*/}}
{{- if and $global.adminOrigin (eq $adminHost "") -}}
{{- $offenders = append $offenders (printf "global.adminOrigin = %q is configured but gateway.adminHost is empty — no Ingress host serves that origin, so the admin app is unreachable while every service still allowlists it for CORS. Set gateway.adminHost to that origin's hostname — the umbrella's values.schema.json makes global.adminOrigin required, so emptying it is not the way out" $global.adminOrigin) -}}
{{- end -}}

{{- if $offenders -}}
{{- fail (printf "gateway: cert-manager is enabled, so these values become a public certificate's SAN and the browser origins this platform advertises — refusing to request a public (cert-manager/ACME) certificate, or to advertise a CORS/OIDC origin, for a hostname no public CA can issue for and no browser off a dev laptop can resolve (#556, NFR-SEC-1).\n\n%d offending value(s):\n  - %s\n\nHow to fix: the DEPLOYED values come from the beekeepingit-gitops repo's apps/<env>/beekeepingit-helmrelease.yaml (D-27, ADR-0018), NOT from this repo. Set the real public hostnames THERE, and mirror them in this repo's infra/helm/beekeepingit/environments/<env>.yaml — updating only the mirror is exactly what caused #556. Create the DNS A record BEFORE adding the host (see docs/adr/0020-admin-app-host-and-cross-origin-cors.md): a host with no A record only swaps a rejectedIdentifier failure for a failed HTTP-01 challenge, and ONE failed authorization invalidates the whole multi-SAN order — taking the app and auth certificates down with it." (len $offenders) (join "\n  - " $offenders)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
