# Federation-posture + account-linking probe (#363, #364, NFR-SEC-1, NFR-TST-1)
# — run inside the authentik worker:
# `ak shell -c "$(cat authentik-federation-probe.py)"`.
#
# WHY THIS EXISTS. A live end-to-end against real Google is not automatable
# (consent screen + bot detection) and must never run in CI, so the INBOUND
# half of federation — what authentik decides when an upstream identity comes
# back — cannot be proven through a browser. This drives the real
# `SourceFlowManager` (and therefore the real `SourceMatcher` and the real,
# deployed account-resolution property mapping) against the dev/CI stand-in
# source, which carries the IDENTICAL posture as the Google one:
# `user_matching_mode: username_link`, the `mapping-federation-account-link`
# resolver attached, no `enrollment_flow`, `authentication_flow:
# default-source-authentication`.
#
# WHAT IT PROVES (#364's acceptance criteria, live, against the real code):
#   1. SUBJECT WINS. An identity whose `UserSourceConnection` already exists
#      resolves to that user by identifier ALONE — asserted with a DIFFERENT
#      and deliberately UNVERIFIED upstream email in the payload, so the
#      assertion is about the subject and nothing else. `attributes.upn` (what
#      the provider emits as the OIDC `sub`) is unchanged: D-7's boundary.
#   2. VERIFIED-EMAIL FIRST LINK. An unlinked identity whose upstream email is
#      genuinely verified and matches exactly one local, active, non-superuser,
#      LOCALLY-verified account resolves to that account (Action.LINK) — no
#      duplicate account.
#   3. CHANGED ADDRESS, VIA HISTORY. The same, matching an address that is only
#      in that account's `attributes.known_emails` and no longer its current
#      `email`.
#   4. UNVERIFIED NEVER LINKS. The same address with the upstream's
#      verification flag false / a string "true" / absent is DENIED, creating
#      no rows. That is the #170 account-takeover shape, refused live.
#   5. AMBIGUITY, SQUATTING, PRIVILEGE AND UNKNOWNS ALL FAIL CLOSED. Two
#      accounts sharing the address, an account that never proved inbox control
#      itself, a superuser, and an address nobody holds are each DENIED with no
#      rows created — so invitation-only account creation still holds.
#   6. THE HISTORY IS ACTUALLY WRITTEN. The deployed
#      `beekeepingit-mark-email-verified` expression policy — the ONE writer of
#      `known_emails` — is evaluated for real and asserted to append, dedupe,
#      normalize and bound the list, and to write nothing at all without the
#      restored-flow-token proof.
#
# HONEST SCOPE LIMITS.
#   * `get_action()` resolves a connection and never touches the `User` row, so
#     "upn unchanged" proves the flow-manager path is non-mutating, NOT that a
#     full federated login leaves `upn` alone. The only thing that could rewrite
#     it is a `user_write` stage inside the authentication flow, and
#     `default-source-authentication` has none; if one is ever bound there, this
#     probe would NOT catch it.
#   * Action.LINK returns an UNSAVED connection. Persisting it is
#     `PostSourceStage`'s job, inside the flow this probe does not execute — so
#     "the link is remembered next time" is proven by construction (upstream
#     code), not by this probe.
#   * Nothing here completes a real upstream token exchange. The browser e2e
#     (client/e2e/tests/federation.spec.ts) covers the outbound half and the
#     posture guard (scripts/check-federation-source-posture.sh) pins the
#     config. Together they are the coverage; none of the three alone is.
#
# WHY EVERYTHING LIVES INSIDE ONE FUNCTION. `ak shell -c` `exec()`s this whole
# file. At authentik 2026.5.4 (django==5.2.15) Django's shell command runs
# `exec(command, {**globals(), **namespace})` — ONE dict, so globals is locals
# and top-level names would resolve fine from inside a `def`. But Django ≤4.2
# used a bare `exec(command)`, where globals and locals are DIFFERENT dicts:
# top-level assignments land in locals while every `def`'s `__globals__` points
# at the other dict, so a helper called from inside a function raises
# `NameError`. Nesting everything in `_run()` makes name resolution pure
# lexical closure, which behaves identically under both forms — so a Django
# bump in an authentik upgrade cannot silently turn this probe into an
# immediate crash. (Raised as a blocking review finding; verified not to apply
# at the pinned version, fixed anyway because the cost is zero.)
#
# Pinned to authentik 2026.5.4. Upstream idiom mirrored:
# `authentik/core/tests/test_source_flow_manager.py` (`test_unauthenticated_enroll`,
# `test_unauthenticated_auth`). `SourceFlowManager.__init__` is positional
# `(source, request, identifier, user_info, policy_context)`; `get_action()`
# takes no arguments and returns `(Action, UserSourceConnection | None)`.
import sys


def _run():
    """Returns the list of failed assertion labels (empty == pass)."""
    import contextlib

    from django.contrib.auth.models import AnonymousUser

    from authentik.core.models import User, UserSourceConnection
    from authentik.core.sources.flow_manager import Action
    from authentik.policies.expression.models import ExpressionPolicy
    from authentik.policies.types import PolicyRequest
    from authentik.sources.oauth.models import OAuthSource, UserOAuthSourceConnection
    from authentik.sources.oauth.views.callback import OAuthSourceFlowManager

    source_slug = "federation-stub"
    resolver_mapping_name = "BeekeepingIT Source Mapping: federated account resolution"
    stamp_policy_name = "beekeepingit-mark-email-verified"
    seed_email = "test.beekeeper@beekeepingit.local"
    # Pinned in the blueprint's seed user; sub_mode=user_upn makes it the `sub`.
    expected_upn = "11111111-1111-4111-8111-111111111111"
    known_ident = "ci-probe-known-sub-0001"

    # Every row this probe creates carries this prefix, so a crashed previous
    # run is swept before a new one starts and nothing leaks into the specs
    # that share this cluster.
    prefix = "ci-probe-364-"
    addr_current = prefix + "current@example.invalid"
    addr_former = prefix + "former@example.invalid"
    addr_unverified = prefix + "unverified@example.invalid"
    addr_duplicate = prefix + "duplicate@example.invalid"
    addr_superuser = prefix + "superuser@example.invalid"
    addr_nobody = prefix + "nobody@example.invalid"

    failures = []

    def check(label, ok, detail=""):
        if ok:
            print("OK: {}".format(label))
        else:
            suffix = " -- {}".format(detail) if detail else ""
            print("FAIL: {}{}".format(label, suffix))
            failures.append(label)
        return ok

    # Prefer authentik's own test helper: it sets `request.user` and applies the
    # Session + Message middleware the flow manager needs. Fall back to an
    # equivalent if `authentik/core/tests/` is stripped from the runtime image.
    try:
        from authentik.core.tests.utils import RequestFactory

        print("info: using authentik.core.tests.utils.RequestFactory")
    except ImportError:
        from django.contrib.messages.middleware import MessageMiddleware
        from django.contrib.sessions.middleware import SessionMiddleware
        from django.test import RequestFactory as _BaseRequestFactory

        def _dummy_get_response(request):
            return None

        class RequestFactory(_BaseRequestFactory):
            def generic(
                self,
                method,
                path,
                data="",
                content_type="application/octet-stream",
                secure=False,
                *,
                headers=None,
                query_params=None,
                **extra,
            ):
                user = extra.pop("user", None)
                request = super().generic(
                    method,
                    path,
                    data,
                    content_type,
                    secure,
                    headers=headers,
                    query_params=query_params,
                    **extra,
                )
                request.user = user if user else AnonymousUser()
                mw = SessionMiddleware(_dummy_get_response)
                mw.process_request(request)
                request.session.save()
                mw = MessageMiddleware(_dummy_get_response)
                mw.process_request(request)
                request.session.save()
                return request

        print("info: using inline RequestFactory fallback")

    class StubPlan:
        """Minimal stand-in for a FlowPlan.

        The stamp policy only ever reads/writes `flow_plan.context`, so this is
        the whole contract. Deliberately NOT the real `FlowPlan`: constructing
        one couples this probe to a dataclass signature that says nothing about
        the behaviour under test, and the real plan is already exercised
        end-to-end by client/e2e/tests/verification.spec.ts.
        """

        def __init__(self):
            self.context = {}

    class StubRestoreToken:
        """Stand-in for the FlowToken the executor restores the plan from.

        The policy only compares `.user`; the token/user match itself is
        authentik's own check inside the email stage (auth.md §8.10).
        """

        def __init__(self, user):
            self.user = user

    def sweep():
        UserOAuthSourceConnection.objects.filter(identifier__startswith=prefix).delete()
        User.objects.filter(username__startswith=prefix).delete()

    def make_user(suffix, email, verified=True, history=None, superuser=False):
        return User.objects.create(
            username=prefix + suffix,
            name="CI Probe " + suffix,
            email=email,
            is_active=True,
            is_superuser=superuser,
            attributes={
                # Not a UUID on purpose: these rows are transient and never
                # mint a token, so an obviously-probe-shaped value is more
                # useful than a plausible `sub` if one ever leaks past the sweep.
                "upn": prefix + "upn-" + suffix,
                "email_verified": verified,
                "known_emails": list(history) if history else [],
            },
        )

    def resolve(rf, identifier, payload):
        """Run the REAL flow manager (hence the real resolver mapping)."""
        sfm = OAuthSourceFlowManager(
            OAuthSource.objects.get(slug=source_slug),
            rf.get("/", user=AnonymousUser()),
            identifier,
            {"info": payload},
            {},
        )
        return sfm.get_action()

    def upstream(email, verified_key="email_verified", verified_value=True, username=None):
        """An upstream userinfo payload.

        `username` defaults to an attacker-flavoured value on purpose: the
        stand-in source type maps `preferred_username` into the `username`
        property, so every assertion below also proves the resolver OVERRODE
        whatever the upstream asserted rather than letting it choose an account.
        """
        payload = {
            "sub": "irrelevant",
            "email": email,
            "name": "CI Probe",
            "preferred_username": username or (prefix + "upstream-asserted"),
        }
        if verified_key is not None:
            payload[verified_key] = verified_value
        return payload

    def probe():
        rf = RequestFactory()

        # ---------- the configured posture, read back from the DB ----------
        # scripts/check-federation-source-posture.sh pins these in the
        # blueprint SOURCE; this pins that the blueprint actually APPLIED (an
        # entry skipped by a mis-set condition would otherwise pass the source
        # guard silently).
        try:
            source = OAuthSource.objects.get(slug=source_slug)
        except OAuthSource.DoesNotExist:
            check("source '{}' exists".format(source_slug), False, "not found")
            return
        check("source '{}' exists".format(source_slug), True)
        check(
            "provider_type == openidconnect",
            source.provider_type == "openidconnect",
            "got {!r}".format(source.provider_type),
        )
        check(
            "user_matching_mode == username_link (#364 resolver steers the match)",
            source.user_matching_mode == "username_link",
            "got {!r}".format(source.user_matching_mode),
        )
        mapping_names = sorted(m.name for m in source.user_property_mappings.all())
        check(
            "the #364 account resolver is the source's ONLY user property mapping",
            mapping_names == [resolver_mapping_name],
            "got {!r}".format(mapping_names),
        )
        check(
            "enrollment_flow is NULL (invitation-only still applies)",
            source.enrollment_flow_id is None,
            "got {!r}".format(source.enrollment_flow_id),
        )
        check("authentication_flow is set", source.authentication_flow_id is not None)
        check("source is enabled", source.enabled is True)

        # ---------- fixtures ----------
        users_before = User.objects.count()
        conns_before = UserSourceConnection.objects.count()

        # The account a returning user must reach. Its CURRENT address differs
        # from the historic one, so cases 2 and 3 are genuinely different paths.
        make_user("current", addr_current, history=[addr_former])
        # Registered at an address but never proved inbox control (#366 allows
        # this, and allows it at someone else's address).
        make_user("unverified", addr_unverified, verified=False)
        # Two accounts, one address — this deployment allows that by design.
        make_user("dupe-a", addr_duplicate)
        make_user("dupe-b", addr_duplicate)
        # Blast-radius guard: ops accounts link deliberately, never inbound.
        make_user("superuser", addr_superuser, superuser=True)

        current_user = User.objects.get(username=prefix + "current")

        # ---------- the linking decisions ----------
        cases = [
            (
                "AC4 verified upstream email == an account's CURRENT address -> LINK to it",
                upstream(addr_current),
                Action.LINK,
                current_user.pk,
            ),
            (
                "AC2/AC5 verified upstream email found only in known_emails -> LINK to the same account",
                upstream(addr_former),
                Action.LINK,
                current_user.pk,
            ),
            (
                "AC3 upstream says email_verified: false -> DENY (the #170 shape refused)",
                upstream(addr_current, verified_value=False),
                Action.DENY,
                None,
            ),
            (
                "AC3 upstream says email_verified: 'true' (a string) -> DENY (strict boolean)",
                upstream(addr_current, verified_value="true"),
                Action.DENY,
                None,
            ),
            (
                "AC3 upstream sends NO verification flag at all -> DENY",
                upstream(addr_current, verified_key=None),
                Action.DENY,
                None,
            ),
            (
                "Google's flag spelling (verified_email) is honoured -> LINK",
                upstream(addr_current, verified_key="verified_email"),
                Action.LINK,
                current_user.pk,
            ),
            (
                "two accounts share the verified address -> DENY (never guess)",
                upstream(addr_duplicate),
                Action.DENY,
                None,
            ),
            (
                "the matched account never proved inbox control itself -> DENY (#361 holds)",
                upstream(addr_unverified),
                Action.DENY,
                None,
            ),
            (
                "the matched account is a superuser -> DENY (blast-radius guard)",
                upstream(addr_superuser),
                Action.DENY,
                None,
            ),
            (
                "verified address nobody holds -> DENY (no account is ever created)",
                upstream(addr_nobody),
                Action.DENY,
                None,
            ),
            # The adversarial case `username_link` looks like it should be
            # vulnerable to: the upstream asserts a REAL local username. The
            # stand-in source type maps `preferred_username` -> the `username`
            # property, so without the resolver this would link straight to
            # that account off an unverified email. The resolver clears it.
            (
                "upstream asserts a real local username with an unverified email -> DENY",
                upstream(
                    addr_nobody,
                    verified_value=False,
                    username=prefix + "current",
                ),
                Action.DENY,
                None,
            ),
            (
                "upstream asserts a real local username with a verified but UNKNOWN email -> DENY",
                upstream(addr_nobody, username=prefix + "current"),
                Action.DENY,
                None,
            ),
        ]
        for index, (label, payload, expected_action, expected_user) in enumerate(cases):
            action, connection = resolve(rf, "{}unlinked-{}".format(prefix, index), payload)
            if not check(label, action == expected_action, "got {!r}".format(action)):
                continue
            if expected_user is None:
                continue
            check(
                label + " [resolved to the expected account]",
                connection is not None and getattr(connection, "user_id", None) == expected_user,
                "got {!r}".format(getattr(connection, "user_id", None)),
            )

        check(
            "no User row created by any resolution",
            User.objects.count() == users_before + 5,
            "{} -> {} (expected +5 fixtures only)".format(users_before, User.objects.count()),
        )
        check(
            "no UserSourceConnection row created by any resolution",
            UserSourceConnection.objects.count() == conns_before,
            "{} -> {}".format(conns_before, UserSourceConnection.objects.count()),
        )

        # Enrollment stays closed at the code level too, not just by never
        # being reached: #363's proof, kept because #365 is what changes it.
        response = OAuthSourceFlowManager(
            source,
            rf.get("/", user=AnonymousUser()),
            prefix + "enroll-probe",
            {"info": upstream(addr_nobody)},
            {},
        ).handle_enroll(UserOAuthSourceConnection(source=source, identifier=prefix + "enroll-probe"))
        check(
            "handle_enroll() -> HTTP 400 (source is not configured for enrollment)",
            getattr(response, "status_code", None) == 400,
            "got {!r}".format(getattr(response, "status_code", None)),
        )

        # ---------- AC1: the SUBJECT decides, not the email -------------------
        seed = User.objects.filter(email=seed_email).first()
        if not check("seed user '{}' exists".format(seed_email), seed is not None):
            return

        upn_before = (seed.attributes or {}).get("upn")
        check(
            "seed user upn == expected before the probe",
            upn_before == expected_upn,
            "got {!r}".format(upn_before),
        )

        created_conn = None
        try:
            # unique_together = (("user", "source")) — reuse rather than
            # violate it, so a re-run (or a retried CI job) does not blow up.
            existing = UserOAuthSourceConnection.objects.filter(
                user=seed, source=source
            ).first()
            if existing:
                print("info: reusing pre-existing connection pk={}".format(existing.pk))
                conn_row = existing
                probe_ident = existing.identifier
            else:
                created_conn = UserOAuthSourceConnection.objects.create(
                    user=seed, source=source, identifier=known_ident
                )
                conn_row = created_conn
                probe_ident = known_ident

            # Deliberately a DIFFERENT, UNVERIFIED address: if the email had any
            # say, this would resolve elsewhere or be denied. It must not.
            action2, connection2 = resolve(
                rf,
                probe_ident,
                upstream(addr_nobody, verified_value=False),
            )
            check(
                "AC1 linked identity -> Action.AUTH on the SUBJECT alone",
                action2 == Action.AUTH,
                "got {!r}".format(action2),
            )
            check(
                "AC1 resolved connection is the seeded row",
                connection2 is not None and connection2.pk == conn_row.pk,
            )
            check(
                "AC1 resolved user is the seed user (a foreign, unverified email changed nothing)",
                connection2 is not None and connection2.user_id == seed.pk,
            )

            seed.refresh_from_db()
            upn_after = (seed.attributes or {}).get("upn")
            check(
                "D-7: seed user upn (the OIDC `sub`) UNCHANGED after AUTH resolution",
                upn_after == expected_upn,
                "before={!r} after={!r}".format(upn_before, upn_after),
            )
        finally:
            if created_conn is not None:
                created_conn.delete()
                print("info: cleaned up the probe connection")

        check(
            "cleanup: no probe connection left behind for the rest of the suite",
            not UserOAuthSourceConnection.objects.filter(
                source=source, identifier=known_ident
            ).exists(),
        )

        # ---------- AC2: the history is actually WRITTEN ----------------------
        # Drives the DEPLOYED stamp policy — the only writer of known_emails.
        try:
            stamp = ExpressionPolicy.objects.get(name=stamp_policy_name)
        except ExpressionPolicy.DoesNotExist:
            check("stamp policy '{}' exists".format(stamp_policy_name), False, "not found")
            return
        check("stamp policy '{}' exists".format(stamp_policy_name), True)

        def run_stamp(user, restored=True):
            plan = StubPlan()
            plan.context["pending_user"] = user
            if restored:
                plan.context["is_restored"] = StubRestoreToken(user)
            request = PolicyRequest(user)
            request.context["flow_plan"] = plan
            result = stamp.passes(request)
            return result, plan.context.get("prompt_data", {})

        # A fresh, unverified account at an address it has never proved.
        pending = make_user("stamp", prefix + "stamp@example.invalid", verified=False)
        result, prompt_data = run_stamp(pending)
        check(
            "stamp policy passes for an unverified pending user with the restore proof",
            result.passing is True,
            "messages={!r}".format(getattr(result, "messages", None)),
        )
        check(
            "stamp policy still writes attributes.email_verified (#361 unchanged)",
            prompt_data.get("attributes.email_verified") is True,
            "got {!r}".format(prompt_data.get("attributes.email_verified")),
        )
        check(
            "stamp policy records the just-proven address in known_emails (#364)",
            prompt_data.get("attributes.known_emails") == [prefix + "stamp@example.invalid"],
            "got {!r}".format(prompt_data.get("attributes.known_emails")),
        )

        # An account with prior history, at a NEW address, with a duplicate and
        # a mixed-case entry already stored.
        pending2 = make_user(
            "stamp2",
            prefix + "Stamp2-New@example.invalid",
            verified=False,
            history=[addr_former, addr_former.upper()],
        )
        _, prompt_data2 = run_stamp(pending2)
        check(
            "stamp policy appends, dedupes and lowercases the history",
            prompt_data2.get("attributes.known_emails")
            == [addr_former, prefix + "stamp2-new@example.invalid"],
            "got {!r}".format(prompt_data2.get("attributes.known_emails")),
        )

        # Without the restored-flow-token evidence nothing is written at all.
        pending3 = make_user("stamp3", prefix + "stamp3@example.invalid", verified=False)
        result3, prompt_data3 = run_stamp(pending3, restored=False)
        check(
            "no restore proof -> stamp policy refuses",
            result3.passing is not True,
        )
        check(
            "no restore proof -> nothing written (neither the flag nor the history)",
            prompt_data3 == {},
            "got {!r}".format(prompt_data3),
        )

    # Defensive: if this deployment ever runs authentik multi-tenant, pin the
    # probe to the public schema rather than whatever `ak shell` activated.
    ctx = contextlib.nullcontext()
    try:
        from django_tenants.utils import get_public_schema_name, schema_context

        ctx = schema_context(get_public_schema_name())
        print("info: pinned to schema '{}'".format(get_public_schema_name()))
    except Exception as exc:  # noqa: BLE001 - diagnostic only, never fatal
        print("info: no schema_context ({}), running as-is".format(exc))

    with ctx:
        # Sweep before AND after: a crashed earlier run must not make this one
        # fail for the wrong reason, and nothing may leak into the specs that
        # share this cluster.
        sweep()
        try:
            probe()
        finally:
            sweep()
            print("info: swept probe fixtures ({}*)".format(prefix))

    return failures


_failures = _run()
if _failures:
    print("PROBE FAILED: {} assertion(s): {}".format(len(_failures), ", ".join(_failures)))
    sys.stdout.flush()
    raise SystemExit(1)
print("PROBE OK")
sys.stdout.flush()
raise SystemExit(0)
