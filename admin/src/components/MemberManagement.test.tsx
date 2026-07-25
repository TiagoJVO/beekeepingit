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

    const table = await screen.findByRole("table");
    expect(within(table).getByText("user-admin")).toBeInTheDocument();
    expect(within(table).getByText("user-bob")).toBeInTheDocument();
    // Role + status are rendered as localized labels, not raw enum values.
    expect(within(table).getByText(/^Admin$/)).toBeInTheDocument();
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
    await userEvent.selectOptions(screen.getByLabelText(/role/i), "admin");
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

describe("MemberManagement — accessibility", () => {
  it("has no automatically-detectable accessibility violations", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(members, "listMembers").mockResolvedValue(page([adminMember, plainMember]));

    const { container } = renderMembers();
    await screen.findByRole("table");

    await waitFor(async () => {
      expect(await axe(container)).toHaveNoViolations();
    });
  });
});
