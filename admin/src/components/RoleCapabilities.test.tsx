import { describe, expect, it } from "vitest";
import { render, screen, within } from "@testing-library/react";
import { axe } from "jest-axe";
import { RoleCapabilities } from "./RoleCapabilities";

describe("RoleCapabilities — inspect what each role can do (NFR-ROL-1, auth.md §5.3)", () => {
  it("renders the fixed capability matrix with a column per role", () => {
    render(<RoleCapabilities />);

    const table = screen.getByRole("table", { name: /what can each role do/i });
    // Column headers: capability + the two fixed roles.
    expect(within(table).getByRole("columnheader", { name: /admin/i })).toBeInTheDocument();
    expect(within(table).getByRole("columnheader", { name: /member/i })).toBeInTheDocument();
    // Each capability is a row header (accessible association of its allowed/not-allowed cells).
    expect(
      within(table).getByRole("rowheader", { name: /invite and remove members/i }),
    ).toBeInTheDocument();
    expect(
      within(table).getByRole("rowheader", { name: /assign member roles/i }),
    ).toBeInTheDocument();
  });

  it("marks allowed/not-allowed cells with accessible text, not bare glyphs", () => {
    render(<RoleCapabilities />);

    // Members can't manage members/roles/org settings — three "Not allowed" cells for the user role,
    // plus shared-data + AI/history allowed. Assert the accessible text is present (glyph is aria-hidden).
    expect(screen.getAllByText(/not allowed/i).length).toBeGreaterThanOrEqual(3);
    expect(screen.getAllByText(/^allowed$/i).length).toBeGreaterThanOrEqual(4);
  });

  it("has no automatically-detectable accessibility violations", async () => {
    const { container } = render(<RoleCapabilities />);
    // Open the <details> so the table is in the a11y tree when axe runs.
    container.querySelector("details")?.setAttribute("open", "");
    expect(await axe(container)).toHaveNoViolations();
  });
});
