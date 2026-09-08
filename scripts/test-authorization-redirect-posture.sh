#!/usr/bin/env bash
# Negative-case suite for scripts/check-authorization-redirect-posture.sh (#822,
# NFR-SEC-1).
#
# That guard is the ENTIRE regression control for a priority/critical finding —
# an account-takeover-grade redirect URI — and a textual guard over a
# Helm-templated, custom-tagged YAML file has many ways to stop looking without
# saying so. A security review of its first version found four fail-OPEN holes
# in ten minutes (a blank line inside the list, a `{{- if }}` inside the list, a
# regex template with the dot-escape dropped, a provider written as a flow map).
# So the guard gets tests: each case below is a real tampering of the real
# blueprint, and the suite asserts the guard REJECTS it. "The guard passes on
# main" proves nothing on its own.
#
# Deterministic and offline: fixtures are derived from the committed blueprint
# in a temp dir; nothing is written to the tree and no cluster is touched.
#
# Run by `task repo:authorization-redirect-posture` -> `task repo:lint`.
# Exit codes: 0 = the guard behaves, 1 = a case did not.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
guard="${repo_root}/scripts/check-authorization-redirect-posture.sh"
blueprint="${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# The line both providers carry today, matched by exact string so the fixtures
# never depend on this script getting a regex right. Since the owner decision on
# #822 the localhost dev origins are STRICT literals, one per real dev port, so
# the shared line is the admin dev server's — the only one both providers carry
# (the pwa provider also carries 5175, the Flutter dev server).
orig='        - { matching_mode: strict, url: "http://localhost:5174" }'
evil='        - { matching_mode: regex, url: "https://evil.example/.*" }'

failures=0
cases=0

# expect <expected-exit> <name> — checks the fixture ${tmp}/<name>.yaml written
# by one of the builders below. Never called on the right of a pipe: that runs
# it in a subshell, where the counters it updates are discarded and a failing
# case cannot fail the suite.
expect() {
  local want="$1" name="$2" file="${tmp}/${2}.yaml" got=0
  cases=$((cases + 1))
  bash "${guard}" "${file}" >/dev/null 2>&1 || got=$?
  if [ "${got}" != "${want}" ]; then
    printf '✗ [authorization-redirect-test] %s: guard exited %s, expected %s\n' \
      "${name}" "${got}" "${want}" >&2
    failures=$((failures + 1))
  fi
}

# Replace every occurrence of the localhost line with <text> (which may itself
# be several lines), writing fixture <name>.
sub_all() {
  awk -v orig="${orig}" -v repl="$2" '$0 == orig { print repl; next } { print }' \
    "${blueprint}" >"${tmp}/$1.yaml"
}
# Insert <text> right after the FIRST localhost line (i.e. inside the PWA
# provider's list), leaving the rest of the file alone.
insert_after_first() {
  awk -v orig="${orig}" -v add="$2" '{ print } $0 == orig && !done { print add; done = 1 }' \
    "${blueprint}" >"${tmp}/$1.yaml"
}

# --- the file as committed, and the shape #823 adds on top of it -------------
cp "${blueprint}" "${tmp}/clean.yaml"
expect 0 clean
insert_after_first logout-entries-compose '        - matching_mode: strict
          url: "{{ .Values.global.appOrigin }}"
          redirect_uri_type: logout
        - matching_mode: strict
          url: "http://localhost:5174"
          redirect_uri_type: logout'
expect 0 logout-entries-compose

# --- the defect itself, and its near neighbours ------------------------------
sub_all loose-wildcard '        - { matching_mode: regex, url: "http://localhost:.*" }'
expect 1 loose-wildcard
sub_all empty-port-allowed '        - { matching_mode: regex, url: "http://localhost:[0-9]*(/.*)?" }'
expect 1 empty-port-allowed

# --- the two regexes the owner decision disqualified, one case per hazard ----
#
# HAZARD 1 — `\d` matches UNICODE decimal digits, so the pattern allow-lists a
# URL that is not a port at all, and `urlparse(...).port` still raises (hostname
# parses as `localhost`, so `cors_allow` reaches the port comparison and 500s
# every localhost `Origin`). Verified on Python 3.11.0:
#   re.fullmatch(r"http://localhost:\d+(/.*)?", "http://localhost:٤٥") -> True
#   urlparse(r"http://localhost:\d+(/.*)?").port
#     -> ValueError: Port could not be cast to integer value as '\d+('
sub_all unicode-digit-shorthand '        - { matching_mode: regex, url: "http://localhost:\\d+(/.*)?" }'
expect 1 unicode-digit-shorthand
sub_all unicode-digit-shorthand-pathless '        - { matching_mode: regex, url: "http://localhost:\\d+" }'
expect 1 unicode-digit-shorthand-pathless

# HAZARD 2 — a BRACKETED host. `urlparse` treats a bracketed netloc as an IPv6
# literal: on Python 3.11.0 the hostname is `0-9` (so the entry grants no
# localhost CORS at all), and later CPython raises `ValueError: Invalid IPv6
# URL`, which 500s the discovery document for any request with an `Origin`
# header — the failure that cost PR #823 a 30-minute k3d run.
sub_all bracketed-host '        - { matching_mode: regex, url: "http://localhost:[0-9]+(/.*)?" }'
expect 1 bracketed-host
sub_all bracketed-host-pathless '        - { matching_mode: regex, url: "http://localhost:[0-9]+" }'
expect 1 bracketed-host-pathless
# Neither hazard is about the localhost host specifically — the ban is on the
# characters, in any redirect URI, so it cannot be sidestepped by using them in
# a rendered-origin entry.
sub_all bracketed-char-class-in-host-regex "        - { matching_mode: regex, url: '{{ .Values.global.appOrigin | replace \".\" \"\\\\.\" }}/[a-z].*' }"
expect 1 bracketed-char-class-in-host-regex

# --- an unlisted dev port is a deliberate edit, not something a pattern covers
sub_all unlisted-dev-port '        - { matching_mode: strict, url: "http://localhost:3000" }'
expect 1 unlisted-dev-port

# --- a new origin, of any redirect type (token.py CORS derivation is unfiltered)
sub_all new-origin "${evil}"
expect 1 new-origin
insert_after_first new-origin-via-logout '        - matching_mode: strict
          url: "https://partner.example"
          redirect_uri_type: logout'
expect 1 new-origin-via-logout

# --- template forms: the dot-escape and the values key are both load-bearing --
sub_all regex-template-without-dot-escape "        - { matching_mode: regex, url: '{{ .Values.global.appOrigin }}/.*' }"
expect 1 regex-template-without-dot-escape
sub_all bare-template-as-regex '        - { matching_mode: regex, url: "{{ .Values.global.appOrigin }}" }'
expect 1 bare-template-as-regex
sub_all template-default-filter "        - { matching_mode: regex, url: '{{ .Values.global.appOrigin | default \"https://evil.example\" }}/.*' }"
expect 1 template-default-filter
sub_all template-printf-alternation "        - { matching_mode: regex, url: '{{ printf \"https://evil.example|\" }}{{ .Values.global.appOrigin }}' }"
expect 1 template-printf-alternation
sub_all unknown-values-key '        - { matching_mode: strict, url: "{{ .Values.global.someOtherHost }}" }'
expect 1 unknown-values-key
# The MODE is half of the allow-list key: a literal dev origin declared `regex`
# is a different trust boundary (every `.` in it becomes a wildcard) and must
# not inherit the strict entry's approval.
sub_all localhost-literal-as-regex '        - { matching_mode: regex, url: "http://localhost:5174" }'
expect 1 localhost-literal-as-regex

# --- things the guard must refuse to read rather than skip -------------------
sub_all unquoted-url '        - { matching_mode: strict, url: http://localhost:5174 }'
expect 1 unquoted-url
sub_all duplicate-url-key '        - { matching_mode: strict, url: "http://localhost:5174", url: "https://evil.example/.*" }'
expect 1 duplicate-url-key
sub_all missing-matching-mode '        - { url: "http://localhost:5174" }'
expect 1 missing-matching-mode
insert_after_first blank-line-then-new-origin "
${evil}"
expect 1 blank-line-then-new-origin
insert_after_first helm-action-inside-list "        {{- if .Values.global.devRedirects }}
${evil}"
expect 1 helm-action-inside-list
{
  cat "${blueprint}"
  printf '  - { model: authentik_providers_oauth2.oauth2provider, id: provider-evil, attrs: { redirect_uris: [ { matching_mode: regex, url: "https://evil.example/.*" } ] } }\n'
} >"${tmp}/flow-map-provider.yaml"
expect 1 flow-map-provider

# --- the guard must notice it has drifted from its subject -------------------
sed 's|^    id: provider-beekeepingit-admin$|    id: provider-renamed|' "${blueprint}" >"${tmp}/provider-renamed.yaml"
expect 1 provider-renamed
awk '!/^      redirect_uris:[[:space:]]*$/ || ++n != 1' "${blueprint}" >"${tmp}/first-list-unparsed.yaml"
expect 1 first-list-unparsed

if [ "${failures}" -ne 0 ]; then
  printf '✗ [authorization-redirect-test] %d of %d case(s) failed\n' "${failures}" "${cases}" >&2
  exit 1
fi
printf '✓ [authorization-redirect-test] %d case(s): the guard accepts the committed blueprint and rejects every tampering\n' "${cases}"
