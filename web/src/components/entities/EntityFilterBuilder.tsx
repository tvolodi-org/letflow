/** EntityFilterBuilder — REQ-393
 *
 *  Renders a list of filter rows (field / operator / value) and an "Add
 *  filter" button. Only fields with `queried === true` appear in the field
 *  selector. Operators are filtered by field type per §4.3 of the design.
 *  The value input is hidden for `is_null` / `is_not_null` ops.
 *
 *  This component is purely presentational — it holds no query state; the
 *  parent (EntityListBrowserPage) owns the rows array and onChange callback.
 */

import React from 'react'
import { Button } from '@/components/ui/Button'
import type { EntityFieldDef, EntityQueryFilterClause } from '@/types/api'

export interface FilterRow {
  id: string
  field: string
  op: EntityQueryFilterClause['op']
  value: string
}

export interface EntityFilterBuilderProps {
  fields: EntityFieldDef[]
  rows: FilterRow[]
  onChange: (rows: FilterRow[]) => void
}

type Op = EntityQueryFilterClause['op']

const ALL_OPS: Op[] = ['eq', 'ne', 'contains', 'lt', 'lte', 'gt', 'gte', 'in', 'not_in', 'is_null', 'is_not_null']

const OP_LABELS: Record<Op, string> = {
  eq: '=',
  ne: '≠',
  contains: 'contains',
  lt: '<',
  lte: '≤',
  gt: '>',
  gte: '≥',
  in: 'in',
  not_in: 'not in',
  is_null: 'is null',
  is_not_null: 'is not null',
}

function opsForField(field: EntityFieldDef): Op[] {
  switch (field.type) {
    case 'string':
    case 'localized_text':
      return ['eq', 'ne', 'contains', 'is_null', 'is_not_null']
    case 'integer':
    case 'decimal':
    case 'date':
    case 'datetime':
      return ['eq', 'ne', 'lt', 'lte', 'gt', 'gte', 'is_null', 'is_not_null']
    case 'boolean':
      return ['eq', 'ne']
    case 'enum':
      return ['eq', 'ne', 'in', 'not_in']
    case 'json':
      return ['eq', 'is_null', 'is_not_null']
    default:
      return ALL_OPS
  }
}

const NO_VALUE_OPS: Op[] = ['is_null', 'is_not_null']

function newRow(field: EntityFieldDef, availableOps: Op[]): FilterRow {
  return {
    id: crypto.randomUUID(),
    field: field.name,
    op: availableOps[0] ?? 'eq',
    value: '',
  }
}

export function EntityFilterBuilder({ fields, rows, onChange }: EntityFilterBuilderProps): React.ReactElement {
  const queriedFields = fields.filter((f) => f.queried === true)

  const updateRow = (id: string, patch: Partial<FilterRow>) => {
    onChange(
      rows.map((r) => {
        if (r.id !== id) return r
        const updated = { ...r, ...patch }
        // reset op when field changes if current op isn't valid for new field
        if (patch.field !== undefined) {
          const newField = queriedFields.find((f) => f.name === patch.field)
          if (newField) {
            const ops = opsForField(newField)
            if (!ops.includes(updated.op)) updated.op = ops[0] ?? 'eq'
          }
        }
        return updated
      }),
    )
  }

  const removeRow = (id: string) => onChange(rows.filter((r) => r.id !== id))

  const addRow = () => {
    if (queriedFields.length === 0) return
    const first = queriedFields[0]
    onChange([...rows, newRow(first, opsForField(first))])
  }

  const containerStyle: React.CSSProperties = {
    display: 'flex',
    flexDirection: 'column',
    gap: 'var(--space-2)',
  }

  const rowStyle: React.CSSProperties = {
    display: 'flex',
    gap: 'var(--space-2)',
    alignItems: 'center',
  }

  const selectStyle: React.CSSProperties = {
    border: '1px solid var(--border-default)',
    borderRadius: 'var(--radius-sm)',
    padding: 'var(--space-1) var(--space-2)',
    background: 'var(--surface-card)',
    color: 'var(--text-primary)',
  }

  const inputStyle: React.CSSProperties = { ...selectStyle, flex: 1 }

  return (
    <div data-testid="entity-filter-builder" style={containerStyle}>
      {rows.map((row) => {
        const fieldDef = queriedFields.find((f) => f.name === row.field) ?? queriedFields[0]
        const ops = fieldDef ? opsForField(fieldDef) : ALL_OPS
        const hideValue = NO_VALUE_OPS.includes(row.op)

        return (
          <div key={row.id} style={rowStyle} data-testid="filter-row">
            {/* Field selector */}
            <select
              style={{ ...selectStyle, width: '35%' }}
              value={row.field}
              onChange={(e) => updateRow(row.id, { field: e.target.value })}
              data-testid="filter-field"
            >
              {queriedFields.map((f) => (
                <option key={f.name} value={f.name}>
                  {f.name}
                </option>
              ))}
            </select>

            {/* Operator selector */}
            <select
              style={{ ...selectStyle, width: '25%' }}
              value={row.op}
              onChange={(e) => updateRow(row.id, { op: e.target.value as Op })}
              data-testid="filter-op"
            >
              {ops.map((op) => (
                <option key={op} value={op}>
                  {OP_LABELS[op]}
                </option>
              ))}
            </select>

            {/* Value input — hidden for is_null / is_not_null */}
            {!hideValue && (
              <input
                style={inputStyle}
                type="text"
                placeholder={fieldDef?.type === 'boolean' ? 'true / false' : 'value'}
                value={row.value}
                onChange={(e) => updateRow(row.id, { value: e.target.value })}
                data-testid="filter-value"
              />
            )}
            {hideValue && <span style={{ flex: 1 }} />}

            <Button variant="ghost" size="sm" onClick={() => removeRow(row.id)} data-testid="filter-remove">
              ✕
            </Button>
          </div>
        )
      })}

      <div>
        <Button
          variant="secondary"
          size="sm"
          onClick={addRow}
          disabled={queriedFields.length === 0}
          data-testid="filter-add"
        >
          Add filter
        </Button>
      </div>
    </div>
  )
}
