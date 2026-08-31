# Federation-posture + account-linking + enrollment probe (#363, #364, #365,
# NFR-SEC-1, NFR-TST-1) — run inside the authentik worker:
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
# resolver attached, `enrollment_flow: beekeepingit-source-enrollment` (#365),
# `authentication_flow: default-source-authentication`.
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
#   5. AMBIGUITY, SQUATTING AND PRIVILEGE ALL FAIL CLOSED. Two accounts sharing
#      the address, an account that never proved inbox control itself, and a
#      superuser are each DENIED with no rows created. An UNVERIFIED unknown
#      identity is denied too — the only path that ENROLLS is #365's: a
#      strictly-verified upstream address that matches no local account.
#   6. THE HISTORY IS ACTUALLY WRITTEN. The deployed
#      `beekeepingit-mark-email-verified` expression policy — the ONE writer of
#      `known_emails` — is evaluated for real and asserted to append, dedupe,
#      normalize and bound the list, and to write nothing at all without the
#      restored-flow-token proof.
#
#   7. THE LINK IS PERSISTED. One sign-in is driven to the END through the real
#      `FlowExecutorView`, then the DATABASE is read: the connection row exists
#      and points at the matched account (so the next sign-in matches by
#      subject), no second account was created, and a COMPLETED federated login
#      left `attributes.upn` and the local `email` untouched.
#
#   8. ENROLLMENT IS OPEN, WELL-FORMED AND SUBJECT-KEYED (#365). A verified
#      unknown identity resolves to Action.ENROLL with a resolver-GENERATED
#      username — never the upstream-asserted one, and colliding with no local
#      account (a collision would silently LINK, i.e. account takeover). One
#      enrollment is driven END TO END through the real `FlowExecutorView`:
#      exactly one account is created, active, non-privileged, carrying a
#      fresh `attributes.upn` (the future OIDC `sub`) and
#      `attributes.email_verified: true` from the upstream's strict boolean —
#      and NOT seeding `attributes.known_emails`, whose single writer stays
#      the #361 stamp policy. The connection row is persisted, and a second
#      sign-in with the same subject resolves to Action.AUTH on the stored
#      subject even when the upstream address has changed and is unverified.
#      The enrollment flow's WRITE GUARD is then evaluated directly against
#      the plan shapes the resolver would never author (missing upn, a string
#      "true", no prompt_data, ...) — the real flow cannot produce them, and
#      an ungated `user_write` is exactly what they exist to stop.
#
# WHY THE POSITIVE CASES ARE LOAD-BEARING, NOT DECORATION. The resolver's whole
# body runs inside a blanket `except: return {"username": None}`, and
# `username_link` with no username DENIES. So ANY error in the resolver — an
# exception, a bad query, a rename — looks exactly like a correct refusal from
# the outside, and every negative assertion here still passes. Cases 2, 3 and 7
# are the only things that tell a working resolver from a broken one. That is
# not hypothetical: this probe once crashed before reaching them (it built a
# fixture with `User(is_superuser=...)`, which is a read-only PROPERTY on
# authentik's model, not a field), and behind that crash the resolver was
# filtering on the same non-existent column and denying every single login.
#
# HONEST SCOPE LIMITS.
#   * Nothing here completes a real upstream token exchange — `info` is
#     fabricated at the point the OAuth callback would have returned it, so
#     Google's actual userinfo SHAPE (in particular that `verified_email` is
#     present and boolean) is covered only by the manual checklist in
#     infra/README.md. The browser e2e
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

    from authentik.core.models import Group, User, UserSourceConnection
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
        # #365-enrolled accounts carry a resolver-GENERATED username, not the
        # probe prefix — but their email is probe-prefixed, so sweep on that too.
        User.objects.filter(email__startswith=prefix).delete()
        Group.objects.filter(name__startswith=prefix).delete()

    def make_user(suffix, email, verified=True, history=None, superuser=False):
        user = User.objects.create(
            username=prefix + suffix,
            name="CI Probe " + suffix,
            email=email,
            is_active=True,
            attributes={
                # Not a UUID on purpose: these rows are transient and never
                # mint a token, so an obviously-probe-shaped value is more
                # useful than a plausible `sub` if one ever leaks past the sweep.
                "upn": prefix + "upn-" + suffix,
                "email_verified": verified,
                "known_emails": list(history) if history else [],
            },
        )
        if superuser:
            # `User.is_superuser` is a read-only PROPERTY on authentik's model —
            # `all_groups().filter(is_superuser=True).exists()`; the column is on
            # Group. Passing it to `User.objects.create()` raises TypeError, which
            # is exactly how this probe used to die: at THIS line, after only the
            # posture assertions, so every #364 linking proof below silently never
            # ran — and the resolver bug they exist to catch shipped unnoticed.
            # Granting it the way authentik actually models it also means the
            # assertion covers superuser inherited through a parent group.
            group = Group.objects.create(name=prefix + "superusers-" + suffix, is_superuser=True)
            group.users.add(user)
        return user

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
        enrollment_flow = source.enrollment_flow
        check(
            "enrollment_flow is the dedicated source-enrollment flow (#365)",
            enrollment_flow is not None
            and enrollment_flow.slug == "beekeepingit-source-enrollment",
            "got {!r}".format(getattr(enrollment_flow, "slug", None)),
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
                "#365 verified address nobody holds -> ENROLL (self-service registration)",
                upstream(addr_nobody),
                Action.ENROLL,
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
            # #365 flips this case from DENY to ENROLL — but the takeover it
            # aims at must still be impossible: the resolver must have REPLACED
            # the upstream-asserted username with a generated one, which the
            # dedicated property assertions right after this loop prove.
            (
                "#365 upstream asserts a real local username with a verified UNKNOWN email -> ENROLL, never LINK",
                upstream(addr_nobody, username=prefix + "current"),
                Action.ENROLL,
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

        # ---------- #365: what the resolver hands an ENROLLMENT ----------
        # Action.ENROLL alone is not enough — the properties the enrollment
        # flow will WRITE must be resolver-authored, not upstream-authored.
        # The takeover shape to refuse: a generated username that happens to
        # (or is crafted to) match an existing account would make the matcher
        # LINK instead of ENROLL, handing the upstream that account.
        enroll_sfm = OAuthSourceFlowManager(
            source,
            rf.get("/", user=AnonymousUser()),
            prefix + "enroll-props",
            {"info": upstream(addr_nobody, username=prefix + "current")},
            {},
        )
        enroll_action, _ = enroll_sfm.get_action()
        if check(
            "#365 enroll properties: action is ENROLL",
            enroll_action == Action.ENROLL,
            "got {!r}".format(enroll_action),
        ):
            props = enroll_sfm.user_properties
            generated = props.get("username")
            check(
                "#365 enroll properties: username is resolver-GENERATED, never the upstream's",
                isinstance(generated, str)
                and generated.startswith("federated-")
                and generated != prefix + "current",
                "got {!r}".format(generated),
            )
            check(
                "#365 enroll properties: generated username collides with NO local account",
                isinstance(generated, str)
                and not User.objects.filter(username__exact=generated).exists(),
            )
            enroll_attrs = props.get("attributes") or {}
            check(
                "#365 enroll properties: attributes.upn assigned (the future OIDC `sub`)",
                isinstance(enroll_attrs.get("upn"), str) and enroll_attrs.get("upn") != "",
                "got {!r}".format(enroll_attrs.get("upn")),
            )
            check(
                "#365 enroll properties: attributes.email_verified stamped strictly True",
                enroll_attrs.get("email_verified") is True,
                "got {!r}".format(enroll_attrs.get("email_verified")),
            )
            check(
                "#365 enroll properties: email is the normalized upstream address",
                props.get("email") == addr_nobody,
                "got {!r}".format(props.get("email")),
            )
            check(
                "#365 enroll properties: known_emails NOT seeded (single writer stays #361's stamp policy)",
                "known_emails" not in enroll_attrs,
                "got {!r}".format(enroll_attrs.get("known_emails")),
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

        # ---------- AC3: the link is actually PERSISTED -----------------------
        # Everything above stops at `get_action()`, which returns an UNSAVED
        # connection — so "resolves to the right account" was proven, but "and
        # is still linked next time" was not: persisting is `PostSourceStage`'s
        # job, and that runs inside the flow, which `get_action()` never enters.
        # This drives the REAL `FlowExecutorView` to the end of a federated
        # sign-in and then reads the database, closing the one gap this probe
        # used to name as a scope limit.
        #
        # The executor is invoked as a VIEW over a shared in-memory session
        # rather than over HTTP on purpose: a `django.test.Client` carrying the
        # session key as a cookie does not resolve it here, and the executor
        # then silently PLANS A FRESH FLOW with an empty context — which looks
        # identical to a legitimate refusal while testing nothing at all.
        import re
        from importlib import import_module

        from django.conf import settings

        from authentik.flows.views.executor import FlowExecutorView

        def complete_flow(identifier, payload):
            """Plan a federated sign-in and drive the REAL FlowExecutorView.

            Returns (planned, executed): `planned` is get_flow()'s response,
            `executed` is the final executor response, or None when no flow was
            ever entered. Exhausting the hop cap leaves `executed` a redirect,
            which callers must treat as FAILURE: an unfinished flow leaves the
            database in exactly the state a correct refusal does, so any DB
            assertion after it would report OK having exercised nothing.
            """
            session = import_module(settings.SESSION_ENGINE).SessionStore()
            session.save()
            planning_request = rf.get("/", user=AnonymousUser())
            planning_request.session = session
            planned = OAuthSourceFlowManager(
                source,
                planning_request,
                identifier,
                {"info": payload},
                {},
            ).get_flow()
            session.save()

            matched_slug = re.search(r"/if/flow/([^/?]+)/", getattr(planned, "url", "") or "")
            if matched_slug is None:
                return planned, None
            slug = matched_slug.group(1)
            path = "/api/v3/flows/executor/{}/?query=".format(slug)
            view = FlowExecutorView.as_view()
            executed = None
            for _hop in range(12):
                hop_request = rf.get(path, user=AnonymousUser())
                hop_request.session = session
                executed = view(hop_request, flow_slug=slug)
                if getattr(executed, "status_code", None) not in (301, 302):
                    break
                path = executed["Location"]
            return planned, executed

        persist_user = make_user("persist", prefix + "persist@example.invalid")
        persist_ident = prefix + "sub-persist"
        persist_upn = (persist_user.attributes or {}).get("upn")
        users_before = User.objects.count()

        planned, executed = complete_flow(persist_ident, upstream(persist_user.email))
        if check(
            "a verified first link enters a flow (302 to the executor)",
            executed is not None,
            "get_flow returned {!r}".format(getattr(planned, "url", planned)),
        ):
            check(
                "the federated sign-in flow ran to completion (not still redirecting)",
                getattr(executed, "status_code", None) not in (301, 302),
                "still redirecting after the hop cap",
            )

        persisted = UserOAuthSourceConnection.objects.filter(
            source=source, identifier=persist_ident
        ).first()
        check(
            "the connection row is PERSISTED, so the next sign-in matches by subject",
            persisted is not None and persisted.user_id == persist_user.pk,
            "got {!r}".format(persisted),
        )
        check(
            "completing the flow created no second account",
            User.objects.count() == users_before,
            "{} -> {}".format(users_before, User.objects.count()),
        )
        persist_user.refresh_from_db()
        check(
            "D-7: a COMPLETED federated login leaves attributes.upn untouched",
            (persist_user.attributes or {}).get("upn") == persist_upn,
            "before={!r} after={!r}".format(
                persist_upn, (persist_user.attributes or {}).get("upn")
            ),
        )
        check(
            "a COMPLETED federated login leaves the local email untouched",
            persist_user.email == prefix + "persist@example.invalid",
            "got {!r}".format(persist_user.email),
        )

        # ---------- #365: enrollment is actually EXECUTED, and well-formed ----
        # Everything above stops at get_action()'s ENROLL verdict. This drives
        # one enrollment END TO END through the real FlowExecutorView — the
        # source-enrollment flow's user_write is what creates the account — and
        # then reads the database.
        enroll_ident = prefix + "sub-enroll"
        enroll_addr = prefix + "enroll@example.invalid"
        users_before_enroll = User.objects.count()

        planned, executed = complete_flow(enroll_ident, upstream(enroll_addr))
        if check(
            "#365 a verified unknown identity enters the source-enrollment flow",
            executed is not None,
            "get_flow returned {!r}".format(getattr(planned, "url", planned)),
        ):
            check(
                "#365 the enrollment flow ran to completion (not still redirecting)",
                getattr(executed, "status_code", None) not in (301, 302),
                "still redirecting after the hop cap",
            )

        enrolled = User.objects.filter(email=enroll_addr).first()
        check(
            "#365 exactly ONE account was created by the enrollment",
            enrolled is not None and User.objects.count() == users_before_enroll + 1,
            "{} -> {} (user found: {})".format(
                users_before_enroll, User.objects.count(), enrolled is not None
            ),
        )
        if enrolled is not None:
            enrolled_attrs = enrolled.attributes or {}
            check(
                "#365 enrolled account: username is resolver-generated",
                enrolled.username.startswith("federated-"),
                "got {!r}".format(enrolled.username),
            )
            check(
                "#365 enrolled account: attributes.upn present (stable OIDC `sub`)",
                isinstance(enrolled_attrs.get("upn"), str) and enrolled_attrs.get("upn") != "",
                "got {!r}".format(enrolled_attrs.get("upn")),
            )
            check(
                "#365 enrolled account: attributes.email_verified is True",
                enrolled_attrs.get("email_verified") is True,
                "got {!r}".format(enrolled_attrs.get("email_verified")),
            )
            check(
                "#365 enrolled account: known_emails NOT seeded (#361 stamp policy stays the only writer)",
                not enrolled_attrs.get("known_emails"),
                "got {!r}".format(enrolled_attrs.get("known_emails")),
            )
            check(
                "#365 enrolled account: active",
                enrolled.is_active is True,
            )
            check(
                "#365 enrolled account: no group membership granted",
                enrolled.ak_groups.count() == 0,
                "got {!r}".format([g.name for g in enrolled.ak_groups.all()]),
            )
            check(
                "#365 enrolled account: not a superuser",
                enrolled.is_superuser is False,
            )
            enroll_conn = UserOAuthSourceConnection.objects.filter(
                source=source, identifier=enroll_ident
            ).first()
            check(
                "#365 the connection row is PERSISTED, keyed on the subject",
                enroll_conn is not None and enroll_conn.user_id == enrolled.pk,
                "got {!r}".format(enroll_conn),
            )
            # The second sign-in must resolve on the STORED SUBJECT — even with
            # a changed, unverified upstream address (the #364 invariant now
            # holding for a #365-enrolled account).
            action_again, connection_again = resolve(
                rf,
                enroll_ident,
                upstream(prefix + "changed@example.invalid", verified_value=False),
            )
            check(
                "#365 second sign-in -> Action.AUTH on the stored subject alone",
                action_again == Action.AUTH
                and connection_again is not None
                and connection_again.user_id == enrolled.pk,
                "got {!r} / {!r}".format(
                    action_again, getattr(connection_again, "user_id", None)
                ),
            )

        # ---------- #365 gate 2: the write guard, negative cases -------------
        # The enrollment above is the guard's happy path. The guard exists for
        # the plan shapes the resolver would never author, and those cannot be
        # produced by driving the real flow (the resolver always authors a good
        # payload when it enrolls) — so the DEPLOYED policy is evaluated
        # directly, the same way the #361 stamp policy is above. A guard that
        # passed these would let a non-resolver-shaped plan reach `user_write`.
        guard_policy_name = "beekeepingit-source-enrollment-write-guard"
        try:
            write_guard = ExpressionPolicy.objects.get(name=guard_policy_name)
        except ExpressionPolicy.DoesNotExist:
            check("write-guard policy '{}' exists".format(guard_policy_name), False, "not found")
            return
        check("write-guard policy '{}' exists".format(guard_policy_name), True)

        def run_guard(prompt_data, with_plan=True):
            request = PolicyRequest(AnonymousUser())
            if with_plan:
                plan = StubPlan()
                if prompt_data is not None:
                    plan.context["prompt_data"] = prompt_data
                request.context["flow_plan"] = plan
            return write_guard.passes(request).passing

        resolver_shaped = {
            "username": "federated-" + "0" * 32,
            "email": prefix + "guard@example.invalid",
            "attributes": {"upn": "a-upn", "email_verified": True},
        }
        check(
            "#365 write guard PASSES a resolver-shaped plan",
            run_guard(resolver_shaped) is True,
        )
        guard_cases = [
            ("no flow plan at all", None, False),
            ("no prompt_data in the plan", None, True),
            ("prompt_data is not a dict", "not-a-dict", True),
            ("empty username", dict(resolver_shaped, username=""), True),
            ("username is not a string", dict(resolver_shaped, username=123), True),
            ("email without an @", dict(resolver_shaped, email="nope"), True),
            ("no attributes", {k: v for k, v in resolver_shaped.items() if k != "attributes"}, True),
            (
                "email_verified is the STRING 'true'",
                dict(resolver_shaped, attributes={"upn": "a-upn", "email_verified": "true"}),
                True,
            ),
            (
                "email_verified is False",
                dict(resolver_shaped, attributes={"upn": "a-upn", "email_verified": False}),
                True,
            ),
            (
                "no upn assigned",
                dict(resolver_shaped, attributes={"email_verified": True}),
                True,
            ),
            (
                "empty upn",
                dict(resolver_shaped, attributes={"upn": "", "email_verified": True}),
                True,
            ),
        ]
        for label, prompt_data, with_plan in guard_cases:
            check(
                "#365 write guard REFUSES: {}".format(label),
                run_guard(prompt_data, with_plan=with_plan) is not True,
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
