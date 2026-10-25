// @vitest-environment jsdom
/**
 * REQ-556 — saved views on the record list screen (EntityListBrowserPage)
 *
 *   V1/V2: selecting a view sets columns, filter and sort controls; "(no view)" resets them
 *   V3:    the request body is the stored filter and sort, page size unchanged
 *   V4/V5: save and delete controls only with EntitiesViewsManage
 *   V6:    a redacted stored column is not rendered as a value
 *   V7/V8: save sends the controls' state; a 409 shows an inline message
 *   V9:    delete asks for confirmation
 *
 * Mocking pattern as EntityListBrowserPage.test.tsx: useQuery by queryKey[3].
 */

import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import * as jestDomMatchers from "@testing-library/jest-dom/matchers";
import {
  render,
  act,
  screen,
  cleanup,
  fireEvent,
} from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
expect.extend(jestDomMatchers);

vi.mock("@tanstack/react-query", () => ({
  useQuery: vi.fn(),
}));

// The real DataTable (tanstack table with a fresh `sorting` array per render)
// re-renders without end once a state update lands outside the initial act();
// the async save/delete tests need a settled tree, so the table is stubbed. The
// stub still calls each column's accessor, which is what the tests look at.
vi.mock("@/components/ui/DataTable", () => ({
  DataTable: (props: {
    columns: { id: string; header: string; accessor: (r: never) => unknown }[];
    data: never[];
  }) => (
    <table data-testid="data-table">
      <thead>
        <tr>
          {props.columns.map((c) => (
            <th key={c.id}>{c.header}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {props.data.map((r, i) => (
          <tr key={i}>
            {props.columns.map((c) => (
              <td key={c.id}>{c.accessor(r) as string}</td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  ),
}));

vi.mock("@/api/entities", () => ({
  entitiesApi: {
    getActiveDefinition: vi.fn(),
    queryRecords: vi.fn(),
  },
}));

vi.mock("@/api/entityViews", () => ({
  entityViewsApi: {
    list: vi.fn(),
    create: vi.fn(),
    remove: vi.fn(),
  },
}));

vi.mock("@/auth/AuthContext", () => ({
  useAuth: () => ({
    session: {
      token: "tok",
      display_name: "Test User",
      loginSource: "oidc",
      tenant_slug: "fixture-tenant",
      tenant_display_name: "Fixture Tenant",
      tenant_id: "tid-entity-views",
      tenant_type: "test",
    },
    isAuthenticated: true,
  }),
}));

import { useQuery } from "@tanstack/react-query";
import { entitiesApi } from "@/api/entities";
import { entityViewsApi } from "@/api/entityViews";
import { EntityListBrowserPage } from "@/pages/entities/EntityListBrowserPage";
import { AccessStateProvider } from "@/auth/access/AccessContext";
import { accessState, LOADING_STATE } from "@/auth/access/fixtures";
import { P, type AccessState } from "@/auth/access";
import { FIELD_REDACTED, isRedacted } from "@/lib/entities/fieldRedaction";
import type {
  EntityDefinition,
  EntityFieldDef,
  EntityView,
} from "@/types/api";

const mockUseQuery = vi.mocked(useQuery);

const FIELDS: EntityFieldDef[] = [
  { name: "a", type: "string", required: false, queried: true },
  { name: "b", type: "string", required: false, queried: true },
  { name: "secret", type: "string", required: false, queried: false },
  { name: "flag", type: "boolean", required: false, queried: false },
  { name: "label", type: "localized_text", required: false, queried: false },
];

const DEFINITION: EntityDefinition = {
  id: "def-tag",
  name: "tag",
  display_name: "Tag",
  definition: { name: "tag", display_name: "Tag", fields: FIELDS },
  content_hash: "x",
  logical_shape_version: "v1",
  artifact_version_id: "av1",
  status: "active",
  inserted_at: "2026-01-01T00:00:00Z",
};

const VIEW: EntityView = {
  id: "view-1",
  entity_type: "tag",
  name: "My view",
  columns: ["b", "a"],
  filter: [{ field: "a", op: "eq", value: "x" }],
  sort: [{ field: "b", dir: "desc" }],
};

function item(recordId: string, fieldValues: Record<string, unknown>) {
  return {
    record_id: recordId,
    field_values: fieldValues,
    deleted: false,
    entity_def_version: "v1",
    last_event_global_seq: 1,
  };
}

// react-query keeps `data` referentially stable between renders; the table
// library loops on a fresh array each render, so the mock does the same.
const pages = new WeakMap<object, { items: unknown[]; next_cursor: null }>();
function stablePage(items: unknown[]) {
  let page = pages.get(items);
  if (!page) {
    page = { items, next_cursor: null };
    pages.set(items, page);
  }
  return page;
}

let viewsData: EntityView[] = [];
let recordItems: unknown[] = [];
const viewsRefetch = vi.fn();

function ok(data: unknown, refetch = vi.fn()) {
  return {
    data,
    isLoading: false,
    isError: false,
    error: null,
    refetch,
  } as unknown as ReturnType<typeof useQuery>;
}

beforeEach(() => {
  viewsData = [VIEW];
  recordItems = [item("r1", { a: "a1", b: "b1" })];
  viewsRefetch.mockResolvedValue(undefined);
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] };
    if (queryKey[3] === "definition") return ok(DEFINITION);
    if (queryKey[3] === "views")
      return ok(stablePage(viewsData), viewsRefetch);
    return ok(stablePage(recordItems));
  });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const MANAGE: AccessState = (() => {
  const s = accessState("tenantAdmin");
  if (s.status !== "ready") throw new Error("fixture not ready");
  return {
    status: "ready",
    info: {
      ...s.info,
      permissions: [...s.info.permissions, P.EntitiesViewsManage],
    },
  };
})();

function renderPage(access: AccessState = MANAGE) {
  return render(
    <AccessStateProvider state={access}>
      <MemoryRouter initialEntries={["/entities/tag"]}>
        <Routes>
          <Route
            path="/entities/:entityType"
            element={<EntityListBrowserPage />}
          />
        </Routes>
      </MemoryRouter>
    </AccessStateProvider>,
  );
}

function headers(): string[] {
  return screen.getAllByRole("columnheader").map((h) => h.textContent ?? "");
}

function selectView(id: string) {
  fireEvent.change(screen.getByTestId("view-select"), { target: { value: id } });
}

function lastRecordsQueryFn(): () => unknown {
  const calls = mockUseQuery.mock.calls
    .map((c) => c[0] as { queryKey: readonly unknown[]; queryFn: () => unknown })
    .filter((o) => o.queryKey[3] === "browser");
  return calls[calls.length - 1].queryFn;
}

describe("REQ-556 — selecting a view", () => {
  it("V1: sets columns, filter and sort controls to the stored values", () => {
    renderPage();
    selectView("view-1");
    const row = screen.getByTestId("filter-row");
    expect(row.querySelector("select")).toHaveValue("a");
    expect(screen.getByDisplayValue("x")).toBeInTheDocument();
    expect(screen.getByTestId("sort-field")).toHaveValue("b");
    expect(screen.getByTestId("sort-dir")).toHaveValue("desc");
    expect(headers()).toEqual(["b", "a"]);
  });

  it("V2: choosing (no view) restores the initial controls", () => {
    renderPage();
    selectView("view-1");
    selectView("");
    expect(screen.queryAllByTestId("filter-row")).toHaveLength(0);
    expect(screen.getByTestId("sort-field")).toHaveValue("");
    expect(headers()).toEqual(FIELDS.map((f) => f.name));
  });

  it("V3: request body is the stored filter and sort, page size unchanged", () => {
    const twoSorts = [
      { field: "b", dir: "desc" as const },
      { field: "a", dir: "asc" as const },
    ];
    viewsData = [{ ...VIEW, sort: twoSorts }];
    renderPage();
    fireEvent.change(screen.getByTestId("page-size"), {
      target: { value: "50" },
    });
    selectView("view-1");
    lastRecordsQueryFn()();
    expect(vi.mocked(entitiesApi.queryRecords)).toHaveBeenLastCalledWith(
      "tag",
      {
        filters: VIEW.filter,
        sort: twoSorts,
        page_size: 50,
        cursor: undefined,
      },
    );
    expect(screen.getByTestId("page-size")).toHaveValue("50");
  });
});

describe("REQ-556 — save and delete controls", () => {
  it("V4: a user with EntitiesViewsManage sees selector, save and delete", () => {
    renderPage(MANAGE);
    expect(screen.getByTestId("view-select")).toBeInTheDocument();
    expect(screen.getByTestId("view-save")).toBeInTheDocument();
    expect(screen.getByTestId("view-delete")).toBeInTheDocument();
  });

  it("V5: without it the selector shows but save and delete do not", () => {
    for (const state of [accessState("tenantAdmin"), LOADING_STATE]) {
      renderPage(state);
      expect(screen.getByTestId("view-select")).toBeInTheDocument();
      expect(screen.queryByTestId("view-save")).toBeNull();
      expect(screen.queryByTestId("view-delete")).toBeNull();
      cleanup();
    }
  });
});

describe("REQ-556 — redaction", () => {
  it("V6: a redacted stored column renders empty, never the sentinel", () => {
    viewsData = [{ ...VIEW, columns: ["a", "secret"], filter: [], sort: [] }];
    recordItems = [
      item("r1", { a: "n1", secret: FIELD_REDACTED }),
      item("r2", { a: "n2" }),
    ];
    const { container } = renderPage();
    selectView("view-1");
    expect(headers()).toEqual(["a", "secret"]);
    expect(screen.getByText("n1")).toBeInTheDocument();
    expect(screen.queryByText(FIELD_REDACTED)).toBeNull();
    expect(container.textContent).not.toContain(FIELD_REDACTED);
  });

  it("V6b: boolean and localized_text holding the sentinel render empty", () => {
    viewsData = [
      { ...VIEW, columns: ["a", "flag", "label"], filter: [], sort: [] },
    ];
    recordItems = [
      item("r1", { a: "n1", flag: FIELD_REDACTED, label: FIELD_REDACTED }),
    ];
    const { container } = renderPage();
    selectView("view-1");
    expect(screen.queryByText("Yes")).toBeNull();
    expect(container.textContent).not.toContain(FIELD_REDACTED);
    expect(isRedacted(FIELD_REDACTED)).toBe(true);
    expect(isRedacted("other")).toBe(false);
  });

  it("V6c: nothing from the view object is rendered as a cell value", () => {
    viewsData = [{ ...VIEW, secret: "LEAK" } as unknown as EntityView];
    const { container } = renderPage();
    selectView("view-1");
    expect(container.textContent).not.toContain("LEAK");
  });
});

describe("REQ-556 — save and delete", () => {
  // State is set after an await, so the click runs inside an async act().
  async function clickAsync(testId: string) {
    await act(async () => {
      fireEvent.click(screen.getByTestId(testId));
      for (let i = 0; i < 20; i++) await Promise.resolve();
    });
  }

  it("V7: save sends the controls' state and refetches the views", async () => {
    vi.mocked(entityViewsApi.create).mockResolvedValue({
      ...VIEW,
      id: "view-2",
      name: "Fresh",
    });
    renderPage();
    selectView("view-1");
    fireEvent.change(screen.getByTestId("view-name"), {
      target: { value: "  Fresh " },
    });
    viewsData = [VIEW, { ...VIEW, id: "view-2", name: "Fresh" }];
    await clickAsync("view-save");
    expect(viewsRefetch).toHaveBeenCalled();
    expect(entityViewsApi.create).toHaveBeenCalledWith({
      entity_type: "tag",
      name: "Fresh",
      columns: ["b", "a"],
      filter: [{ field: "a", op: "eq", value: "x" }],
      sort: [{ field: "b", dir: "desc" }],
    });
    expect(screen.getByTestId("view-name")).toHaveValue("");
  });

  it("V8: a 409 on save shows an inline message", async () => {
    vi.mocked(entityViewsApi.create).mockRejectedValue({ status: 409 });
    renderPage();
    fireEvent.change(screen.getByTestId("view-name"), {
      target: { value: "Dup" },
    });
    viewsData = [VIEW, { ...VIEW, id: "view-2", name: "Fresh" }];
    await clickAsync("view-save");
    expect(screen.getByTestId("view-save-error")).toHaveTextContent(
      "A view with this name already exists.",
    );
    expect(screen.getByTestId("view-name")).toHaveValue("Dup");
  });

  it("V9: delete needs confirmation; cancel does nothing", async () => {
    vi.mocked(entityViewsApi.remove).mockResolvedValue(undefined);
    renderPage();
    selectView("view-1");
    fireEvent.click(screen.getByTestId("view-delete"));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(entityViewsApi.remove).not.toHaveBeenCalled();

    fireEvent.click(screen.getByTestId("view-delete"));
    await act(async () => {
      fireEvent.click(screen.getAllByRole("button", { name: "Delete" })[0]);
    });
    expect(entityViewsApi.remove).toHaveBeenCalledWith("view-1");
    expect(viewsRefetch).toHaveBeenCalled();
  });
});
