import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import type { RenderResult } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { axe } from "jest-axe";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AuthContextProps } from "react-oidc-context";
import { AdminGuard } from "./AdminGuard";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import * as organizations from "../api/organizations";
import * as members from "../api/members";

// --- Mock the OIDC auth context. Each test sets the return value of useAuth. ---
const useAuthMock = vi.fn<() => Partial<AuthContextProps>>();
vi.mock("react-oidc-context", () => ({
  useAuth: () => useAuthMock(),
}));

const config: AppConfig = {
  oidcIssuer: "https://auth.example/o/bk/",
  oidcClientId: "beekeepingit-admin",
  oidcRedirectUri: "http://localhost:5174",
  apiBaseUrl: "https://app.example",
  accountUrl: "https://auth.example/if/user/#/settings",
  quotasSeamEnabled: false,
};

const signinRedirect = vi.fn();
const signoutRedirect = vi.fn();

function authenticatedAs(name: string): Partial<AuthContextProps> {
  return {
    isLoading: false,
    error: undefined,
    isAuthenticated: true,
    // Minimal User shape the guard reads.
    user: { access_token: "tok", profile: { name } } as AuthContextProps["user"],
    signinRedirect,
    signoutRedirect,
  };
}

function renderGuard(): RenderResult {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <AdminGuard config={config} />
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("AdminGuard", () => {
  it("shows the login screen when unauthenticated and starts sign-in on click", async () => {
    useAuthMock.mockReturnValue({
      isLoading: false,
      isAuthenticated: false,
      signinRedirect,
      signoutRedirect,
    });

    renderGuard();

    expect(screen.getByRole("heading", { name: /sign in to the admin app/i })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /sign in/i }));
    expect(signinRedirect).toHaveBeenCalledOnce();
  });

  it("ALLOWS an admin: renders the guarded shell (NFR-ROL-1)", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("Ana Admin"));
    vi.spyOn(organizations, "getMyOrganization").mockResolvedValue({
      id: "o1",
      name: "Apiário Central",
      role: "admin",
    });
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({
      data: { id: "o1", name: "Apiário Central", address: "Rua das Flores 1", role: "admin" },
      etag: '"v1"',
    });

    renderGuard();

    expect(
      await screen.findByText(/signed in as ana admin · apiário central/i),
    ).toBeInTheDocument();
    expect(screen.getByText(/signed in as admin/i)).toBeInTheDocument();
    // The shell's first administrative screen is organization management (#73).
    expect(
      await screen.findByRole("heading", { name: /organization details/i }),
    ).toBeInTheDocument();
  });

  it("DENIES a non-admin (user role) with a clear message (NFR-ROL-1)", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("Uwe User"));
    vi.spyOn(organizations, "getMyOrganization").mockResolvedValue({
      id: "o1",
      name: "Apiário Central",
      role: "user",
    });

    renderGuard();

    expect(
      await screen.findByRole("heading", { name: /admin access required/i }),
    ).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: /welcome/i })).not.toBeInTheDocument();
  });

  it("DENIES with a no-organization message on a 404 (genuinely not a platform operator either)", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("New User"));
    vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
      new ApiError("not-found", 404, "no membership"),
    );
    // The operator-detection call (#469): a 403 here means this caller has no organization AND
    // is not a platform operator — the pre-existing "no organization" denial, unchanged.
    vi.spyOn(organizations, "listOrganizations").mockRejectedValue(
      new ApiError("forbidden", 403, "not a platform operator"),
    );

    renderGuard();

    expect(await screen.findByText(/not a member of any organization/i)).toBeInTheDocument();
  });

  describe("platform operator (#469, D-32)", () => {
    function operatorOrgs(): organizations.OrganizationList {
      return {
        data: [
          { id: "org-a", name: "Apiário Alfa", member_count: 3 },
          { id: "org-b", name: "Apiário Beta", member_count: 7 },
        ],
        page: { next_cursor: null, limit: 50 },
      };
    }

    it("shows the organization picker for a verified operator (no membership, GET /organizations succeeds)", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockResolvedValue(operatorOrgs());

      renderGuard();

      expect(
        await screen.findByRole("heading", { name: /choose an organization to administer/i }),
      ).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /apiário alfa/i })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /apiário beta/i })).toBeInTheDocument();
      // The organization-tier "admin access required"/"no organization" screens never render here.
      expect(
        screen.queryByRole("heading", { name: /admin access required/i }),
      ).not.toBeInTheDocument();
    });

    it("selecting an organization drives the detail screens with THAT org's data and shows the persistent operator banner", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockResolvedValue(operatorOrgs());
      const getOrgById = vi.spyOn(organizations, "getOrganizationById").mockResolvedValue({
        data: { id: "org-b", name: "Apiário Beta", address: "Rua B", role: "admin" },
        etag: '"v1"',
      });
      vi.spyOn(members, "listMembers").mockResolvedValue({
        data: [],
        page: { next_cursor: null, limit: 50 },
      });

      renderGuard();

      await userEvent.click(await screen.findByRole("button", { name: /apiário beta/i }));

      // The banner names the SELECTED org and is visible alongside the detail screens.
      const banner = await screen.findByRole("status");
      expect(banner).toHaveTextContent(/platform operator view/i);
      expect(banner).toHaveTextContent(/apiário beta/i);

      // The org-settings screen reads the SELECTED org (org-b) via /organizations/{orgId}, never
      // "my organization" — proving the selected org drives the detail screens, not "my org".
      await waitFor(() => expect(getOrgById).toHaveBeenCalledWith(expect.anything(), "org-b"));
      expect(await screen.findByDisplayValue("Apiário Beta")).toBeInTheDocument();
    });

    it("switching organizations returns the operator to the picker", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockResolvedValue(operatorOrgs());
      vi.spyOn(organizations, "getOrganizationById").mockResolvedValue({
        data: { id: "org-b", name: "Apiário Beta", address: "Rua B", role: "admin" },
        etag: '"v1"',
      });
      vi.spyOn(members, "listMembers").mockResolvedValue({
        data: [],
        page: { next_cursor: null, limit: 50 },
      });

      renderGuard();

      await userEvent.click(await screen.findByRole("button", { name: /apiário beta/i }));
      await screen.findByText(/platform operator view/i);

      await userEvent.click(screen.getByRole("button", { name: /switch organization/i }));

      expect(
        await screen.findByRole("heading", { name: /choose an organization to administer/i }),
      ).toBeInTheDocument();
    });

    it("shows a retryable error when the operator-detection call fails on the network", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockRejectedValue(
        new ApiError("network", 0, "offline"),
      );

      renderGuard();

      expect(
        await screen.findByRole("heading", { name: /could not verify your access/i }),
      ).toBeInTheDocument();
      expect(screen.getByText(/could not reach the server/i)).toBeInTheDocument();
    });

    it("the organization picker has no automatically-detectable accessibility violations", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockResolvedValue(operatorOrgs());

      const { container } = renderGuard();
      await screen.findByRole("heading", { name: /choose an organization to administer/i });

      await waitFor(async () => {
        expect(await axe(container)).toHaveNoViolations();
      });
    });

    it("the operator-context banner + detail screens have no automatically-detectable accessibility violations", async () => {
      useAuthMock.mockReturnValue(authenticatedAs("Opal Operator"));
      vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
        new ApiError("not-found", 404, "no membership"),
      );
      vi.spyOn(organizations, "listOrganizations").mockResolvedValue(operatorOrgs());
      vi.spyOn(organizations, "getOrganizationById").mockResolvedValue({
        data: { id: "org-b", name: "Apiário Beta", address: "Rua B", role: "admin" },
        etag: '"v1"',
      });
      vi.spyOn(members, "listMembers").mockResolvedValue({
        data: [],
        page: { next_cursor: null, limit: 50 },
      });

      const { container } = renderGuard();
      await userEvent.click(await screen.findByRole("button", { name: /apiário beta/i }));
      await screen.findByText(/platform operator view/i);

      await waitFor(async () => {
        expect(await axe(container)).toHaveNoViolations();
      });
    });
  });

  it("signs the denied user out on request", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("Uwe User"));
    vi.spyOn(organizations, "getMyOrganization").mockResolvedValue({
      id: "o1",
      name: "Org",
      role: "user",
    });

    renderGuard();

    await screen.findByRole("heading", { name: /admin access required/i });
    await userEvent.click(screen.getByRole("button", { name: /sign out/i }));
    expect(signoutRedirect).toHaveBeenCalledOnce();
  });

  it("shows an auth error with a retry that restarts sign-in", async () => {
    useAuthMock.mockReturnValue({
      isLoading: false,
      error: new Error("token exchange failed") as AuthContextProps["error"],
      isAuthenticated: false,
      signinRedirect,
      signoutRedirect,
    });

    renderGuard();

    expect(await screen.findByRole("heading", { name: /sign-in failed/i })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /try again/i }));
    expect(signinRedirect).toHaveBeenCalledOnce();
  });

  it("shows a retryable access error when the role lookup fails on the network", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("Ann Admin"));
    vi.spyOn(organizations, "getMyOrganization").mockRejectedValue(
      new ApiError("network", 0, "offline"),
    );

    renderGuard();

    expect(
      await screen.findByRole("heading", { name: /could not verify your access/i }),
    ).toBeInTheDocument();
    expect(screen.getByText(/could not reach the server/i)).toBeInTheDocument();
  });

  it("the admin shell has no automatically-detectable accessibility violations", async () => {
    useAuthMock.mockReturnValue(authenticatedAs("Ana Admin"));
    vi.spyOn(organizations, "getMyOrganization").mockResolvedValue({
      id: "o1",
      name: "Org",
      role: "admin",
    });
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({
      data: { id: "o1", name: "Org", address: "1 Main St", role: "admin" },
      etag: '"v1"',
    });

    const { container } = renderGuard();
    await screen.findByRole("heading", { name: /organization details/i });

    await waitFor(async () => {
      expect(await axe(container)).toHaveNoViolations();
    });
  });
});
