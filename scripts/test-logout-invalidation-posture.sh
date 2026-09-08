#!/usr/bin/env bash
# Negative-case suite for scripts/check-logout-invalidation-posture.sh (#237,
# NFR-SEC-1).
#
# That guard is the entire regression control for BOTH halves of #237 — an SSO
# session that outlives Sign out, and an allow-list that IS the open-redirect
# boundary once authentik starts validating `post_logout_redirect_uri` against
# it. Neither half fails loudly: the app keeps "logging out", it just stops
# meaning it. And a textual guard over a Helm-templated, custom-tagged YAML file
# has many ways to stop looking without saying so — three rounds of review found
# fail-OPEN holes in this one (a walk ended by a blank line, a quoted `"logout"`
# value that hid an `https://evil.example/.*` entry entirely, `state: created`
# on a provider). "The guard passes on main" proves nothing on its own, so its
# negative cases run WITH it rather than on trust — the same posture
# scripts/test-authorization-redirect-posture.sh established for #822's guard.
#
# Deterministic and offline: fixtures are derived from the committed blueprint
# in a temp dir; nothing is written to the tree and no cluster is touched.
#
# Run by `task repo:logout-invalidation-posture` -> `task repo:lint`.
# Exit codes: 0 = the guard behaves, 1 = a case did not.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
guard="${repo_root}/scripts/check-logout-invalidation-posture.sh"
blueprint="${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

failures=0
cases=0

# expect <expected-exit> <name> — checks the fixture ${tmp}/<name>.yaml written
# by one of the builders below. Never called on the right of a pipe: that runs
# it in a subshell, where the counters it updates are discarded and a failing
# case could not fail the suite.
expect() {
  local want="$1" name="$2" file="${tmp}/${2}.yaml" got=0
  cases=$((cases + 1))
  bash "${guard}" "${file}" >/dev/null 2>&1 || got=$?
  if [ "${got}" != "${want}" ]; then
    printf '✗ [logout-invalidation-test] %s: guard exited %s, expected %s\n' \
      "${name}" "${got}" "${want}" >&2
    failures=$((failures + 1))
  fi
}

# --- fixture builders -------------------------------------------------------
# Everything matches by EXACT LINE, so a fixture never depends on this script
# getting a regex right. Anchors and replacements travel through the
# ENVIRONMENT, not `awk -v`, because -v interprets backslash escapes and several
# of the rejected patterns below are literally about a backslash (`\d`).
#
# A blueprint reformat would leave a builder matching nothing and its case
# "passing" for the wrong reason, so every fixture is diffed against the
# original at the bottom of this file.

# Replace every line equal to $BK_A with $BK_R (which may be several lines).
sub_line() {
  BK_A="$2" BK_R="$3" awk '
    $0 == ENVIRON["BK_A"] { print ENVIRON["BK_R"]; next } { print }
  ' "${blueprint}" >"${tmp}/$1.yaml"
}
# Insert $BK_R immediately after the FIRST line equal to $BK_A.
insert_after_first_line() {
  BK_A="$2" BK_R="$3" awk '
    { print }
    $0 == ENVIRON["BK_A"] && !done { print ENVIRON["BK_R"]; done = 1 }
  ' "${blueprint}" >"${tmp}/$1.yaml"
}
# Delete the FIRST line equal to $BK_A plus the following $BK_N lines.
delete_first_run() {
  BK_A="$2" BK_N="$3" awk '
    !done && $0 == ENVIRON["BK_A"] { skip = ENVIRON["BK_N"] + 0; done = 1; next }
    skip > 0 { skip--; next }
    { print }
  ' "${blueprint}" >"${tmp}/$1.yaml"
}
# Replace EVERY three-line run $BK_A/$BK_B/$BK_C with $BK_R (empty = delete).
# The blueprint's logout entries are three-line block mappings, and awk sees one
# line at a time — so the file is buffered and matched as a run.
sub_block() {
  BK_A="$2" BK_B="$3" BK_C="$4" BK_R="$5" awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] == ENVIRON["BK_A"] && line[i + 1] == ENVIRON["BK_B"] &&
            line[i + 2] == ENVIRON["BK_C"]) {
          if (ENVIRON["BK_R"] != "") print ENVIRON["BK_R"]
          i += 2
          continue
        }
        print line[i]
      }
    }
  ' "${blueprint}" >"${tmp}/$1.yaml"
}

# --- anchors ----------------------------------------------------------------
stage_model='  - model: authentik_stages_user_logout.userlogoutstage'
binding_model='  - model: authentik_flows.flowstagebinding'
binding_target='      target: !KeyOf flow-default-provider-invalidation'
provider_inval='      invalidation_flow: !KeyOf flow-default-provider-invalidation'
authz_5175='        - { matching_mode: strict, url: "http://localhost:5175" }'
# The last line of the #599 identifiers-only pin entry — a clean place to splice
# a WHOLE extra top-level entry without disturbing the one above it.
pin_last='    identifiers: { slug: default-provider-invalidation-flow }'

# The pwa provider's Flutter dev-server logout entry, as its three lines. Only
# that provider carries port 5175, so this block occurs exactly once.
l_mode='        - matching_mode: strict'
l_url_5175='          url: "http://localhost:5175"'
l_type='          redirect_uri_type: logout'
l_url_app='          url: "{{ .Values.global.appOrigin }}"'
l_url_admin='          url: "{{ .Values.global.adminOrigin }}"'
entry_5175="${l_mode}
${l_url_5175}
${l_type}"

# --- the file as committed --------------------------------------------------
cp "${blueprint}" "${tmp}/clean.yaml"
expect 0 clean

# --- (1) the session half: the stage and its binding ------------------------
# No stage at all: the SSO session outlives Sign out and re-entry needs no
# password — #237's security defect, exactly.
delete_first_run stage-deleted "${stage_model}" 4
expect 1 stage-deleted

# The stage is declared but never bound. An unbound stage is decoration: the
# flow still runs no stages, so nothing ends the session. (Ours is the FIRST
# `flowstagebinding` in the file; the others are #361/#363's.)
delete_first_run binding-deleted "${binding_model}" 5
expect 1 binding-deleted

# `state: absent` DELETES the entry on apply while the text stays in the file.
insert_after_first_line stage-state-absent "${stage_model}" '    state: absent'
expect 1 stage-state-absent
insert_after_first_line binding-state-absent "${binding_model}" '    state: absent'
expect 1 binding-state-absent

# `conditions: [false]` leaves the planner skipping the entry, silently.
insert_after_first_line binding-condition-false "${binding_model}" '    conditions: [false]'
expect 1 binding-condition-false

# A duplicate `target:` is last-wins in PyYAML: this guard would read the pinned
# invalidation flow while authentik binds the stage somewhere else entirely.
insert_after_first_line binding-dup-target "${binding_target}" \
  '      target: !KeyOf flow-default-provider-authorization'
expect 1 binding-dup-target

# Re-point both providers' `invalidation_flow`: the binding stays present,
# correct and attached — to a flow neither provider ever plans.
sub_line provider-inval-repointed "${provider_inval}" \
  '      invalidation_flow: !KeyOf flow-default-provider-authorization'
expect 1 provider-inval-repointed

# Owning a `designation: invalidation` flow re-arms #599's slug-ordering trap: a
# `beekeepingit-*` slug sorts ahead of `default-invalidation-flow`, so
# authentik's own UI logout would silently start running our flow.
insert_after_first_line owned-invalidation-flow "${stage_model}" \
  '  - model: authentik_flows.flow
    id: flow-beekeepingit-invalidation
    identifiers: { slug: beekeepingit-invalidation }
    attrs:
      designation: invalidation'
expect 1 owned-invalidation-flow

# --- (2) the return half: the logout allow-list -----------------------------
# Since #822 a localhost dev redirect is a STRICT LITERAL per real dev port.
# Every regex spelling is unsafe on its own axis, so each is rejected on its own:
#   `.*`     — fullmatches http://localhost:@evil.example (userinfo host)
#   `\d+`    — unicode digits, and `urlparse(...).port` raises in `cors_allow`
#   `[0-9]+` — bracketed netloc; 500s every request carrying an `Origin`
sub_block logout-localhost-wildcard "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: regex
          url: "http://localhost:.*"
          redirect_uri_type: logout'
expect 1 logout-localhost-wildcard

sub_block logout-localhost-backslash-d "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: regex
          url: "http://localhost:\d+"
          redirect_uri_type: logout'
expect 1 logout-localhost-backslash-d

sub_block logout-localhost-bracketed "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: regex
          url: "http://localhost:[0-9]+"
          redirect_uri_type: logout'
expect 1 logout-localhost-bracketed

# A REVIEWED url with the mode widened to `regex`. Under `fullmatch` every
# unescaped `.` becomes a wildcard — how a rendered origin turns into a
# look-alike registrable domain — so the PAIR is the check, not the URL alone.
sub_block logout-mode-widened "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: regex
          url: "http://localhost:5175"
          redirect_uri_type: logout'
expect 1 logout-mode-widened

# An unreviewed dev port is a deliberate edit to the guard, not a free entry.
sub_block logout-unreviewed-port "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: strict
          url: "http://localhost:31337"
          redirect_uri_type: logout'
expect 1 logout-unreviewed-port

# A hand-written attacker origin appended to the list.
sub_block logout-evil-origin "${l_mode}" "${l_url_5175}" "${l_type}" \
  "${entry_5175}
        - matching_mode: strict
          url: \"https://evil.example\"
          redirect_uri_type: logout"
expect 1 logout-evil-origin

# The quoted-key/value evasion an earlier review found: `redirect_uri_type:
# \"logout\"` is the same entry to PyYAML, but a bare `: logout` pattern never
# matched it — so that URL was not recognised as a logout target at all and NO
# allow-list assertion ever reached it.
sub_block logout-quoted-keys-evil "${l_mode}" "${l_url_5175}" "${l_type}" \
  "${entry_5175}
        - \"matching_mode\": \"strict\"
          \"url\": \"https://evil.example\"
          \"redirect_uri_type\": \"logout\""
expect 1 logout-quoted-keys-evil

# PyYAML last-wins on a duplicated key: the guard reads the first `url:`, the
# provider applies the second.
sub_block logout-dup-url-key "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: strict
          url: "http://localhost:5175"
          url: "https://evil.example"
          redirect_uri_type: logout'
expect 1 logout-dup-url-key

# The same trick on the TYPE key: read as `authorization` here (and skipped),
# applied as `logout` by authentik.
sub_block logout-dup-type-key "${l_mode}" "${l_url_5175}" "${l_type}" \
  "${entry_5175}
        - matching_mode: strict
          url: \"https://evil.example\"
          redirect_uri_type: authorization
          redirect_uri_type: logout"
expect 1 logout-dup-type-key

# An unquoted value is not readable by this guard — or by review.
sub_block logout-unquoted-url "${l_mode}" "${l_url_5175}" "${l_type}" \
  '        - matching_mode: strict
          url: http://localhost:5175
          redirect_uri_type: logout'
expect 1 logout-unquoted-url

# Drop the app origin: the PWA's own `post_logout_redirect_uri` stops matching
# and Sign out regresses from the interstitial to a 400.
sub_block logout-drop-app-origin "${l_mode}" "${l_url_app}" "${l_type}" ''
expect 1 logout-drop-app-origin

# Drop the admin origin everywhere: the admin app signs out through THIS
# application's end_session_endpoint (#460), so admin sign-out 400s.
sub_block logout-drop-admin-origin "${l_mode}" "${l_url_admin}" "${l_type}" ''
expect 1 logout-drop-admin-origin

# --- (2b/2c/2d) the evasions review found in the guard itself ---------------
# A quoted MODEL is the same entry to PyYAML, and prettier PRESERVES the quotes
# — so an anchored `~ /authentik_flows\.flow$/` was a full bypass of the
# owned-invalidation-flow assertion until the model was normalised at capture.
insert_after_first_line owned-invalidation-flow-quoted-model "${pin_last}"   '  - model: "authentik_flows.flow"
    id: flow-evil-invalidation
    identifiers: { slug: beekeepingit-evil-invalidation }
    attrs:
      designation: invalidation'
expect 1 owned-invalidation-flow-quoted-model

# A top-level entry the walker does not recognise is folded into the PREVIOUS
# entry and never examined. Here: a whole extra provider with `id:` before
# `model:`, carrying a regex logout target.
insert_after_first_line unparseable-top-level-entry "${pin_last}"   '  - id: provider-evil
    model: authentik_providers_oauth2.oauth2provider
    identifiers: { name: beekeepingit-evil }
    attrs:
      redirect_uris:
        - matching_mode: regex
          url: "https://evil.example/.*"
          redirect_uri_type: logout'
expect 1 unparseable-top-level-entry

# A SECOND binding onto the shared invalidation flow. It carries a different
# stage, so the target+stage count is blind to it — and at `order: 0` it runs
# BEFORE the logout stage and can send the browser away, SSO cookie intact.
insert_after_first_line second-binding-on-invalidation-flow "${binding_model}"   '    id: binding-evil-preempt
    identifiers:
      target: !KeyOf flow-default-provider-invalidation
      stage: !KeyOf stage-provider-invalidation-logout
      order: 0
  - model: authentik_flows.flowstagebinding'
expect 1 second-binding-on-invalidation-flow

# A POLICY binding onto the logout stage binding is `conditions:` by another
# name: authentik skips a stage whose bound policies deny.
insert_after_first_line policy-binding-on-logout-binding "${pin_last}"   '  - model: authentik_policies.policybinding
    id: binding-evil-policy
    identifiers:
      target: !KeyOf binding-provider-invalidation-logout
      order: 0'
expect 1 policy-binding-on-logout-binding

# --- (3) the bracket ban, on EVERY redirect URI -----------------------------
# One bracketed entry `urlparse()`s as an IPv6 literal in `cors_allow` and 500s
# every request carrying an `Origin` header — discovery included — while
# in-cluster probes, which send none, stay green. It cost this change a
# 30-minute k3d run, so it is banned on AUTHORIZATION entries too.
sub_line bracketed-authorization-entry "${authz_5175}" \
  '        - { matching_mode: regex, url: "http://localhost:[0-9]+" }'
expect 1 bracketed-authorization-entry

# --- anchor guards ----------------------------------------------------------
# Every builder above matches by exact line. If the blueprint is reformatted a
# builder silently produces an unmodified copy and its case "passes" for the
# wrong reason — so assert each anchor is still there, and that every fixture
# really differs from the original.
for anchor in "${stage_model}" "${binding_model}" "${binding_target}" \
  "${provider_inval}" "${authz_5175}" "${pin_last}" "${l_mode}" "${l_url_5175}" "${l_type}" \
  "${l_url_app}" "${l_url_admin}"; do
  if ! grep -qxF "${anchor}" "${blueprint}"; then
    printf '✗ [logout-invalidation-test] fixture anchor no longer in the blueprint: %s\n' \
      "${anchor}" >&2
    failures=$((failures + 1))
  fi
done

for f in "${tmp}"/*.yaml; do
  case "${f}" in
  */clean.yaml) continue ;;
  esac
  if cmp -s "${f}" "${blueprint}"; then
    printf '✗ [logout-invalidation-test] fixture %s is identical to the blueprint — its builder matched nothing\n' \
      "$(basename "${f}")" >&2
    failures=$((failures + 1))
  fi
done

if [ "${failures}" -ne 0 ]; then
  printf '✗ [logout-invalidation-test] %d failure(s) across %d case(s)\n' "${failures}" "${cases}" >&2
  exit 1
fi
printf '✓ [logout-invalidation-test] %d case(s): the guard accepts the committed blueprint and rejects every tampering\n' "${cases}"
