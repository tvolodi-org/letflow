// @vitest-environment jsdom
/** J1–J5 — T-1422 (GATE B R12): the generic journal: split layout, V1 default, V2 as an option, keys. */
import { act } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { LAYOUT_STORAGE_KEY, createLayoutStore } from '@/lib/layoutStore'
import { resetDefaultLayoutStore } from '@/hooks/useLayoutPrefs'
import { JournalLegTable } from '../JournalDetails'
import {
  DEFAULT_JOURNAL_VARIANT, JOURNAL_LAYOUTS, JournalDetails, JOURNAL_VARIANTS, Journal, JournalList, isJournalVariant,
  type JournalListProps, type JournalOp, type JournalVariant,
} from '..'

expect.extend(jestDomMatchers)
const ANON = `${LAYOUT_STORAGE_KEY}.anon`
beforeEach(() => {
  localStorage.clear()
  resetDefaultLayoutStore()
  vi.useFakeTimers()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

const LEGS = { legs: 'Legs', heldBy: 'Held by', hiddenUnit: 'Hidden unit', change: 'Change', location: 'Location', item: 'Item' }
const op = (id: string): JournalOp => ({
  id, time: '04-11-2026 23:00', kind: 'receipt', kindLabel: 'Receipt', kindIcon: null, docText: `DOC-${id} - Receipt`, docHref: `/d/${id}`,
  item: 'ITM-1 - Bolt', itemMore: 0, location: 'WH - Main', locationMore: 0, qty: '5 pcs', qtySign: 'pos', status: 'posted', statusLabel: 'Posted', statusNote: '',
  legs: [{ id: '1', location: 'WH - Main', item: 'ITM-1 - Bolt', holder: '', qty: '5 pcs', sign: 'pos', hidden: false }],
})

function listProps(over: Partial<JournalListProps> = {}): JournalListProps {
  return {
    titleId: 't', variant: 'v1', layoutScreen: 'test.journal', state: 'ready', ops: [op('a'), op('b'), op('c')], selectedId: null, expandedId: null,
    onRow: vi.fn(), onToggleExpand: vi.fn(), onDetails: vi.fn(), filtersNode: <span />, filterCount: 0, filtersOpen: false,
    onToggleFilters: vi.fn(), onClearFilters: vi.fn(), filtered: false,
    empty: { title: 'Empty', text: 'e' }, noMatch: { title: 'No match', text: 'n' }, rangeText: 'Showing 3',
    labels: {
      title: 'Movements', filters: 'Filters', export: 'Export', details: 'Details', expand: 'Show legs', collapse: 'Hide legs',
      clearFilters: 'Clear', more: (n) => `+${n}`,
      columns: { date: 'Date', kind: 'Kind', doc: 'Doc', item: 'Item', qty: 'Qty', location: 'Location', status: 'Status' }, legs: LEGS,
    },
    ...over,
  }
}

const shell = (variant?: JournalVariant, detailOpen = false, onClose?: () => void) => (
  <MemoryRouter>
    <Journal variant={variant} list={<JournalList {...listProps({ variant: variant ?? 'v1' })} />} details={<div className="lf-jrn__details" />} detailOpen={detailOpen} filtersOpen={false} onClose={onClose} layoutScreen="test.journal" splitLabel="Movement details" />
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
        <Journal list={<JournalList {...listProps({ onRow })} />} details={<div />} detailOpen filtersOpen={false} onClose={onClose} layoutScreen="test.journal" splitLabel="Movement details" />
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

describe('D1 wide Details button (T-1439)', () => {
  const labels = {
    pane: 'Pane', back: 'Back', prev: 'Prev', next: 'Next', close: 'Close', sections: 'Op', position: '1 of 3', legsTitle: 'Legs',
    legs: LEGS, blankTitle: 'b', blankText: 'b', details: 'Details',
  }
  const view = (onOpenFull?: () => void) => (
    <MemoryRouter>
      <JournalDetails labels={labels} op={op('a')} hasPrev={false} hasNext layoutScreen="test.journal" onBack={vi.fn()} onPrev={vi.fn()} onNext={vi.fn()}
        onOpenFull={onOpenFull} fields={null} links={null} />
    </MemoryRouter>
  )
  it('draws the button with the label and calls the handler; absent without the prop', () => {
    const open = vi.fn()
    const { unmount } = render(view(open))
    const b = screen.getByTestId('journal-open-full')
    expect(b).toHaveTextContent('Details')
    fireEvent.click(b)
    expect(open).toHaveBeenCalledTimes(1)
    unmount()
    render(view())
    expect(screen.queryByTestId('journal-open-full')).toBeNull()
  })
})

describe('C1 base.css keeps the T-1439 rules', () => {
  it('has the full-screen and table rules', async () => {
    const { readFileSync } = await import('node:fs')
    const css = readFileSync('src/styles/base.css', 'utf8')
    const at = css.indexOf('T-1439 R12b')
    expect(at).toBeGreaterThan(-1)
    const block = css.slice(at)
    expect(block).toContain('.lf-jrn__table { min-width')
    expect(block).toContain('[data-detail="open"] > .lf-jrn__list')
    expect(block).toContain('.lf-jrn__fullbtn')
  })
})

/** jsdom has no layout: the journal element is `area` px wide, a table 1000 px, a th as wide as its percent. */
function layout(area: number) {
  vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockImplementation(function (this: HTMLElement) {
    return this.classList.contains('lf-jrn') ? area : 0
  })
  vi.spyOn(HTMLElement.prototype, 'getClientRects').mockImplementation(function (this: HTMLElement) {
    return (this.tagName === 'TH' ? [{}] : []) as unknown as DOMRectList
  })
  vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
    const w = this.tagName === 'TABLE' ? 1000 : this.tagName === 'TH' ? parseFloat(this.style.width || '10') * 10 : this.classList.contains('lf-jrn__list') ? 600 : 1000
    return { left: 0, right: w, width: w, top: 0, bottom: 40, height: 40, x: 0, y: 0, toJSON: () => ({}) } as DOMRect
  })
}
const key = (el: Element, k: string) => act(() => void el.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })))
/** The store writes localStorage after a 400 ms debounce. */
const stored = () => {
  act(() => void vi.advanceTimersByTime(500))
  return JSON.parse(localStorage.getItem(ANON) ?? '{}')
}

describe('J3-1 / J3-2 the divider between operations and legs', () => {
  it('J3-1 wide area: one separator named by splitLabel; ArrowLeft changes --lf-pane-1', () => {
    layout(1200)
    render(shell('v1', true))
    const seps = screen.getAllByRole('separator').filter((e) => !e.classList.contains('lf-colhandle'))
    expect(seps).toHaveLength(1)
    expect(seps[0]).toHaveAttribute('aria-label', 'Movement details')
    expect(seps[0]).toHaveAttribute('aria-controls')
    const jrn = screen.getByTestId('journal')
    key(seps[0], 'ArrowLeft')
    expect(jrn.style.getPropertyValue('--lf-pane-1')).not.toBe('')
  })

  it('J3-2 narrow area: no divider and no column handle', () => {
    layout(500)
    render(shell())
    expect(screen.queryAllByRole('separator')).toHaveLength(0)
    expect(document.querySelector('.lf-colhandle')).toBeNull()
  })
})

describe('J3-4 / J3-5 resizable and remembered columns', () => {
  it('J3-4 handles on every operations column but the last; a key writes the width into the store', () => {
    layout(1200)
    render(shell())
    const heads = Array.from(document.querySelectorAll('thead th[data-col]'))
    expect(heads.map((h) => h.getAttribute('data-col'))).toEqual(['date', 'kind', 'doc', 'item', 'qty', 'loc', 'st'])
    expect(document.querySelectorAll('.lf-colhandle')).toHaveLength(6)
    expect(heads[6].querySelector('.lf-colhandle')).toBeNull()
    const h = heads[0].querySelector('.lf-colhandle') as HTMLElement
    expect(h).toHaveAttribute('aria-label', 'Resize column: Date')
    key(h, 'ArrowRight')
    expect(stored().screens['test.journal'].cols.ops.date).toBe(16)
    key(h, 'Enter')
    expect(stored().screens['test.journal']?.cols?.ops?.date ?? null).toBeNull()
  })

  it('J3-5 remembered widths and pane size are applied on mount', () => {
    const seed = createLayoutStore({ storageKey: ANON })
    seed.setPanes('test.journal', 'details', [38])
    seed.setCols('test.journal', 'ops', { date: 12 })
    seed.flush()
    resetDefaultLayoutStore()
    layout(1200)
    render(shell())
    expect((document.querySelector('th[data-col=date]') as HTMLElement).style.width).toBe('12%')
    expect(screen.getByTestId('journal').style.getPropertyValue('--lf-pane-1')).toBe('38%')
  })
})

describe('J3-3 the legs table', () => {
  const masked = { id: '2', location: '', item: '', holder: '', qty: '3 pcs', sign: 'neg' as const, hidden: true }
  const legs = [{ ...op('a').legs[0], holder: 'Aigul B.' }, masked]

  it('one row per leg: place with holder, item, signed change; a masked leg spans place and item', () => {
    layout(1200)
    render(<JournalLegTable legs={legs} labels={LEGS} screen="test.journal" />)
    const t = screen.getByTestId('journal-legtable')
    expect(Array.from(t.querySelectorAll('th')).map((h) => h.getAttribute('data-col'))).toEqual(['loc', 'item', 'chg'])
    const rows = screen.getAllByTestId('journal-legrow')
    expect(rows).toHaveLength(2)
    expect(rows[0]).toHaveTextContent('Main')
    expect(rows[0]).toHaveTextContent('Held by Aigul B.')
    expect(rows[0]).toHaveTextContent('+')
    expect(rows[0].querySelector('.sr-only')).toHaveTextContent('+')
    expect(rows[1].querySelector('td[colspan="2"]')).toHaveTextContent('Hidden unit')
    expect(rows[1].querySelector('.sr-only')).toHaveTextContent('−')
  })

  it('J3-4 the legs table has handles on loc and item, none on the change column', () => {
    layout(1200)
    render(<JournalLegTable legs={legs} labels={LEGS} screen="test.journal" />)
    expect(document.querySelectorAll('.lf-colhandle')).toHaveLength(2)
    key(document.querySelector('th[data-col=loc] .lf-colhandle') as HTMLElement, 'ArrowRight')
    expect(stored().screens['test.journal'].cols.legs.loc).toBe(41)
  })

  it('J3-3 JournalDetails renders both the cards and the table (the CSS shows one)', () => {
    const noop = vi.fn()
    render(
      <MemoryRouter>
        <JournalDetails
          labels={{ pane: 'P', back: 'Back', prev: 'Prev', next: 'Next', close: 'Close', sections: 'S', position: '1 of 1', legsTitle: 'Legs', legs: LEGS, blankTitle: 'b', blankText: 't' }}
          op={op('a')} hasPrev={false} hasNext={false} onBack={noop} onPrev={noop} onNext={noop}
          fields={null} links={null} layoutScreen="test.journal"
        />
      </MemoryRouter>,
    )
    expect(screen.getAllByTestId('journal-leg')).toHaveLength(1)
    expect(screen.getAllByTestId('journal-legrow')).toHaveLength(1)
  })
})
