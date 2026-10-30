/** Filter-row helpers shared by the list browser and the report builder (REQ-556, REQ-634). */

import type { EntityFieldDef, EntityQueryFilterClause } from '@/types/api'
import type { FilterRow } from '@/components/entities/EntityFilterBuilder'

/** Coerce a filter row's string value to the typed value the API expects. */
export function coerceValue(
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

export function coerceSingle(raw: string, field: EntityFieldDef): unknown {
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
export function buildFilters(
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

/** A stored clause value shown in the filter builder's text input (inverse of coerceValue). */
export function valueToText(value: unknown): string {
  if (value == null) return "";
  if (Array.isArray(value)) return value.map((v) => String(v)).join(",");
  return String(value);
}

export function toFilterRow(c: EntityQueryFilterClause): FilterRow {
  return {
    id: crypto.randomUUID(),
    field: c.field,
    op: c.op,
    value: valueToText(c.value),
  };
}
