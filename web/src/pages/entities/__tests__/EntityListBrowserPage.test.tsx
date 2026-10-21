// @vitest-environment jsdom
/**
 * REQ-393 — unit tests for EntityFilterBuilder and EntityListBrowserPage
 *
 *   EntityFilterBuilder (purely presentational, no query state):
 *     TC-EFB-01: renders empty state when rows is empty
 *     TC-EFB-02: add-filter button calls onChange with one new row
 *     TC-EFB-03: remove button calls onChange without the removed row
 *     TC-EFB-04: field/op/value changes propagate to onChange
 *
 *   EntityListBrowserPage (wired to useQuery):
 *     TC-ELBP-01: definition loading → outer QueryStateBoundary shows
 *                 SkeletonLayout (aria-busy="true")
 *     TC-ELBP-02: records 422 (field_not_allowed) → query-error-banner shows
 *                 the API message; page-size-error is absent
 *     TC-ELBP-03: records 400 (page_size_too_large) → page-size-error shows;
 *                 query-error-banner is absent
 *     TC-ELBP-04: successful query → table renders column headers and row data
 *
 * Mocking pattern: useQuery mocked directly (DIRECTIVE T-2), no msw/raw-fetch.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import * as jestDomMatchers from "@testing-library/jest-dom/matchers";
import { render, screen, cleanup, fireEvent } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
expect.extend(jestDomMatchers);

vi.mock("@tanstack/react-query", () => ({
  useQuery: vi.fn(),
}));

vi.mock("@/api/entities", () => ({
  entitiesApi: {
    getActiveDefinition: vi.fn(),
    queryRecords: vi.fn(),
  },
}));

// REQ-384: EntityListBrowserPage resolves tenant-scoped query keys via
// useTenantScopedQueryKeys(), which reads useAuth().session.tenant_id.
// A fixed authenticated session is sufficient here.
vi.mock("@/auth/AuthContext", () => ({
  useAuth: () => ({
    session: {
      token: "tok",
      display_name: "Test User",
      loginSource: "oidc",
      tenant_slug: "fixture-tenant",
      tenant_display_name: "Fixture Tenant",
      tenant_id: "tid-entity-list-browser",
      tenant_type: "test",
      production_tenant_display_name: null,
    },
    isAuthenticated: true,
  }),
}));

import { useQuery } from "@tanstack/react-query";
import { EntityFilterBuilder } from "@/components/entities/EntityFilterBuilder";
import type { FilterRow } from "@/components/entities/EntityFilterBuilder";
import { EntityListBrowserPage } from "@/pages/entities/EntityListBrowserPage";
import type {
  EntityDefinition,
  EntityRecordsPage,
  EntityFieldDef,
} from "@/types/api";

const mockUseQuery = vi.mocked(useQuery);

// ── shared fixtures ────────────────────────────────────────────────────────────

const TAG_QUERIED_FIELDS: EntityFieldDef[] = [
  { name: "name", type: "string", required: true, queried: true },
  { name: "description", type: "string", required: false, queried: true },
];

const TAG_ALL_FIELDS: EntityFieldDef[] = [
  ...TAG_QUERIED_FIELDS,
  // internal_note is NOT queried — must not appear in filter field selector
  { name: "internal_note", type: "string", required: false, queried: false },
];

const TAG_DEFINITION: EntityDefinition = {
  id: "def-tag",
  name: "tag",
  display_name: "Tag",
  definition: {
    name: "tag",
    display_name: "Tag",
    fields: TAG_ALL_FIELDS,
  },
  content_hash: "x",
  logical_shape_version: "v1",
  artifact_version_id: "av1",
  status: "active",
  inserted_at: "2026-01-01T00:00:00Z",
};

const TAG_RECORDS_PAGE: EntityRecordsPage = {
  items: [
    {
      record_id: "r1",
      field_values: { name: "security", description: "Security tag" },
      deleted: false,
      entity_def_version: "v1",
      last_event_global_seq: 1,
    },
    {
      record_id: "r2",
      field_values: { name: "safety", description: "Safety tag" },
      deleted: false,
      entity_def_version: "v1",
      last_event_global_seq: 2,
    },
  ],
  next_cursor: null,
};

function successMocks() {
  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] };
    // REQ-384 §7.1: keys are tenant-prefixed:
    // ['tenant', tenantId, 'entities', 'definition'|'browser', ...]
    if (queryKey[3] === "definition") {
      return {
        data: TAG_DEFINITION,
        isLoading: false,
        isError: false,
        error: null,
        refetch: vi.fn(),
      } as unknown as ReturnType<typeof useQuery>;
    }
    return {
      data: TAG_RECORDS_PAGE,
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>;
  });
}

function renderEntityListPage(entityType = "tag") {
  return render(
    <MemoryRouter initialEntries={[`/entities/${entityType}`]}>
      <Routes>
        <Route
          path="/entities/:entityType"
          element={<EntityListBrowserPage />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

// ── EntityFilterBuilder ────────────────────────────────────────────────────────

describe("REQ-393 — EntityFilterBuilder", () => {
  it("TC-EFB-01: renders empty state with Add filter button and no filter rows", () => {
    render(
      <EntityFilterBuilder
        fields={TAG_QUERIED_FIELDS}
        rows={[]}
        onChange={vi.fn()}
      />,
    );
    expect(screen.getByTestId("entity-filter-builder")).toBeInTheDocument();
    expect(screen.queryAllByTestId("filter-row")).toHaveLength(0);
    const addBtn = screen.getByTestId("filter-add");
    expect(addBtn).toBeInTheDocument();
    // "Add filter" is enabled when queried fields exist
    expect(addBtn).not.toBeDisabled();
  });

  it("TC-EFB-02: Add filter button calls onChange with one new row appended", () => {
    const onChange = vi.fn();
    render(
      <EntityFilterBuilder
        fields={TAG_QUERIED_FIELDS}
        rows={[]}
        onChange={onChange}
      />,
    );
    fireEvent.click(screen.getByTestId("filter-add"));
    expect(onChange).toHaveBeenCalledTimes(1);
    const [newRows] = onChange.mock.calls[0] as [FilterRow[]];
    expect(newRows).toHaveLength(1);
    expect(newRows[0].field).toBe("name"); // first queried field
    expect(typeof newRows[0].id).toBe("string");
    expect(newRows[0].id.length).toBeGreaterThan(0);
    expect(newRows[0].value).toBe("");
  });

  it("TC-EFB-03: remove button calls onChange without the removed row", () => {
    const onChange = vi.fn();
    const existingRow: FilterRow = {
      id: "row-keep",
      field: "name",
      op: "eq",
      value: "x",
    };
    const toRemove: FilterRow = {
      id: "row-remove",
      field: "description",
      op: "contains",
      value: "y",
    };
    render(
      <EntityFilterBuilder
        fields={TAG_QUERIED_FIELDS}
        rows={[existingRow, toRemove]}
        onChange={onChange}
      />,
    );
    expect(screen.getAllByTestId("filter-row")).toHaveLength(2);

    // Remove buttons are rendered in row order; click the second (toRemove)
    const removeBtns = screen.getAllByTestId("filter-remove");
    fireEvent.click(removeBtns[1]);

    expect(onChange).toHaveBeenCalledTimes(1);
    const [newRows] = onChange.mock.calls[0] as [FilterRow[]];
    expect(newRows).toHaveLength(1);
    expect(newRows[0].id).toBe("row-keep");
  });

  it("TC-EFB-04: changing value and op on a row propagates the update via onChange", () => {
    const onChange = vi.fn();
    const existingRow: FilterRow = {
      id: "row-1",
      field: "name",
      op: "eq",
      value: "",
    };
    render(
      <EntityFilterBuilder
        fields={TAG_QUERIED_FIELDS}
        rows={[existingRow]}
        onChange={onChange}
      />,
    );

    // Change the value input
    fireEvent.change(screen.getByTestId("filter-value"), {
      target: { value: "security" },
    });
    const callsAfterValue = onChange.mock.calls.length;
    const [afterValue] = onChange.mock.calls[callsAfterValue - 1] as [
      FilterRow[],
    ];
    expect(afterValue[0].value).toBe("security");

    // Change the op selector
    onChange.mockClear();
    fireEvent.change(screen.getByTestId("filter-op"), {
      target: { value: "contains" },
    });
    const [afterOp] = onChange.mock.calls[0] as [FilterRow[]];
    expect(afterOp[0].op).toBe("contains");
  });
});

// ── EntityListBrowserPage ──────────────────────────────────────────────────────

describe("REQ-393 — EntityListBrowserPage", () => {
  it('TC-ELBP-01: definition loading state renders SkeletonLayout with aria-busy="true"', () => {
    mockUseQuery.mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useQuery>);

    renderEntityListPage();

    expect(screen.getByLabelText("Loading content")).toHaveAttribute(
      "aria-busy",
      "true",
    );
  });

  it("TC-ELBP-02: records 422 surfaces as query-error-banner with the API message; no page-size-error", () => {
    // client.ts maps RFC 9457 body: title→message, body→details (whole body)
    // so details.detail carries the field-level error text
    const apiError = {
      message: "Unprocessable Entity",
      status: 422,
      code: "422",
      details: {
        detail: 'field is not queryable: "internal_note"',
        title: "Unprocessable Entity",
      },
    };
    mockUseQuery.mockImplementation((opts: unknown) => {
      const { queryKey } = opts as { queryKey: readonly unknown[] };
      if (queryKey[3] === "definition") {
        return {
          data: TAG_DEFINITION,
          isLoading: false,
          isError: false,
          error: null,
          refetch: vi.fn(),
        } as unknown as ReturnType<typeof useQuery>;
      }
      return {
        data: undefined,
        isLoading: false,
        isError: true,
        error: apiError,
        refetch: vi.fn(),
      } as unknown as ReturnType<typeof useQuery>;
    });

    renderEntityListPage();

    const banner = screen.getByTestId("query-error-banner");
    expect(banner).toBeInTheDocument();
    expect(banner.textContent).toContain("internal_note");
    expect(screen.queryByTestId("page-size-error")).not.toBeInTheDocument();
  });

  it("TC-ELBP-03: records 400 surfaces as page-size-error; query-error-banner is absent", () => {
    const apiError = {
      message: "page_size_too_large: requested 999, maximum is 200",
      status: 400,
    };
    mockUseQuery.mockImplementation((opts: unknown) => {
      const { queryKey } = opts as { queryKey: readonly unknown[] };
      if (queryKey[3] === "definition") {
        return {
          data: TAG_DEFINITION,
          isLoading: false,
          isError: false,
          error: null,
          refetch: vi.fn(),
        } as unknown as ReturnType<typeof useQuery>;
      }
      return {
        data: undefined,
        isLoading: false,
        isError: true,
        error: apiError,
        refetch: vi.fn(),
      } as unknown as ReturnType<typeof useQuery>;
    });

    renderEntityListPage();

    const pageSizeError = screen.getByTestId("page-size-error");
    expect(pageSizeError).toBeInTheDocument();
    expect(pageSizeError.textContent).toContain("200");
    expect(screen.queryByTestId("query-error-banner")).not.toBeInTheDocument();
  });

  it("TC-ELBP-04: successful query renders column headers from the definition and row data", () => {
    successMocks();
    renderEntityListPage();

    // Column headers derived from entity definition fields (via data-testid on each th)
    expect(screen.getByTestId("datatable-header-name")).toBeInTheDocument();
    expect(
      screen.getByTestId("datatable-header-description"),
    ).toBeInTheDocument();

    // Row cell values from TAG_RECORDS_PAGE items
    const nameCells = screen.getAllByTestId("datatable-cell-name");
    expect(nameCells.some((el) => el.textContent === "security")).toBe(true);
    expect(nameCells.some((el) => el.textContent === "safety")).toBe(true);
  });
});
