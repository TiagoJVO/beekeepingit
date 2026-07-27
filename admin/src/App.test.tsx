import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { App } from "./App";

// No VITE_* env vars are set under vitest, so readConfig reports a missing configuration and
// App must render the ConfigError screen (never a blank page or a crash) before it ever
// mounts the OIDC provider.
describe("App", () => {
  it("renders a clear configuration error when required env vars are missing", () => {
    render(<App />);
    expect(screen.getByRole("heading", { name: /configuration error/i })).toBeInTheDocument();
    expect(screen.getByText("VITE_OIDC_ISSUER")).toBeInTheDocument();
  });
});
