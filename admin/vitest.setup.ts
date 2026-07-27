import "@testing-library/jest-dom/vitest";
import { afterEach, expect } from "vitest";
import { cleanup } from "@testing-library/react";
// jest-axe ships CommonJS; import the matcher and register it on vitest's expect.
import { toHaveNoViolations } from "jest-axe";
import { initI18n } from "./src/i18n";

expect.extend(toHaveNoViolations);

// Initialize i18n once and pin English for deterministic assertions on rendered strings.
const i18n = initI18n();
void i18n.changeLanguage("en");

afterEach(() => {
  cleanup();
});
