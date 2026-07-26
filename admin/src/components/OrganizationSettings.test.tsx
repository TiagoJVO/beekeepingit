import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import type { RenderResult } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { axe } from "jest-axe";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { AuthContextProps } from "react-oidc-context";
import { OrganizationSettings } from "./OrganizationSettings";
import { ApiError } from "../api/client";
import type { AppConfig } from "../config/env";
import * as organizations from "../api/organizations";
import type { Organization } from "../api/organizations";

// Mock the OIDC auth context: the screen is only ever reached by an authenticated admin.
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

const org: Organization = {
  id: "org-1",
  name: "Apiário Central",
  address: "Rua das Flores 1",
  role: "admin",
  updated_at: "2026-07-01T00:00:00Z",
};

function authenticated(): Partial<AuthContextProps> {
  return {
    isLoading: false,
    isAuthenticated: true,
    user: {
      access_token: "tok",
      profile: { sub: "user-1", name: "Ana Admin" },
    } as AuthContextProps["user"],
  };
}

function renderSettings(orgId?: string): RenderResult {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <OrganizationSettings config={config} orgId={orgId} />
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("OrganizationSettings", () => {
  it("loads and shows the organization's current name and address (FR-ONB-2)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    expect(nameInput).toHaveValue("Apiário Central");
    expect(screen.getByLabelText(/address/i)).toHaveValue("Rua das Flores 1");
  });

  it("saves an edit via PATCH with the ETag as If-Match and confirms success (happy path)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });
    const update = vi.spyOn(organizations, "updateOrganization").mockResolvedValue({
      data: { ...org, name: "Apiário Norte", updated_at: "2026-07-02T00:00:00Z" },
      etag: '"v2"',
    });

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "Apiário Norte");
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));

    await waitFor(() => expect(update).toHaveBeenCalledTimes(1));
    // updateOrganization(client, orgId, update, etag) — assert the org-scoped args + If-Match.
    expect(update.mock.calls[0]![1]).toBe("org-1");
    expect(update.mock.calls[0]![2]).toEqual({
      name: "Apiário Norte",
      address: "Rua das Flores 1",
    });
    expect(update.mock.calls[0]![3]).toBe('"v1"');

    expect(await screen.findByRole("status")).toHaveTextContent(/saved/i);
  });

  it("surfaces a 409 stale-write as a reload prompt and does not claim success (FR-TEN-2)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });
    vi.spyOn(organizations, "updateOrganization").mockRejectedValue(
      new ApiError("conflict", 409, "If-Match does not match the current version"),
    );

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "Apiário Norte");
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/someone else changed this organization/i);
    expect(screen.getByRole("button", { name: /reload latest details/i })).toBeInTheDocument();
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
  });

  it("reloading after a conflict adopts the latest server values (FR-TEN-2)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    const getOrg = vi
      .spyOn(organizations, "getOrganization")
      .mockResolvedValueOnce({ data: org, etag: '"v1"' })
      // The reload's refetch sees the record another admin changed in the meantime.
      .mockResolvedValueOnce({
        data: { ...org, name: "Apiário do Outro Admin", updated_at: "2026-07-03T00:00:00Z" },
        etag: '"v2"',
      });
    vi.spyOn(organizations, "updateOrganization").mockRejectedValue(
      new ApiError("conflict", 409, "stale"),
    );

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "Minha Edição");
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));
    await screen.findByRole("button", { name: /reload latest details/i });

    await userEvent.click(screen.getByRole("button", { name: /reload latest details/i }));

    await waitFor(() => expect(getOrg).toHaveBeenCalledTimes(2));
    // The form now shows the server's latest value, not the user's stale edit.
    expect(await screen.findByLabelText(/organization name/i)).toHaveValue(
      "Apiário do Outro Admin",
    );
    expect(screen.queryByText(/someone else changed this organization/i)).not.toBeInTheDocument();
  });

  it("refuses to save when the current version (ETag) is unavailable (fail-safe, FR-TEN-2)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    // A null ETag (e.g. a CORS response that does not expose it) must not degrade to an
    // unconditional overwrite: the save is blocked instead of silently dropping If-Match.
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: null });
    const update = vi.spyOn(organizations, "updateOrganization");

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "Apiário Norte");
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));

    expect(await screen.findByText(/could not confirm the current version/i)).toBeInTheDocument();
    expect(update).not.toHaveBeenCalled();
  });

  it("blocks the save when the name is empty and never calls the API (validation)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });
    const update = vi.spyOn(organizations, "updateOrganization");

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.clear(nameInput);
    // Empty name alone leaves the form dirty (differs from baseline), so Save is enabled.
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));

    expect(await screen.findByText(/organization name is required/i)).toBeInTheDocument();
    expect(nameInput).toHaveAttribute("aria-invalid", "true");
    expect(update).not.toHaveBeenCalled();
  });

  it("maps a server 422 back onto the offending field (server is authoritative)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });
    vi.spyOn(organizations, "updateOrganization").mockRejectedValue(
      new ApiError("validation", 422, "invalid", {
        title: "Validation failed",
        errors: [{ field: "name", code: "required", message: "name must not be empty" }],
      }),
    );

    renderSettings();

    const nameInput = await screen.findByLabelText(/organization name/i);
    await userEvent.type(nameInput, " Extra");
    await userEvent.click(screen.getByRole("button", { name: /save changes/i }));

    expect(await screen.findByText(/organization name is required/i)).toBeInTheDocument();
    expect(nameInput).toHaveAttribute("aria-invalid", "true");
  });

  it("reads an explicit orgId via /organizations/{orgId} instead of /me when supplied (#469, operator mode)", async () => {
    useAuthMock.mockReturnValue(authenticated());
    const getMyOrg = vi.spyOn(organizations, "getOrganization");
    const getOrgById = vi.spyOn(organizations, "getOrganizationById").mockResolvedValue({
      data: { ...org, id: "org-selected", name: "Apiário Selecionado" },
      etag: '"v1"',
    });

    render(
      <QueryClientProvider
        client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
      >
        <OrganizationSettings config={config} orgId="org-selected" />
      </QueryClientProvider>,
    );

    expect(await screen.findByLabelText(/organization name/i)).toHaveValue("Apiário Selecionado");
    expect(getOrgById).toHaveBeenCalledWith(expect.anything(), "org-selected");
    expect(getMyOrg).not.toHaveBeenCalled();
  });

  it("has no automatically-detectable accessibility violations", async () => {
    useAuthMock.mockReturnValue(authenticated());
    vi.spyOn(organizations, "getOrganization").mockResolvedValue({ data: org, etag: '"v1"' });

    const { container } = renderSettings();
    await screen.findByLabelText(/organization name/i);

    await waitFor(async () => {
      expect(await axe(container)).toHaveNoViolations();
    });
  });
});
