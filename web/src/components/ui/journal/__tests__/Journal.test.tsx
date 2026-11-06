// @vitest-environment jsdom
/** J1–J5 — T-1422 (GATE B R12): the generic journal: split layout, V1 default, V2 as an option, keys. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import {
  DEFAULT_JOURNAL_VARIANT, JOURNAL_LAYOUTS, JOURNAL_VARIANTS, Journal, JournalList, isJournalVariant,
  type JournalListProps, type JournalOp, type JournalVariant,
} from '..'

expect.extend(jestDomMatchers)
afterEach(cleanup)

const LEGS = { legs: 'Legs', heldBy: 'Held by', hiddenUnit: 'Hidden unit', change: 'Change' }
const op = (id: string): JournalOp => ({
  id, time: '04-11-2026 23:00', kind: 'receipt', kindLabel: 'Receipt', kindIcon: null, docText: `DOC-${id} - Receipt`, docHref: `/d/${id}`,
  item: 'ITM-1 - Bolt', itemMore: 0, qty: '5 pcs', qtySign: 'pos', status: 'posted', statusLabel: 'Posted', statusNote: '',
  legs: [{ id: '1', location: 'WH - Main', item: 'ITM-1 - Bolt', holder: '', qty: '5 pcs', sign: 'pos', hidden: false }],
})

function listProps(over: Partial<JournalListProps> = {}): JournalListProps {
  return {
    titleId: 't', variant: 'v1', state: 'ready', ops: [op('a'), op('b'), op('c')], selectedId: null, expandedId: null,
    onRow: vi.fn(), onToggleExpand: vi.fn(), onDetails: vi.fn(), filtersNode: <span />, filterCount: 0, filtersOpen: false,
    onToggleFilters: vi.fn(), onClearFilters: vi.fn(), filtered: false,
    empty: { title: 'Empty', text: 'e' }, noMatch: { title: 'No match', text: 'n' }, rangeText: 'Showing 3',
    labels: {
      title: 'Movements', filters: 'Filters', export: 'Export', details: 'Details', expand: 'Show legs', collapse: 'Hide legs',
      clearFilters: 'Clear', more: (n) => `+${n}`,
      columns: { date: 'Date', kind: 'Kind', doc: 'Doc', item: 'Item', qty: 'Qty', status: 'Status' }, legs: LEGS,
    },
    ...over,
  }
}

const shell = (variant?: JournalVariant, detailOpen = false, onClose?: () => void) => (
  <MemoryRouter>
    <Journal variant={variant} list={<JournalList {...listProps({ variant: variant ?? 'v1' })} />} details={<div />} detailOpen={detailOpen} filtersOpen={false} onClose={onClose} />
  </MemoryRouter>
)

describe('J1 layout and variant registry', () => {
  it('split layout, V1 default; V2 and V3 exist', () => {
    expect(Object.keys(JOURNAL_LAYOUTS)).toEqual(['split'])
    expect(DEFAULT_JOURNAL_VARIANT).toBe('v1')
    expect([...JOURNAL_VARIANTS]).toEqual(['v1', 'v2', 'v3'])
    expect(isJournalVariant('v2')).toBe(true)
    expect(isJournalVariant('v9')).toBe(false)
    render(shell())
    const j = screen.getByTestId('journal')
    expect(j).toHaveAttribute('data-layout', 'split')
    expect(j).toHaveAttribute('data-variant', 'v1')
    expect(j).toHaveAttribute('data-detail', 'closed')
  })
})

describe('J2 V1 inline legs', () => {
  it('has the expand button and aria-expanded; the legs row and Details button show when expanded', () => {
    const onToggle = vi.fn()
    const onDetails = vi.fn()
    render(
      <MemoryRouter>
        <JournalList {...listProps({ expandedId: 'a', onToggleExpand: onToggle, onDetails })} />
      </MemoryRouter>,
    )
    const rows = screen.getAllByTestId('journal-row')
    expect(rows[0]).toHaveAttribute('aria-expanded', 'true')
    expect(rows[1]).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getAllByTestId('journal-legsrow')).toHaveLength(1)
    fireEvent.click(screen.getAllByTestId('journal-expand')[1])
    expect(onToggle).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }))
    fireEvent.click(screen.getByTestId('journal-details-btn'))
    expect(onDetails).toHaveBeenCalledWith(expect.objectContaining({ id: 'a' }))
  })
})

describe('J4 V2 sheet is an option, not the default', () => {
  it('v2 sets the attribute and a scrim that closes; v1 has no scrim and no expand button in v2/v3', () => {
    const onClose = vi.fn()
    const { unmount } = render(shell('v2', true, onClose))
    expect(screen.getByTestId('journal')).toHaveAttribute('data-variant', 'v2')
    fireEvent.click(screen.getByTestId('journal-scrim'))
    expect(onClose).toHaveBeenCalled()
    expect(screen.queryByTestId('journal-expand')).not.toBeInTheDocument()
    unmount()
    render(shell())
    expect(screen.queryByTestId('journal-scrim')).not.toBeInTheDocument()
  })
})

describe('J5 keys', () => {
  it('Escape closes the open details; arrows move the roving focus; Enter selects', () => {
    const onClose = vi.fn()
    const onRow = vi.fn()
    render(
      <MemoryRouter>
        <Journal list={<JournalList {...listProps({ onRow })} />} details={<div />} detailOpen filtersOpen={false} onClose={onClose} />
      </MemoryRouter>,
    )
    const rows = screen.getAllByTestId('journal-row')
    expect(rows[0]).toHaveAttribute('tabindex', '0')
    expect(rows[1]).toHaveAttribute('tabindex', '-1')
    rows[0].focus()
    fireEvent.keyDown(rows[0], { key: 'ArrowDown' })
    expect(rows[1]).toHaveFocus()
    fireEvent.keyDown(rows[1], { key: 'End' })
    expect(rows[2]).toHaveFocus()
    fireEvent.keyDown(rows[2], { key: 'Home' })
    expect(rows[0]).toHaveFocus()
    fireEvent.keyDown(rows[0], { key: 'Enter' })
    expect(onRow).toHaveBeenCalledWith(expect.objectContaining({ id: 'a' }))
    fireEvent.keyDown(rows[0], { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
