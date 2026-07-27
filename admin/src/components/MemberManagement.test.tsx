import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import type { RenderResult } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { axe } from "jest-axe";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AuthContextProps } from "react-oidc-context";
import { MemberManagement } from "./MemberManagement";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import * as members from "../api/members";
import type { Member, MemberList } from "../api/members";

// The screen is only ever reached by an authenticated admin — mock the OIDC auth context.
const useAuthMock = vi.fn<() => Partial<AuthContextProps>>();
vi.mock("react-oidc-context", () => ({
  useAuth: () => useAuthMock(),
}));

const config: AppConfig = {
  oidcIssuer: "https://auth.example/o/bk/",
  oidcClientId: "beekeepingit-admin",
  oidcRedirectUri: "http://localhost:5174",
  apiBaseUrl: "https://app.example",
  accountUrl: "",
  quotasSeamEnabled: false,
};

const adminMember: Member = { user_id: "user-admin", role: "admin", status: "active" };
const plainMember: Member = { user_id: "user-bob", role: "user", status: "active" };

function page(data: Member[], nextCursor: string | null = null): MemberList {
  return { data, page: { next_cursor: nextCursor, limit: 50 } };
}

function authenticated(): Partial<AuthContextProps> {
  return {
    isLoading: false,
    isAuthenticated: true,
    user: {
      access_token: "tok",
      profile: { sub: "user-admin", name: "Ana Admin" },
    } as AuthContextProps["user"],
  };
}

function renderMembers(): RenderResult {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <MemberManagement config={config} orgId="org-1" />
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("MemberManagement — roster (NFR-ROL-2)", () => {
  it("renders the organization's members in an accessible table", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));

    renderMembers();

    const table = await screen.findByRole("table", { name: /current members/i });
    expect(within(table).getByText("user-admin")).toBeInTheDocument();
    expect(within(table).getByText("user-bob")).toBeInTheDocument();
    // Role + status are rendered as localized labels, not raw enum values. Ignore the per-row role
    // <option>s (which also read "Admin"/"Member") so we match the Role column cell only.
    expect(
      within(table).getByText(/^Admin$/, { ignore: "script, style, option" }),
    ).toBeInTheDocument();
    expect(within(table).getAllByText(/^Active$/)).toHaveLength(2);
  });

  it("loads the next page of members on demand (cursor pagination)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    const list = vi
      .spyOn(members, "listMembers")
      .mockResolvedValueOnce(page([adminMember], "cursor-2"))
      .mockResolvedValueOnce(page([plainMember], null));

    renderMembers();

    await screen.findByText("user-admin");
    // A "load more" affordance appears only because the first page reported a next_cursor.
    await userEvent.click(screen.getByRole("button", { name: /load more members/i }));

    expect(await screen.findByText("user-bob")).toBeInTheDocument();
    // The second call carried the cursor from the first page.
    expect(list).toHaveBeenNthCalledWith(2, expect.anything(), "org-1", "cursor-2");
  });
});

describe("MemberManagement — invite (FR-ONB-3, D-3)", () => {
  it("invites a member by email and sends the chosen role (NFR-ROL-1)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember]));
    const invite = vi
      .spyOn(members, "createInvitation")
      .mockResolvedValue({ id: "inv-1", email: "new@hive.co", role: "admin", status: "pending" });

    renderMembers();
    await screen.findByText("user-admin");

    await userEvent.type(screen.getByLabelText(/email address/i), "new@hive.co");
    // Target the invite role picker exactly — roster rows now also carry "…role…" labelled selects.
    await userEvent.selectOptions(screen.getByLabelText("Role"), "admin");
    await userEvent.click(screen.getByRole("button", { name: /send invitation/i }));

    await waitFor(() => expect(invite).toHaveBeenCalledTimes(1));
    // createInvitation(client, orgId, { email, role }) — assert the org-scope + chosen role.
    expect(invite.mock.calls[0]![1]).toBe("org-1");
    expect(invite.mock.calls[0]![2]).toEqual({ email: "new@hive.co", role: "admin" });
    expect(await screen.findByRole("status")).toHaveTextContent(/invitation sent to new@hive\.co/i);
  });

  it("blocks the invite when the email is malformed and never calls the API (validation)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember]));
    const invite = vi.spyOn(members, "createInvitation");

    renderMembers();
    await screen.findByText("user-admin");

    await userEvent.type(screen.getByLabelText(/email address/i), "not-an-email");
    await userEvent.click(screen.getByRole("button", { name: /send invitation/i }));

    expect(await screen.findByText(/enter a valid email address/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email address/i)).toHaveAttribute("aria-invalid", "true");
    expect(invite).not.toHaveBeenCalled();
  });
});

describe("MemberManagement — remove (FR-TEN-2, NFR-ROL-1)", () => {
  it("removes a member after an explicit confirmation step (destructive action)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const remove = vi.spyOn(members, "removeMember").mockResolvedValue(undefined);

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.click(screen.getByRole("button", { name: /remove member user-bob/i }));

    // A confirmation dialog appears; nothing has been removed yet.
    const dialog = await screen.findByRole("alertdialog");
    expect(remove).not.toHaveBeenCalled();

    await userEvent.click(within(dialog).getByRole("button", { name: /^remove member$/i }));

    await waitFor(() =>
      expect(remove).toHaveBeenCalledWith(expect.anything(), "org-1", "user-bob"),
    );
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
  });

  it("cancelling the confirmation does not remove the member", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const remove = vi.spyOn(members, "removeMember");

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.click(screen.getByRole("button", { name: /remove member user-bob/i }));
    const dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /cancel/i }));

    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(remove).not.toHaveBeenCalled();
  });

  it("moves focus into the confirmation dialog and closes it on Escape (a11y)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const remove = vi.spyOn(members, "removeMember");

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.click(screen.getByRole("button", { name: /remove member user-bob/i }));
    const dialog = await screen.findByRole("alertdialog");
    // Focus is moved into the dialog so it is announced and reachable.
    expect(dialog).toHaveFocus();

    await userEvent.keyboard("{Escape}");

    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(remove).not.toHaveBeenCalled();
  });

  it("surfaces the last-admin guard (409) clearly and keeps the member (D-3)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember]));
    vi.spyOn(members, "removeMember").mockRejectedValue(
      new ApiError("conflict", 409, "cannot remove the last admin"),
    );

    renderMembers();
    await screen.findByText("user-admin");

    await userEvent.click(screen.getByRole("button", { name: /remove member user-admin/i }));
    const dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /^remove member$/i }));

    expect(await within(dialog).findByText(/can't remove the last admin/i)).toBeInTheDocument();
    // The dialog stays open so the admin sees why; the roster is unchanged.
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
  });
});

describe("MemberManagement — change role (NFR-ROL-1, D-3)", () => {
  it("shows a per-member role picker only for active members (in the roster actions)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    const invited: Member = { user_id: "user-inv", role: "user", status: "invited" };
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember, invited]));

    renderMembers();
    await screen.findByText("user-bob");

    // Active members get a role picker…
    expect(screen.getByLabelText(/change role for member user-bob/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/change role for member user-admin/i)).toBeInTheDocument();
    // …an invited (not-yet-active) member does not — the change endpoint is for active members.
    expect(screen.queryByLabelText(/change role for member user-inv/i)).not.toBeInTheDocument();
  });

  it("confirms, PATCHes the chosen role, reflects it in the roster and announces success", async () => {
    useAuthMock.mockReturnValue(authenticated());
    // First read: bob is a plain member; after the change the roster re-reads him as an admin.
    vi.spyOn(members, "listMembers")
      .mockResolvedValueOnce(page([adminMember, plainMember]))
      .mockResolvedValue(page([adminMember, { ...plainMember, role: "admin" }]));
    const change = vi
      .spyOn(members, "changeMemberRole")
      .mockResolvedValue({ ...plainMember, role: "admin" });

    renderMembers();
    await screen.findByText("user-bob");

    // Picking a different role opens a confirmation step; nothing is sent yet.
    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    const dialog = await screen.findByRole("alertdialog");
    expect(change).not.toHaveBeenCalled();

    await userEvent.click(within(dialog).getByRole("button", { name: /^change role$/i }));

    // The PATCH carries the org scope, the target user, and the chosen role.
    await waitFor(() =>
      expect(change).toHaveBeenCalledWith(expect.anything(), "org-1", "user-bob", "admin"),
    );
    // Dialog closes, success is announced, and the roster reflects the new role after refetch.
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    expect(await screen.findByText(/user-bob is now admin/i)).toBeInTheDocument();
    const table = screen.getByRole("table", { name: /current members/i });
    await waitFor(() =>
      expect(
        within(table).getAllByText(/^Admin$/, { ignore: "script, style, option" }),
      ).toHaveLength(2),
    );
  });

  it("surfaces the last-admin guard (409) clearly and keeps the dialog open (D-3)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    vi.spyOn(members, "changeMemberRole").mockRejectedValue(
      new ApiError("conflict", 409, "cannot demote the last admin"),
    );

    renderMembers();
    await screen.findByText("user-admin");

    // Demote the only admin → the server's last-admin guard rejects it.
    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-admin/i),
      "user",
    );
    const dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /^change role$/i }));

    expect(await within(dialog).findByText(/can't demote the last admin/i)).toBeInTheDocument();
    // The dialog stays open so the admin sees why; no success announced.
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
    expect(screen.queryByText(/is now/i)).not.toBeInTheDocument();
  });

  it("surfaces a 404 (no longer a member) and a 403 (not permitted) with distinct messages", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const change = vi
      .spyOn(members, "changeMemberRole")
      .mockRejectedValueOnce(new ApiError("not-found", 404, "not a member"))
      .mockRejectedValueOnce(new ApiError("forbidden", 403, "not permitted"));

    renderMembers();
    await screen.findByText("user-bob");

    // 404 — the target is no longer a member.
    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    let dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /^change role$/i }));
    expect(await within(dialog).findByText(/no longer a member/i)).toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole("button", { name: /cancel/i }));

    // 403 — the server refuses (admin-only re-enforced).
    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /^change role$/i }));
    expect(
      await within(dialog).findByText(/don't have permission to change roles/i),
    ).toBeInTheDocument();
    expect(change).toHaveBeenCalledTimes(2);
  });

  it("surfaces a network error via the shared network message", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    vi.spyOn(members, "changeMemberRole").mockRejectedValue(new ApiError("network", 0, "offline"));

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    const dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /^change role$/i }));

    expect(await within(dialog).findByText(/could not reach the server/i)).toBeInTheDocument();
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();
  });

  it("does not render a role picker for a member whose role is outside the fixed set", async () => {
    useAuthMock.mockReturnValue(authenticated());
    // A defensive edge: the open MembershipRole type permits a value beyond admin/user.
    const oddRole = { user_id: "user-x", role: "owner", status: "active" } as unknown as Member;
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, oddRole]));

    renderMembers();
    await screen.findByText("user-x");

    // No mis-rendering select for the unknown role; the active admin still has one.
    expect(screen.queryByLabelText(/change role for member user-x/i)).not.toBeInTheDocument();
    expect(screen.getByLabelText(/change role for member user-admin/i)).toBeInTheDocument();
  });

  it("cancelling the confirmation does not change the role", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const change = vi.spyOn(members, "changeMemberRole");

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    const dialog = await screen.findByRole("alertdialog");
    await userEvent.click(within(dialog).getByRole("button", { name: /cancel/i }));

    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(change).not.toHaveBeenCalled();
  });

  it("moves focus into the role dialog and closes it on Escape (a11y)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));
    const change = vi.spyOn(members, "changeMemberRole");

    renderMembers();
    await screen.findByText("user-bob");

    await userEvent.selectOptions(
      screen.getByLabelText(/change role for member user-bob/i),
      "admin",
    );
    const dialog = await screen.findByRole("alertdialog");
    expect(dialog).toHaveFocus();

    await userEvent.keyboard("{Escape}");

    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    expect(change).not.toHaveBeenCalled();
  });

  it("renders the role-capabilities reference so an admin can inspect each role (NFR-ROL-1)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));

    renderMembers();
    await screen.findByText("user-bob");

    // The collapsible reference is present with its capability rows (row headers).
    expect(screen.getByText(/what can each role do/i)).toBeInTheDocument();
    expect(screen.getByRole("rowheader", { name: /assign member roles/i })).toBeInTheDocument();
  });
});

describe("MemberManagement — accessibility", () => {
  it("has no automatically-detectable accessibility violations", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));

    const { container } = renderMembers();
    await screen.findByRole("table", { name: /current members/i });

    await waitFor(async () => {
      expect(await axe(container)).toHaveNoViolations();
    });
  });
});
