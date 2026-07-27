import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { axe } from "jest-axe";
import { useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AuthContextProps } from "react-oidc-context";
import { OrganizationPicker } from "./OrganizationPicker";
import { useOrganizations } from "../hooks/useOrganizations";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import * as organizations from "../api/organizations";
import type { OrganizationSummary } from "../api/organizations";

// Mock the OIDC auth context, same convention as the other component tests in this app.
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

function authenticated(): Partial<AuthContextProps> {
  return {
    isLoading: false,
    isAuthenticated: true,
    user: { access_token: "tok", profile: { sub: "op-1" } } as AuthContextProps["user"],
  };
}

// A thin harness wiring the real `useOrganizations` hook into `OrganizationPicker` — search
// state lives at the caller (mirroring `AdminGuard`), so this is exactly how the app composes
// the two, rather than hand-mocking the hook's return shape.
function Harness({
  onSelect,
  onSignOut,
}: {
  onSelect: (org: OrganizationSummary) => void;
  onSignOut: () => void;
}) {
  const [search, setSearch] = useState("");
  const { query, organizations: orgs } = useOrganizations(config, { enabled: true, search });
  return (
    <OrganizationPicker
      organizations={orgs}
      query={query}
      search={search}
      onSearchChange={setSearch}
      onSelect={onSelect}
      userName="Opal Operator"
      onSignOut={onSignOut}
    />
  );
}

function renderPicker(onSelect = vi.fn(), onSignOut = vi.fn()) {
  useAuthMock.mockReturnValue(authenticated());
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <Harness onSelect={onSelect} onSignOut={onSignOut} />
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("OrganizationPicker", () => {
  it("lists organizations and lets the operator select one (#469)", async () => {
    vi.spyOn(organizations, "listOrganizations").mockResolvedValue({
      data: [
        { id: "org-a", name: "Apiário Alfa", member_count: 3 },
        { id: "org-b", name: "Apiário Beta", member_count: 7 },
      ],
      page: { next_cursor: null, limit: 50 },
    });
    const onSelect = vi.fn();

    renderPicker(onSelect);

    const row = await screen.findByRole("button", { name: /apiário alfa/i });
    await userEvent.click(row);

    expect(onSelect).toHaveBeenCalledWith(
      expect.objectContaining({ id: "org-a", name: "Apiário Alfa" }),
    );
  });

  it("submits a search and refetches filtered by it, restarting pagination", async () => {
    const list = vi.spyOn(organizations, "listOrganizations").mockResolvedValue({
      data: [{ id: "org-a", name: "Apiário Alfa", member_count: 3 }],
      page: { next_cursor: null, limit: 50 },
    });

    renderPicker();

    await screen.findByRole("button", { name: /apiário alfa/i });
    await userEvent.type(screen.getByLabelText(/search organizations/i), "Alfa");
    await userEvent.click(screen.getByRole("button", { name: /^search$/i }));

    await waitFor(() =>
      expect(list).toHaveBeenLastCalledWith(expect.anything(), { cursor: null, q: "Alfa" }),
    );
  });

  it("loads the next page on demand (cursor pagination)", async () => {
    const list = vi
      .spyOn(organizations, "listOrganizations")
      .mockResolvedValueOnce({
        data: [{ id: "org-a", name: "Apiário Alfa", member_count: 3 }],
        page: { next_cursor: "cursor-2", limit: 50 },
      })
      .mockResolvedValueOnce({
        data: [{ id: "org-b", name: "Apiário Beta", member_count: 7 }],
        page: { next_cursor: null, limit: 50 },
      });

    renderPicker();

    await screen.findByRole("button", { name: /apiário alfa/i });
    await userEvent.click(screen.getByRole("button", { name: /load more organizations/i }));

    await screen.findByRole("button", { name: /apiário beta/i });
    expect(list).toHaveBeenCalledTimes(2);
  });

  it("shows a retryable error when the list fails to load (keyboard-operable retry)", async () => {
    vi.spyOn(organizations, "listOrganizations").mockRejectedValue(
      new ApiError("network", 0, "offline"),
    );

    renderPicker();

    expect(await screen.findByRole("alert")).toHaveTextContent(/could not reach the server/i);
    expect(screen.getByRole("button", { name: /try again/i })).toBeInTheDocument();
  });

  it("shows an empty state when no organizations match the search", async () => {
    vi.spyOn(organizations, "listOrganizations").mockResolvedValue({
      data: [],
      page: { next_cursor: null, limit: 50 },
    });

    renderPicker();

    expect(await screen.findByText(/no organizations match/i)).toBeInTheDocument();
  });

  it("has no automatically-detectable accessibility violations", async () => {
    vi.spyOn(organizations, "listOrganizations").mockResolvedValue({
      data: [{ id: "org-a", name: "Apiário Alfa", member_count: 3 }],
      page: { next_cursor: null, limit: 50 },
    });

    const { container } = renderPicker();
    await screen.findByRole("button", { name: /apiário alfa/i });

    await waitFor(async () => {
      expect(await axe(container)).toHaveNoViolations();
    });
  });
});
