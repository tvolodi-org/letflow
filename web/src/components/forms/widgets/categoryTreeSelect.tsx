/**
 * REQ-586 part D — `entity-category-tree` widget: the parent picker for
 * `category.parent_id`.
 *
 * `category.parent_id` is a self-referencing fk (`references_entity:
 * "category"`), so the generic `entityReferenceSelectRenderer` would offer a
 * flat, searchable list. A category tree is hierarchical, so this widget
 * loads the tenant's live categories through the same `POST /entities/query`
 * route, builds the tree from each record's own `parent_id`, and shows it
 * indented, siblings ordered by `sort_order`. Choosing a node reports its
 * `record_id`; the "no parent" row reports `null` (root of the tree).
 *
 * When editing, the record itself and all its descendants are left out of
 * the list: offering them would only produce a `parent_cycle` refusal from
 * the authoring write rule, which stays the authority (this is a convenience,
 * not the guard). `question.parent_id` is NOT routed here; it keeps
 * `entityReferenceSelectRenderer`.
 */

import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { useIntl } from 'react-intl'
import { entitiesApi } from '@/api/entities'
import type { EntityRecord } from '@/types/api'
import type { FieldTypeRenderer, RenderInputArgs } from '../fieldRegistry'

const CATEGORY_ENTITY = 'category'
const PAGE_SIZE = 200
const MAX_PAGES = 10

const listboxStyles: CSSProperties = {
  listStyle: 'none',
  margin: '.25rem 0 0 0',
  padding: 0,
  border: '1px solid var(--color-neutral-400)',
  borderRadius: '4px',
  maxHeight: '14rem',
  overflowY: 'auto',
}

export interface CategoryTreeNode {
  recordId: string
  label: string
  depth: number
}

function labelOf(value: unknown, preferredLocale: string): string {
  if (typeof value === 'string') return value
  if (value && typeof value === 'object') {
    const byLocale = value as Record<string, unknown>
    const preferred = byLocale[preferredLocale]
    if (typeof preferred === 'string' && preferred.trim() !== '') return preferred
    for (const candidate of Object.values(byLocale)) {
      if (typeof candidate === 'string' && candidate.trim() !== '') return candidate
    }
  }
  return ''
}

function sortOrderOf(record: EntityRecord): number {
  const raw = record.field_values.sort_order
  return typeof raw === 'number' ? raw : 0
}

/** Depth-first flattening of the category forest. Siblings are ordered by
 *  `sort_order` (ties by label, then record_id, so the order is stable).
 *  A record whose parent is absent from `records` is treated as a root.
 *  `excludeRecordId`, if given, drops that record and its whole subtree. */
export function buildCategoryTree(
  records: EntityRecord[],
  locale: string,
  excludeRecordId?: string,
): CategoryTreeNode[] {
  const ids = new Set(records.map((r) => r.record_id))
  const childrenOf = new Map<string | null, EntityRecord[]>()
  for (const record of records) {
    const rawParent = record.field_values.parent_id
    const parent = typeof rawParent === 'string' && rawParent !== '' && ids.has(rawParent) ? rawParent : null
    const siblings = childrenOf.get(parent) ?? []
    siblings.push(record)
    childrenOf.set(parent, siblings)
  }

  const labels = new Map(records.map((r) => [r.record_id, labelOf(r.field_values.name, locale) || r.record_id]))
  const out: CategoryTreeNode[] = []
  const visited = new Set<string>()

  const walk = (parent: string | null, depth: number): void => {
    const siblings = [...(childrenOf.get(parent) ?? [])].sort(
      (a, b) =>
        sortOrderOf(a) - sortOrderOf(b) ||
        (labels.get(a.record_id) ?? '').localeCompare(labels.get(b.record_id) ?? '') ||
        a.record_id.localeCompare(b.record_id),
    )
    for (const record of siblings) {
      if (record.record_id === excludeRecordId || visited.has(record.record_id)) continue
      visited.add(record.record_id)
      out.push({ recordId: record.record_id, label: labels.get(record.record_id) ?? record.record_id, depth })
      walk(record.record_id, depth + 1)
    }
  }
  walk(null, 0)
  return out
}

function CategoryTreeInput({ fieldName, fieldDef, register, ariaDescribedBy, ariaErrorMessage, ariaRequired }: RenderInputArgs) {
  const intl = useIntl()
  const hiddenRef = useRef<HTMLInputElement | null>(null)
  const [records, setRecords] = useState<EntityRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState<string | null>(null)

  // react-hook-form seeds the registered element from defaultValues when the
  // ref attaches; read the initial selection from there.
  useEffect(() => {
    setSelected(hiddenRef.current?.value ? hiddenRef.current.value : null)
  }, [])

  useEffect(() => {
    let cancelled = false
    const load = async (): Promise<void> => {
      const all: EntityRecord[] = []
      let cursor: string | undefined
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const result = await entitiesApi.queryRecords(CATEGORY_ENTITY, {
          filters: [{ field: 'deleted', op: 'eq', value: false }],
          sort: [{ field: 'sort_order', dir: 'asc' }],
          page_size: PAGE_SIZE,
          ...(cursor ? { cursor } : {}),
        })
        all.push(...result.items)
        if (!result.next_cursor) break
        cursor = result.next_cursor
      }
      if (!cancelled) setRecords(all)
    }
    load()
      .catch(() => {
        if (!cancelled) setRecords([])
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [])

  const nodes = useMemo(
    () => buildCategoryTree(records, intl.locale, fieldDef.editingRecordId),
    [records, intl.locale, fieldDef.editingRecordId],
  )

  const choose = (recordId: string | null): void => {
    setSelected(recordId)
    void register.onChange({ target: { name: fieldName, value: recordId }, type: 'change' })
  }

  const optionStyle = (isSelected: boolean, depth: number): CSSProperties => ({
    padding: '.4rem .6rem',
    paddingLeft: `${0.6 + depth * 1.25}rem`,
    cursor: 'pointer',
    background: isSelected ? 'var(--color-neutral-200)' : 'transparent',
  })

  return (
    <div>
      <input type="hidden" name={register.name} ref={(el) => { hiddenRef.current = el; register.ref(el) }} value={selected ?? ''} readOnly />
      <ul
        id={fieldName}
        role="listbox"
        aria-label={intl.formatMessage({ id: 'entities.widgets.categoryTree.label' })}
        aria-required={ariaRequired ? 'true' : undefined}
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaErrorMessage ? 'true' : undefined}
        aria-errormessage={ariaErrorMessage}
        data-testid="category-tree"
        style={listboxStyles}
      >
        <li
          role="option"
          aria-selected={selected === null}
          data-testid="category-tree-none"
          onClick={() => choose(null)}
          style={optionStyle(selected === null, 0)}
        >
          {intl.formatMessage({ id: 'entities.widgets.categoryTree.noParent' })}
        </li>
        {loading && (
          <li style={{ padding: '.4rem .6rem', color: 'var(--text-secondary)' }}>
            {intl.formatMessage({ id: 'entities.widgets.categoryTree.loading' })}
          </li>
        )}
        {nodes.map((node) => (
          <li
            key={node.recordId}
            role="option"
            aria-selected={selected === node.recordId}
            data-testid={`category-tree-node-${node.recordId}`}
            data-depth={node.depth}
            onClick={() => choose(node.recordId)}
            style={optionStyle(selected === node.recordId, node.depth)}
          >
            {node.label}
          </li>
        ))}
      </ul>
    </div>
  )
}

export const categoryTreeSelectRenderer: FieldTypeRenderer = {
  renderInput: (args) => <CategoryTreeInput {...args} />,
  requiredAriaAttributes: ['aria-required', 'aria-describedby', 'aria-invalid', 'aria-errormessage'],
}
