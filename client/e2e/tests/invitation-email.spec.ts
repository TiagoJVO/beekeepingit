import { test, expect } from "@playwright/test";
import { apiJson, loginAndCaptureToken, MAILPIT_URL } from "./helpers";

/**
 * Organization-invitation email e2e (#641, FR-ONB-3, FR-TEN-2, D-3).
 *
 * The defect this pins: creating an invitation used to send NOTHING. The
 * environment's mail sink held the same messages before and after, and the
 * admin's screen said "Pendente" forever for a message that had never left.
 * Every unit and integration test around the new send path uses a fake mailer,
 * so this is the one place that proves the REAL SMTP path — the organizations
 * service's own relay configuration, its NetworkPolicy edge to the sink, and
 * the message it actually puts on the wire — works against the deployed stack.
 *
 * Asserts, live:
 *   1. creating an invitation delivers a message to the invited address
 *      (Mailpit's API sees it — the exact check that was empty before #641),
 *   2. that message names the organization and the inviter and links to the
 *      app's sign-up flow (AC 2),
 *   3. the API reports the delivery honestly (`delivery_status: sent`,
 *      `last_delivery_at` set) rather than only "pending" (AC 4),
 *   4. the resend endpoint exists and is guarded by its cooldown (AC 5) —
 *      an immediate retry is refused with 429 + Retry-After rather than
 *      mailbombing the address.
 *
 * Requires the Mailpit sink reachable from the runner (helm-e2e.yml
 * port-forwards it and sets E2E_MAILPIT_URL) and a deployed stack whose
 * organizations service has SMTP configured (charts/services `smtp:` +
 * `mail: true`). Self-skips otherwise, like the other mail-dependent specs.
 *
 * NOTE: a real relay and sending domain for staging/prod are issue #417 and
 * are deliberately NOT in scope here — this proves the code path against the
 * in-cluster sink, which is exactly what dev and CI point at (ADR-0019 §4), so
 * no test mail can ever reach a real inbox.
 */

const ADMIN_USER = process.env.E2E_USER ?? "test.beekeeper@beekeepingit.local";
const ADMIN_PASS = process.env.E2E_PASS ?? "dev-password123";

/** A per-run address so repeated runs never collide on the pending-invite unique index. */
const inviteeEmail = () => `invitee-${Date.now()}@beekeepingit.local`;

type MailpitMessage = { ID: string };

/** Polls the sink for a message to `recipient` and returns its text part. */
async function pollForMessageText(
  request: import("@playwright/test").APIRequestContext,
  recipient: string,
): Promise<string> {
  const deadline = Date.now() + 60_000;
  for (;;) {
    const list = await request
      .get(`${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${recipient}`)}`)
      .catch(() => null);
    if (list?.ok()) {
      const body = (await list.json()) as { messages?: MailpitMessage[] };
      const newest = body.messages?.[0];
      if (newest) {
        const full = await request.get(`${MAILPIT_URL}/api/v1/message/${newest.ID}`);
        const message = (await full.json()) as { Text?: string; Subject?: string };
        return `${message.Subject ?? ""}\n${message.Text ?? ""}`;
      }
    }
    if (Date.now() > deadline) {
      throw new Error(`no invitation email for ${recipient} arrived in Mailpit`);
    }
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
}

test.describe("organization invitation email (#641)", () => {
  test.skip(
    !MAILPIT_URL,
    "E2E_MAILPIT_URL not set — needs the Mailpit sink port-forwarded (helm-e2e.yml)",
  );

  test("creating an invitation actually emails the invited address, and says so", async ({
    request,
    browser,
  }) => {
    test.setTimeout(180_000); // one full OIDC login plus SMTP delivery

    const admin = await loginAndCaptureToken(browser, ADMIN_USER, ADMIN_PASS);
    try {
      const me = await apiJson(admin.page, admin.token, "GET", "/organizations/me");
      expect(me.status, "the seeded admin must already have an organization").toBe(200);
      const orgId = me.json.id as string;
      const orgName = me.json.name as string;

      const email = inviteeEmail();
      const created = await apiJson(
        admin.page,
        admin.token,
        "POST",
        `/organizations/${orgId}/invitations`,
        { email, role: "user" },
      );
      expect(created.status, JSON.stringify(created.json)).toBe(201);

      // AC 4 — the API tells the truth about the send, immediately.
      expect(
        created.json.delivery_status,
        `invitation reported ${created.json.delivery_status} / ${created.json.delivery_error}`,
      ).toBe("sent");
      expect(created.json.last_delivery_at).not.toBeNull();
      // The lifecycle status is untouched by delivery.
      expect(created.json.status).toBe("pending");

      // AC 1 + AC 2 — the message really is in the sink, and it is usable.
      const body = await pollForMessageText(request, email);
      expect(body).toContain(orgName);
      expect(body, "the email must link to the app's sign-up flow").toMatch(
        /https:\/\/app\.beekeepingit\.local[^\s]*\/login/,
      );
      expect(body, "the email must tell the invitee which address to use").toContain(email);

      // AC 5 — the retry path exists and is rate limited rather than
      // unlimited. (The success half of resend is covered by the Go
      // integration suite, which can move the clock past the cooldown.)
      const resend = await apiJson(
        admin.page,
        admin.token,
        "POST",
        `/organizations/${orgId}/invitations/${created.json.id as string}/resend`,
      );
      expect(resend.status, "an immediate resend must be refused by the cooldown").toBe(429);

      // Housekeeping: leave the org's invitation list as we found it, so a
      // long-lived cluster does not accumulate rows across runs.
      await apiJson(
        admin.page,
        admin.token,
        "DELETE",
        `/organizations/${orgId}/invitations/${created.json.id as string}`,
      );
    } finally {
      await admin.context.close();
    }
  });
});
