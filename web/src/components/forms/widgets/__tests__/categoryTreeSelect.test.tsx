// @vitest-environment jsdom
/**
 * REQ-586 part D -- the category tree picker (`entity-category-tree`).
 * Only the transport (entitiesApi.queryRecords) is mocked.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, fireEvent } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
expect.extend(jestDomMatchers)

import { categoryTreeSelectRenderer, buildCategoryTree } from '../categoryTreeSelect'
import { entitiesApi } from '@/api/entities'
import { entitiesMessages, ENTITIES_UI_LOCALES } from '@/i18n/entitiesMessages'
import { entityFieldToFormField } from '@/utils/entityFieldToFormField'
import { ENTITY_CATEGORY_TREE_WIDGET, ENTITY_FK_REFERENCE_WIDGET } from '@/components/entities/entityWidgetRegistry'
import type { EntityRecord } from '@/types/api'
import type { TaskFormField } from '@/types/forms'

function cat(id: string, name: string, sort: number, parent: string | null = null): EntityRecord {
  return {
    record_id: id,
    field_values: { name: { kk: `${name}-kk`, ru: `${name}-ru`, en: name }, sort_order: sort, parent_id: parent },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

// Deliberately shuffled: sort_order, not arrival order, decides sibling order.
const RECORDS: EntityRecord[] = [
  cat('c-grand', 'Grandchild', 1, 'c-child-a'),
  cat('c-root-b', 'RootB', 2),
  cat('c-child-b', 'ChildB', 2, 'c-root-a'),
  cat('c-root-a', 'RootA', 1),
  cat('c-child-a', 'ChildA', 1, 'c-root-a'),
]

const fieldDef: TaskFormField = {
  name: 'parent_id',
  type: 'string',
  required: false,
  xUiWidget: ENTITY_CATEGORY_TREE_WIDGET,
  referencesEntity: 'category',
}

function mount(locale: 'kk' | 'ru' | 'en', onChange = vi.fn(), def: TaskFormField = fieldDef) {
  const register = { name: 'parent_id', ref: vi.fn(), onChange, onBlur: vi.fn() }
  render(
    <IntlProvider locale={locale} messages={entitiesMessages[locale]}>
      {categoryTreeSelectRenderer.renderInput({ fieldName: 'parent_id', fieldDef: def, register })}
    </IntlProvider>,
  )
  return onChange
}

beforeEach(() => {
  vi.spyOn(entitiesApi, 'queryRecords').mockResolvedValue({ items: RECORDS, next_cursor: null })
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('REQ-586 D -- buildCategoryTree', () => {
  it('T1 orders siblings by sort_order and nests three levels', () => {
    expect(buildCategoryTree(RECORDS, 'en').map((n) => [n.label, n.depth])).toEqual([
      ['RootA', 0],
      ['ChildA', 1],
      ['Grandchild', 2],
      ['ChildB', 1],
      ['RootB', 0],
    ])
  })

  it('T2 excluding a record drops it and all its descendants', () => {
    expect(buildCategoryTree(RECORDS, 'en', 'c-child-a').map((n) => n.label)).toEqual(['RootA', 'ChildB', 'RootB'])
  })
})

describe('REQ-586 D -- widget', () => {
  it('T3 renders the indented tree in sort_order', async () => {
    mount('en')
    await screen.findByTestId('category-tree-node-c-grand')
    const nodes = screen.getAllByRole('option').filter((o) => o.getAttribute('data-depth') !== null)
    expect(nodes.map((o) => [o.textContent, o.getAttribute('data-depth')])).toEqual([
      ['RootA', '0'],
      ['ChildA', '1'],
      ['Grandchild', '2'],
      ['ChildB', '1'],
      ['RootB', '0'],
    ])
    expect(screen.getByTestId('category-tree-node-c-grand')).toHaveStyle({ paddingLeft: '3.1rem' })
  })

  for (const locale of ENTITIES_UI_LOCALES) {
    it(`T4 ${locale}: labels come from the ${locale} catalog and the record names`, async () => {
      mount(locale as 'kk' | 'ru' | 'en')
      await screen.findByTestId('category-tree-node-c-root-a')
      expect(screen.getByTestId('category-tree')).toHaveAttribute(
        'aria-label',
        entitiesMessages[locale]['entities.widgets.categoryTree.label'],
      )
      expect(screen.getByTestId('category-tree-none')).toHaveTextContent(
        entitiesMessages[locale]['entities.widgets.categoryTree.noParent'],
      )
      expect(screen.getByTestId('category-tree-node-c-root-a')).toHaveTextContent(
        locale === 'en' ? 'RootA' : `RootA-${locale}`,
      )
    })
  }

  it('T5 choosing a node reports its record id', async () => {
    const onChange = mount('en')
    fireEvent.click(await screen.findByTestId('category-tree-node-c-child-b'))
    expect(onChange).toHaveBeenCalledWith({ target: { name: 'parent_id', value: 'c-child-b' }, type: 'change' })
    expect(screen.getByTestId('category-tree-node-c-child-b')).toHaveAttribute('aria-selected', 'true')
  })

  it('T6 "no parent" reports null', async () => {
    const onChange = mount('en')
    await screen.findByTestId('category-tree-node-c-root-a')
    fireEvent.click(screen.getByTestId('category-tree-node-c-root-a'))
    fireEvent.click(screen.getByTestId('category-tree-none'))
    expect(onChange).toHaveBeenLastCalledWith({ target: { name: 'parent_id', value: null }, type: 'change' })
  })

  it('T7 editing hides the record itself and its descendants', async () => {
    mount('en', vi.fn(), { ...fieldDef, editingRecordId: 'c-child-a' })
    await screen.findByTestId('category-tree-node-c-root-a')
    expect(screen.queryByTestId('category-tree-node-c-child-a')).toBeNull()
    expect(screen.queryByTestId('category-tree-node-c-grand')).toBeNull()
    expect(screen.getByTestId('category-tree-node-c-child-b')).toBeInTheDocument()
  })
})

describe('REQ-586 D -- routing', () => {
  const parentField = { name: 'parent_id', type: 'string' as const, required: false }
  const fk = { name: 'fk_x_parent_id', field: 'parent_id', references_entity: 'x' }

  it('T8 category.parent_id routes to the tree, question.parent_id stays the fk reference', () => {
    expect(
      entityFieldToFormField(parentField, { ...fk, references_entity: 'category' }, { entityType: 'category', editingRecordId: 'r1' }),
    ).toMatchObject({ xUiWidget: ENTITY_CATEGORY_TREE_WIDGET, editingRecordId: 'r1' })
    expect(
      entityFieldToFormField(parentField, { ...fk, references_entity: 'question' }, { entityType: 'question' }).xUiWidget,
    ).toBe(ENTITY_FK_REFERENCE_WIDGET)
  })
})
