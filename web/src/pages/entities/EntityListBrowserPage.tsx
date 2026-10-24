/** EntityListBrowserPage — REQ-393
 *
 *  Tenant-agnostic entity-list browse screen: filter builder, sort control,
 *  page-size control, and cursor-paginated results table. Wired to
 *  `POST /entities/query` via `entitiesApi.queryRecords`.
 *
 *  Design: lib/letflow/design/req393-entity-list-query-ui.md
 *
 *  KEY INVARIANTS:
 *  - SortClause field is `dir`, not `direction` (api.ts:352).
 *  - DataTable columns have sortable: false (server-driven sort only).
 *  - Filter builder shows only fields with queried === true.
 *  - 422 (field_not_allowed) and 400 (page_size_too_large) are surfaced
 *    as inline messages, NOT toasts.
 *  - tenantId is resolved internally via useTenantScopedQueryKeys (not a prop).
 *  - Query fires on explicit "Search" button press, not on every keystroke.
 */

import { useMemo, useState, useEffect } from "react";
import { useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { entitiesApi } from "@/api/entities";
import { useTenantScopedQueryKeys } from "@/api/useTenantScopedQueryKeys";
import type {
  ApiError,
  EntityFieldDef,
  EntityQueryFilterClause,
  EntityQuerySortClause,
} from "@/types/api";
import { classifyError } from "@/utils/classifyError";
import { PageLayout } from "@/components/ui/PageLayout";
import { DataTable, type DataTableColumn } from "@/components/ui/DataTable";
import { PaginationControls } from "@/components/ui/PaginationControls";
import { QueryStateBoundary } from "@/components/ui/QueryStateBoundary";
import {
  EntityFilterBuilder,
  type FilterRow,
} from "@/components/entities/EntityFilterBuilder";

// ── local state helpers ────────────────────────────────────────────────────────

interface SortControl {
  field: string | null;
  dir: "asc" | "desc";
}

/** Coerce a filter row's string value to the typed value the API expects. */
function coerceValue(
  row: FilterRow,
  fieldDef: EntityFieldDef | undefined,
): unknown {
  const { op, value } = row;
  if (op === "is_null" || op === "is_not_null") return undefined;
  if (!fieldDef) return value;

  if (op === "in" || op === "not_in") {
    const items = value.split(",").map((s) => s.trim());
    return items.map((item) => coerceSingle(item, fieldDef));
  }
  return coerceSingle(value, fieldDef);
}

function coerceSingle(raw: string, field: EntityFieldDef): unknown {
  if (field.type === "boolean") return raw.trim().toLowerCase() === "true";
  if (field.type === "integer") {
    const n = parseInt(raw, 10);
    return isNaN(n) ? undefined : n;
  }
  if (field.type === "decimal") {
    const n = parseFloat(raw);
    return isNaN(n) ? undefined : n;
  }
  return raw;
}

/** Build the `EntityQueryFilterClause[]` sent to the API from the UI rows. */
function buildFilters(
  rows: FilterRow[],
  fields: EntityFieldDef[],
): EntityQueryFilterClause[] {
  const result: EntityQueryFilterClause[] = [];
  for (const row of rows) {
    if (!row.field) continue;
    const fieldDef = fields.find((f) => f.name === row.field);
    const op = row.op as EntityQueryFilterClause["op"];
    const coerced = coerceValue(row, fieldDef);
    if (op === "is_null" || op === "is_not_null") {
      result.push({ field: row.field, op });
    } else if (coerced !== undefined) {
      result.push({ field: row.field, op, value: coerced });
    }
  }
  return result;
}

function extractMessage(err: unknown): string {
  if (err && typeof err === "object") {
    const e = err as ApiError;
    // RFC 9457: human-readable detail is in details.detail; message is just the title
    const detail = e.details?.["detail"];
    if (typeof detail === "string" && detail.length > 0) return detail;
    if ("message" in e && typeof e.message === "string" && e.message.length > 0)
      return e.message;
  }
  return "An error occurred";
}

// ── component ─────────────────────────────────────────────────────────────────

// Server maximum is 200 (Pagination.max_page_size/0); never offer more.
export const PAGE_SIZE_OPTIONS = [25, 50, 100, 200] as const;

export function EntityListBrowserPage(): React.ReactElement {
  const { entityType } = useParams<{ entityType: string }>();
  const safeEntityType = entityType ?? "";

  const tenantKeys = useTenantScopedQueryKeys();

  // ── filter / sort / page-size controls ──────────────────────────────────────
  const [filterRows, setFilterRows] = useState<FilterRow[]>([]);
  const [sort, setSort] = useState<SortControl>({ field: null, dir: "asc" });
  const [pageSize, setPageSize] = useState<number>(25);

  // ── pagination cursor stack ──────────────────────────────────────────────────
  const [cursorStack, setCursorStack] = useState<string[]>([]);
  const cursor =
    cursorStack.length > 0 ? cursorStack[cursorStack.length - 1] : undefined;

  // ── committed query params (only updated on Search press) ───────────────────
  const [committedFilters, setCommittedFilters] = useState<
    EntityQueryFilterClause[]
  >([]);
  const [committedSort, setCommittedSort] = useState<EntityQuerySortClause[]>(
    [],
  );
  const [committedPageSize, setCommittedPageSize] = useState<number>(25);
  const [pageSizeError, setPageSizeError] = useState<string | null>(null);
  const [queryError, setQueryError] = useState<string | null>(null);

  // ── entity definition fetch ──────────────────────────────────────────────────
  const definitionQuery = useQuery({
    queryKey: tenantKeys.entities.definition(safeEntityType),
    queryFn: () => entitiesApi.getActiveDefinition(safeEntityType),
    enabled: safeEntityType.length > 0,
  });

  const definition = definitionQuery.data;
  const fields: EntityFieldDef[] = useMemo(
    () => definition?.definition.fields ?? [],
    [definition],
  );

  // ── records query — fires with committed params ──────────────────────────────
  const recordsQuery = useQuery({
    queryKey: tenantKeys.entities.browserRecords(safeEntityType, {
      filters: committedFilters,
      sort: committedSort,
      pageSize: committedPageSize,
      cursor,
    }),
    queryFn: () =>
      entitiesApi.queryRecords(safeEntityType, {
        filters: committedFilters.length > 0 ? committedFilters : undefined,
        sort: committedSort.length > 0 ? committedSort : undefined,
        page_size: committedPageSize,
        cursor,
      }),
    enabled: safeEntityType.length > 0,
    retry: false,
  });

  // surface API errors as inline messages instead of QueryStateBoundary fallbacks
  const recordsError = recordsQuery.error as ApiError | null | undefined;
  useEffect(() => {
    if (!recordsError) {
      setQueryError(null);
      setPageSizeError(null);
      return;
    }
    const msg = extractMessage(recordsError);
    if (recordsError.status === 400) {
      setPageSizeError(
        "Page size is too large (maximum: 200). Choose a smaller value.",
      );
      setQueryError(null);
    } else {
      setQueryError(msg);
      setPageSizeError(null);
    }
  }, [recordsError]);

  // ── table columns ────────────────────────────────────────────────────────────
  const columns: DataTableColumn<Record<string, unknown>>[] = useMemo(() => {
    if (fields.length === 0)
      return [
        {
          id: "record_id",
          header: "ID",
          accessor: (r) => String(r["record_id"] ?? ""),
          sortable: false,
        },
      ];
    return fields.map((f) => ({
      id: f.name,
      header: f.name,
      accessor: (r: Record<string, unknown>) => {
        const fv = r["field_values"] as Record<string, unknown> | undefined;
        const val = fv?.[f.name];
        if (val == null) return "";
        if (f.type === "localized_text" && typeof val === "object") {
          const byLocale = val as Record<string, unknown>;
          const first = Object.values(byLocale).find(
            (v) => typeof v === "string" && (v as string).length > 0,
          );
          return typeof first === "string" ? first : "";
        }
        if (f.type === "boolean") return val ? "Yes" : "No";
        return String(val);
      },
      sortable: false,
    }));
  }, [fields]);

  const rows = useMemo(
    () =>
      (recordsQuery.data?.items ?? []) as unknown as Record<string, unknown>[],
    [recordsQuery.data],
  );

  // ── pagination ───────────────────────────────────────────────────────────────
  const hasNextPage = recordsQuery.data?.next_cursor != null;
  const page = cursorStack.length + 1;

  const goNext = () => {
    if (!recordsQuery.data?.next_cursor) return;
    setCursorStack((prev) => [
      ...prev,
      recordsQuery.data!.next_cursor as string,
    ]);
  };
  const goPrev = () => setCursorStack((prev) => prev.slice(0, -1));

  // ── search handler ───────────────────────────────────────────────────────────
  const handleSearch = () => {
    const filters = buildFilters(filterRows, fields);
    const sortClauses: EntityQuerySortClause[] = sort.field
      ? [{ field: sort.field, dir: sort.dir }]
      : [];
    // reset to page 1 whenever committed params change
    setCursorStack([]);
    setCommittedFilters(filters);
    setCommittedSort(sortClauses);
    setCommittedPageSize(pageSize);
  };

  const defState = definitionQuery.isLoading
    ? "loading"
    : definitionQuery.isError
      ? classifyError(definitionQuery.error)
      : "success";

  const inputStyle: React.CSSProperties = {
    border: "1px solid var(--border-default)",
    borderRadius: "var(--radius-sm)",
    padding: "var(--space-1) var(--space-2)",
    background: "var(--surface-card)",
    color: "var(--text-primary)",
  };

  const sectionStyle: React.CSSProperties = {
    display: "flex",
    flexDirection: "column",
    gap: "var(--space-3)",
    padding: "var(--space-4)",
    border: "1px solid var(--border-default)",
    borderRadius: "var(--radius-md)",
    background: "var(--surface-card)",
  };

  const errorBannerStyle: React.CSSProperties = {
    color: "var(--color-error-dark)",
    padding: "var(--space-2) var(--space-3)",
    border: "1px solid var(--border-error)",
    borderRadius: "var(--radius-sm)",
    background: "var(--color-error-light)",
  };

  return (
    <PageLayout title={`Browse: ${safeEntityType}`}>
      {/* Definition loading boundary */}
      <QueryStateBoundary
        state={defState}
        onRetry={() => void definitionQuery.refetch()}
      >
        {/* Filter builder */}
        <div style={sectionStyle} data-testid="filter-section">
          <strong>Filters</strong>
          <EntityFilterBuilder
            fields={fields}
            rows={filterRows}
            onChange={setFilterRows}
          />
        </div>

        {/* Sort control */}
        <div
          style={{
            display: "flex",
            gap: "var(--space-3)",
            alignItems: "center",
          }}
          data-testid="sort-section"
        >
          <label htmlFor="sort-field">Sort by</label>
          <select
            id="sort-field"
            style={inputStyle}
            value={sort.field ?? ""}
            onChange={(e) =>
              setSort((s) => ({ ...s, field: e.target.value || null }))
            }
            data-testid="sort-field"
          >
            <option value="">(none)</option>
            {fields.map((f) => (
              <option key={f.name} value={f.name}>
                {f.name}
              </option>
            ))}
          </select>
          <select
            id="sort-dir"
            style={inputStyle}
            value={sort.dir}
            onChange={(e) =>
              setSort((s) => ({ ...s, dir: e.target.value as "asc" | "desc" }))
            }
            data-testid="sort-dir"
          >
            <option value="asc">Ascending</option>
            <option value="desc">Descending</option>
          </select>
        </div>

        {/* Page-size control */}
        <div
          style={{
            display: "flex",
            gap: "var(--space-3)",
            alignItems: "center",
          }}
          data-testid="page-size-section"
        >
          <label htmlFor="page-size">Page size</label>
          <select
            id="page-size"
            style={inputStyle}
            value={pageSize}
            onChange={(e) => setPageSize(Number(e.target.value))}
            data-testid="page-size"
          >
            {PAGE_SIZE_OPTIONS.map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
          {pageSizeError && (
            <span
              style={{ color: "var(--color-error-dark)" }}
              data-testid="page-size-error"
            >
              {pageSizeError}
            </span>
          )}
        </div>

        {/* Search button */}
        <div>
          <button
            onClick={handleSearch}
            disabled={recordsQuery.isLoading}
            data-testid="search-button"
            style={{
              padding: "var(--space-2) var(--space-4)",
              background: "var(--interactive-primary)",
              color: "var(--text-inverse)",
              border: "none",
              borderRadius: "var(--radius-sm)",
              cursor: recordsQuery.isLoading ? "not-allowed" : "pointer",
            }}
          >
            {recordsQuery.isLoading ? "Searching…" : "Search"}
          </button>
        </div>

        {/* Query error banner */}
        {queryError && (
          <div style={errorBannerStyle} data-testid="query-error-banner">
            {queryError}
          </div>
        )}

        {/* Results table — wrapped in its own boundary */}
        <QueryStateBoundary
          state={
            recordsQuery.isLoading
              ? "loading"
              : recordsQuery.isError && !queryError && !pageSizeError
                ? classifyError(recordsQuery.error)
                : "success"
          }
          onRetry={() => void recordsQuery.refetch()}
        >
          <DataTable<Record<string, unknown>>
            columns={columns}
            data={rows}
            isLoading={recordsQuery.isLoading}
            emptyMessage="No records found."
          />

          <PaginationControls
            page={page}
            pageSize={committedPageSize}
            totalItems={null}
            hasNextPage={hasNextPage}
            onPageChange={(p) => {
              if (p < page) goPrev();
              else goNext();
            }}
          />
        </QueryStateBoundary>
      </QueryStateBoundary>
    </PageLayout>
  );
}

export default EntityListBrowserPage;
