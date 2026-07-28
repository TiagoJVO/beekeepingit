#!/usr/bin/env bash
# Guard: every upstream federation source in the Authentik blueprint must keep
# the account posture #363 shipped (FR-TEN-1, NFR-SEC-1, D-7).
#
# Adding a federation source hands an EXTERNAL identity provider a path into
# accounts on this deployment. Three properties make that safe, and all three
# are one careless line away from being lost — so they are asserted here rather
# than left to review:
#
#   1. NO `enrollment_flow`. With it unset, an unknown upstream identity is
#      refused with an HTTP 400 and creates no rows at all
#      (core/sources/flow_manager.py `handle_enroll`, authentik 2026.5.4).
#      Setting it opens self-service account creation via the upstream, which
#      is #365 and NOT this issue — invitation-only account creation still
#      applies (auth.md §8.12).
#   2. `user_matching_mode: identifier`. Matching keys on the upstream's stable
#      SUBJECT. Any `email_*` mode would link an existing local account from an
#      upstream email — and authentik's Google source type drops Google's
#      `verified_email`, so that email is UNVERIFIED. That is the #170
#      account-takeover shape. Subject + known-email-history linking is #364.
#   3. Credentials by `!Env`, never literals. The blueprint is rendered into a
#      ConfigMap, so a literal (or Helm-interpolated) client secret would be
#      readable by anything in the namespace and visible in
#      `helm get manifest`. Credentials arrive as process env from the
#      out-of-band Secret merged into `beekeepingit-authentik-config`
#      (charts/authentik/templates/config-secret.yaml).
#
# Plus two structural properties the above depend on:
#   4. Every source entry is `conditions:`-gated, so a cluster without those
#      credentials skips the entry instead of failing serializer validation —
#      which would invalidate the WHOLE blueprint (the PR #414 failure mode).
#   5. The default identification stage is never left with EMPTY `user_fields`,
#      which would trip authentik's AutoRedirectController and send every login
#      to a source with no way to reach the password form.
#
# Deterministic and offline: asserts over the blueprint SOURCE, with no cluster
# and no YAML parser (the file carries custom `!KeyOf`/`!Find`/`!Env` tags a
# plain parser would reject). Same engine style as
# scripts/check-scope-mapping-provider.sh.
#
# The dev/CI stand-in source is held to the SAME bar on purpose: it exists to
# exercise the identical code path, so it must carry the identical posture.
#
# Run by `task repo:federation-source-posture` -> `task repo:lint` -> `task ci`.
# An optional argument overrides the blueprint path.
#
# Exit codes: 0 = posture intact, 1 = drift.
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
blueprint="${1:-${repo_root}/infra/helm/beekeepingit/charts/authentik/files/beekeepingit.blueprint.yaml}"

if [ ! -f "${blueprint}" ]; then
  printf '✗ [federation-source] blueprint not found: %s\n' "${blueprint}" >&2
  exit 1
fi

# Walk the blueprint entry-by-entry. Top-level entries begin at `  - model:`;
# everything until the next one is that entry's body, joined into a single
# space-separated string so a value a reformat wrapped across lines still
# matches. Assertions run per entry in flush().
awk '
  function flush() {
    if (model == "") return

    if (model ~ /authentik_sources_oauth\.oauthsource/) {
      sources++
      seen_ids = seen_ids " " id

      # (1) enrollment_flow must be absent. The boundary is a NON-identifier
      # character (not just whitespace) so a flow-style mapping — valid YAML,
      # and a bypass found in review — is caught too:
      #   attrs: {..., authentication_flow: x,enrollment_flow: !KeyOf y}
      # A leading identifier char still excludes an unrelated longer key such
      # as `pre_enrollment_flow:`.
      if (body ~ /(^|[^A-Za-z0-9_-])enrollment_flow[[:space:]]*:/) {
        printf("✗ [federation-source] %s sets `enrollment_flow` — that opens self-service account creation via the upstream (#365), which this posture forbids\n", id) > "/dev/stderr"
        status = 1
      }

      # (2) matching must key on the upstream subject.
      if (body !~ /user_matching_mode[[:space:]]*:[[:space:]]*identifier([^A-Za-z0-9_-]|$)/) {
        printf("✗ [federation-source] %s must set `user_matching_mode: identifier` — any email_* mode links an existing account from an UNVERIFIED upstream email (the #170 shape); subject+known-email linking is #364\n", id) > "/dev/stderr"
        status = 1
      }

      # (3) credentials must never be literals. consumer_key is exempt only
      # when it is a non-secret public client id AND consumer_secret is !Env
      # (the dev/CI stand-in, which authenticates against nothing).
      if (body !~ /consumer_secret[[:space:]]*:[[:space:]]*!Env[[:space:]]*\[/) {
        printf("✗ [federation-source] %s must take `consumer_secret` from `!Env` — the blueprint renders into a ConfigMap, so a literal or Helm-interpolated secret is readable namespace-wide\n", id) > "/dev/stderr"
        status = 1
      }

      # (4) the entry must be conditions-gated, so an environment without the
      # credentials skips it rather than failing validation for the whole file.
      if (body !~ /(^|[^A-Za-z0-9_-])conditions[[:space:]]*:/) {
        printf("✗ [federation-source] %s has no `conditions:` gate — an environment without its credentials would fail serializer validation and invalidate the ENTIRE blueprint (PR #414)\n", id) > "/dev/stderr"
        status = 1
      }
    }

    # (5) no identification-stage entry may empty user_fields.
    if (model ~ /authentik_stages_identification\.identificationstage/) {
      ident_entries++
      if (body ~ /user_fields:[[:space:]]*\[[[:space:]]*\]/) {
        printf("✗ [federation-source] an identification-stage entry sets an EMPTY `user_fields` — authentik auto-redirects such a stage to its single source, removing every way to reach the password form\n") > "/dev/stderr"
        status = 1
      }
      if (body !~ /user_fields:/) {
        printf("✗ [federation-source] an identification-stage entry omits `user_fields` — IdentificationStageSerializer cross-validates the entry`s OWN data and would reject it, invalidating the whole blueprint (PR #414)\n") > "/dev/stderr"
        status = 1
      }
    }
  }

  # Strip comments before anything else: the section documentation deliberately
  # names `enrollment_flow` and `email_link`, and must not be assertable text.
  # A YAML comment must be at line start or preceded by whitespace, so the
  # boundary is required — otherwise a legitimate `#` inside a value (a URL
  # fragment, a CSS colour) would be silently truncated, hiding real content
  # from the assertions above (review finding).
  { sub(/(^|[[:space:]])#.*$/, "") }
  /^[[:space:]]*$/ { next }

  # Fail closed on YAML anchors/aliases/merge keys ANYWHERE in the file. This
  # guard reasons over each entry`s own text and does not resolve anchors, so a
  # `<<: *shared` merge could reintroduce `enrollment_flow` into a source entry
  # from a definition elsewhere and pass assertion (1) unseen. The blueprint
  # has never used anchors; banning them outright is cheaper and more certain
  # than teaching this script to expand them. Same fail-closed-on-the-opaque
  # posture as scripts/check-scope-mapping-provider.sh.
  /(^|[[:space:]])(<<[[:space:]]*:|&[A-Za-z_]|\*[A-Za-z_])/ {
    printf("✗ [federation-source] line %d uses a YAML anchor/alias/merge key — this guard does not resolve them and cannot prove a source entry stays enrollment-closed; keep the blueprint anchor-free\n", FNR) > "/dev/stderr"
    status = 1
  }

  /^  - model:/ { flush(); model = $3; id = ""; body = ""; next }
  { body = body " " $0 }
  /^    id:/ { if (id == "") id = $2 }

  END {
    flush()
    if (sources == 0) {
      printf("✗ [federation-source] no oauthsource entry found — #363 shipped one; if it was removed on purpose, remove this guard in the same change\n") > "/dev/stderr"
      status = 1
    }
    if (ident_entries == 0) {
      printf("✗ [federation-source] no identification-stage entry found — the sources would never be shown on the login card\n") > "/dev/stderr"
      status = 1
    }
    if (status == 0) {
      printf("› [federation-source] ok: %d source(s) [%s ] are subject-matched, enrollment-closed, !Env-credentialed and conditions-gated\n", sources, seen_ids)
    }
    exit status
  }
' "${blueprint}"
