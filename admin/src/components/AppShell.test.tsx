import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AuthContextProps } from "react-oidc-context";
import { AppShell } from "./AppShell";
import type { AppConfig } from "../config/env";
import * as organizations from "../api/organizations";
import * as members from "../api/members";

// The quotas/rate-limit management surface is DEFERRED out of v1 (D-4); the admin app carries
// only an INERT seam for it (EPIC-91). These tests pin the two guarantees that keep it inert:
// it is absent by default (flag off), and even when flagged on it is a disabled, non-actionable
// stub — while #73's organization-settings screen keeps rendering either way.
const useAuthMock = vi.fn<() => Partial<AuthContextProps>>();
vi.mock("react-oidc-context", () => ({
  useAuth: () => useAuthMock(),
}));

const baseConfig: AppConfig = {
  oidcIssuer: "https://auth.example/o/bk/",
  oidcClientId: "beekeepingit-admin",
  oidcRedirectUri: "http://localhost:5174",
  apiBaseUrl: "https://app.example",
  accountUrl: "",
  quotasSeamEnabled: false,
};

function renderShell(quotasSeamEnabled: boolean) {
  useAuthMock.mockReturnValue({
    isLoading: false,
    isAuthenticated: true,
    user: {
      access_token: "tok",
      profile: { sub: "user-1", name: "Ada" },
    } as AuthContextProps["user"],
  });
  // Keep the embedded organization (#73) and member (#74) screens in a quiet loading state —
  // this suite only asserts the nav seam, not org/member CRUD, so we never resolve the fetches.
  vi.spyOn(organizations, "getOrganization").mockReturnValue(new Promise(() => {}));
  vi.spyOn(members, "listMembers").mockReturnValue(new Promise(() => {}));

  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <AppShell
        config={{ ...baseConfig, quotasSeamEnabled }}
        userName="Ada"
        orgName="Hive Co"
        orgId="org-1"
        onSignOut={vi.fn()}
      />
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("AppShell quotas/rate-limit seam", () => {
  it("does not render the quotas seam by default (ships inert)", () => {
    renderShell(false);
    expect(screen.queryByText(/quotas & rate limits/i)).not.toBeInTheDocument();
    // #73's organization-settings screen still renders regardless of the deferred seam.
    expect(screen.getByText(/loading your organization/i)).toBeInTheDocument();
  });

  it("renders a disabled, non-actionable entry only when the flag is on", () => {
    renderShell(true);
    const seam = screen.getByRole("button", { name: /quotas & rate limits/i });
    expect(seam).toBeDisabled();
    expect(seam).toHaveAttribute("aria-disabled", "true");
    // Coexists with #73's organization-settings screen.
    expect(screen.getByText(/loading your organization/i)).toBeInTheDocument();
  });
});
