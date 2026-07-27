import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { axe } from "jest-axe";
import { OperatorContextBanner } from "./OperatorContextBanner";

describe("OperatorContextBanner (#469, D-32 — safety-critical operator-context indicator)", () => {
  it("names the organization and is a live region so it is announced", () => {
    render(<OperatorContextBanner orgName="Apiário Beta" onSwitchOrganization={vi.fn()} />);

    const banner = screen.getByRole("status");
    expect(banner).toHaveTextContent(/apiário beta/i);
    expect(banner).toHaveTextContent(/platform operator/i);
  });

  it("does not rely on colour alone — an icon (decorative) plus explicit text carry the meaning", () => {
    render(<OperatorContextBanner orgName="Apiário Beta" onSwitchOrganization={vi.fn()} />);

    const icon = screen.getByText("⚠");
    expect(icon).toHaveAttribute("aria-hidden", "true");
    // The banner's own text (not the icon) is what assistive tech announces.
    expect(screen.getByRole("status")).toHaveTextContent(/you are administering/i);
  });

  it("invokes the switch-organization callback", async () => {
    const onSwitch = vi.fn();
    render(<OperatorContextBanner orgName="Apiário Beta" onSwitchOrganization={onSwitch} />);

    await userEvent.click(screen.getByRole("button", { name: /switch organization/i }));

    expect(onSwitch).toHaveBeenCalledOnce();
  });

  it("has no automatically-detectable accessibility violations", async () => {
    const { container } = render(
      <OperatorContextBanner orgName="Apiário Beta" onSwitchOrganization={vi.fn()} />,
    );

    expect(await axe(container)).toHaveNoViolations();
  });
});
