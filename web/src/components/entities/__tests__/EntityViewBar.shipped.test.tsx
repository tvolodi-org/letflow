// @vitest-environment jsdom
/** T-1868: the shipped "Asset list" report is shown in the user's language (en, ru, kk). */
import { describe, it, expect, afterEach } from "vitest";
import * as jestDomMatchers from "@testing-library/jest-dom/matchers";
import { render, screen, cleanup } from "@testing-library/react";
import { IntlProvider } from "react-intl";
import { EntityViewBar } from "../EntityViewBar";
import { entitiesMessages } from "@/i18n/entitiesMessages";

expect.extend(jestDomMatchers);
afterEach(cleanup);

const cases = [
  ["en", "Asset list"],
  ["ru", "Список активов"],
  ["kk", "Активтер тізімі"],
] as const;

describe("EntityViewBar shipped report name", () => {
  for (const [locale, label] of cases) {
    it(`shows ${label} in ${locale}`, () => {
      render(
        <IntlProvider locale={locale} messages={entitiesMessages[locale]}>
          <EntityViewBar
            views={[
              { id: "v1", name: "Asset list" },
              { id: "v2", name: "My own" },
            ]}
            activeViewId={null}
            onSelect={() => {}}
            fieldNames={[]}
            selectedColumns={[]}
            onToggleColumn={() => {}}
            canManage={false}
            onSave={async () => true}
            onDelete={() => {}}
            saveError={null}
            deleteError={null}
            busy={false}
          />
        </IntlProvider>,
      );
      expect(screen.getByRole("option", { name: label })).toBeInTheDocument();
      expect(screen.getByRole("option", { name: "My own" })).toBeInTheDocument();
    });
  }
});
