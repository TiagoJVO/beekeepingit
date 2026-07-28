# Federation-posture probe (#363, NFR-SEC-1, NFR-TST-1) — run inside the
# authentik worker: `ak shell -c "$(cat authentik-federation-probe.py)"`.
#
# WHY THIS EXISTS. A live end-to-end against real Google is not automatable
# (consent screen + bot detection) and must never run in CI, so the INBOUND
# half of federation — what authentik decides when an upstream identity comes
# back — cannot be proven through a browser. This drives the real
# `SourceFlowManager` against the dev/CI stand-in source (a generic
# `openidconnect` source configured with the IDENTICAL posture as the Google
# one: `user_matching_mode: identifier`, no `enrollment_flow`,
# `authentication_flow: default-source-authentication`) and asserts the two
# decisions that carry the security weight:
#
#   1. An UNKNOWN upstream identity is REFUSED — `Action.ENROLL` -> HTTP 400,
#      with no `User` and no `UserSourceConnection` row created. That is
#      "invitation-only account creation still applies" (#365 is what opens
#      it), proven against the real code path rather than asserted on paper.
#   2. A LINKED identity resolves to the EXISTING local user — `Action.AUTH`,
#      same user, same `attributes.upn`. `upn` is what the provider emits as
#      the OIDC `sub` (`sub_mode: user_upn`), so this is D-7's boundary: a
#      federated sign-in produces the same subject the password path does, and
#      the domain services need no change.
#
# HONEST SCOPE LIMIT. `get_action()` resolves a connection and does not touch
# the `User` row at all, so assertion 2's "upn unchanged" is close to
# tautological here — it proves the flow-manager path is non-mutating, NOT that
# a full federated login leaves `upn` alone. The only thing that could rewrite
# it is a `user_write` stage inside the authentication flow, and
# `default-source-authentication` has none; if one is ever bound there, this
# probe would NOT catch it. The browser e2e
# (client/e2e/tests/federation.spec.ts) covers the outbound half, and the
# posture guard (scripts/check-federation-source-posture.sh) pins the config.
# Together they are the coverage; none of the three alone is.
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
    from authentik.sources.oauth.models import OAuthSource, UserOAuthSourceConnection
    from authentik.sources.oauth.views.callback import OAuthSourceFlowManager

    source_slug = "federation-stub"
    seed_email = "test.beekeeper@beekeepingit.local"
    # Pinned in the blueprint's seed user; sub_mode=user_upn makes it the `sub`.
    expected_upn = "11111111-1111-4111-8111-111111111111"
    unknown_ident = "ci-probe-unknown-sub-0001"
    known_ident = "ci-probe-known-sub-0001"
    unknown_email = "ci-probe-nobody@example.invalid"

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
            "user_matching_mode == identifier (keys on the upstream SUBJECT)",
            source.user_matching_mode == "identifier",
            "got {!r}".format(source.user_matching_mode),
        )
        check(
            "enrollment_flow is NULL (invitation-only still applies)",
            source.enrollment_flow_id is None,
            "got {!r}".format(source.enrollment_flow_id),
        )
        check("authentication_flow is set", source.authentication_flow_id is not None)
        check("source is enabled", source.enabled is True)

        # ---------- 1. unknown identity -> ENROLL -> 400, nothing created ----
        users_before = User.objects.count()
        conns_before = UserSourceConnection.objects.count()

        # AnonymousUser(), NOT guardian's get_anonymous_user(): get_action
        # branches on request.user.is_authenticated first, and guardian's
        # anonymous user is a real DB row that would yield LINK instead of the
        # unauthenticated path this must exercise.
        sfm = OAuthSourceFlowManager(
            source,
            rf.get("/", user=AnonymousUser()),
            unknown_ident,
            {
                "info": {
                    "sub": unknown_ident,
                    "email": unknown_email,
                    "preferred_username": "ci-probe-nobody",
                    "name": "CI Probe",
                }
            },
            {},
        )
        action, connection = sfm.get_action()
        check(
            "unknown identity -> Action.ENROLL",
            action == Action.ENROLL,
            "got {!r}".format(action),
        )

        if action == Action.ENROLL:
            response = sfm.handle_enroll(connection)
            check(
                "handle_enroll() -> HTTP 400 (source not configured for enrollment)",
                getattr(response, "status_code", None) == 400,
                "got {!r}".format(getattr(response, "status_code", None)),
            )

        check(
            "no User row created",
            User.objects.count() == users_before,
            "{} -> {}".format(users_before, User.objects.count()),
        )
        check(
            "no User with the probe email",
            not User.objects.filter(email=unknown_email).exists(),
        )
        check(
            "no UserSourceConnection row created",
            UserSourceConnection.objects.count() == conns_before,
            "{} -> {}".format(conns_before, UserSourceConnection.objects.count()),
        )
        check(
            "no connection for the unknown identifier",
            not UserSourceConnection.objects.filter(
                source=source, identifier=unknown_ident
            ).exists(),
        )

        # ---------- 2. existing link -> AUTH, seed user, upn untouched -------
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

            sfm2 = OAuthSourceFlowManager(
                source,
                rf.get("/", user=AnonymousUser()),
                probe_ident,
                {
                    "info": {
                        "sub": probe_ident,
                        "email": seed_email,
                        "preferred_username": "test.beekeeper",
                        "name": "Test Beekeeper",
                    }
                },
                {},
            )
            action2, connection2 = sfm2.get_action()
            check(
                "linked identity -> Action.AUTH",
                action2 == Action.AUTH,
                "got {!r}".format(action2),
            )
            check(
                "resolved connection is the seeded row",
                connection2 is not None and connection2.pk == conn_row.pk,
            )
            check(
                "resolved user is the seed user (no new account)",
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
        probe()

    return failures


_failures = _run()
if _failures:
    print("PROBE FAILED: {} assertion(s): {}".format(len(_failures), ", ".join(_failures)))
    sys.stdout.flush()
    raise SystemExit(1)
print("PROBE OK")
sys.stdout.flush()
raise SystemExit(0)
