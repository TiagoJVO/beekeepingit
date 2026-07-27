import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { App } from "./App";

// Explicitly stubbed empty rather than relying on the ambient process environment having
// nothing set: release-deploy.yml exports real VITE_* values into the shell before running
// this suite (so the build step downstream has them), which would otherwise make this test
// flaky/failing there even though it passes locally. With the required vars force-cleared,
// readConfig reports a missing configuration and App must render the ConfigError screen
// (never a blank page or a crash) before it ever mounts the OIDC provider.
describe("App", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_OIDC_ISSUER", "");
    vi.stubEnv("VITE_OIDC_CLIENT_ID", "");
    vi.stubEnv("VITE_API_BASE_URL", "");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("renders a clear configuration error when required env vars are missing", () => {
    render(<App />);
    expect(screen.getByRole("heading", { name: /configuration error/i })).toBeInTheDocument();
    expect(screen.getByText("VITE_OIDC_ISSUER")).toBeInTheDocument();
  });
});
