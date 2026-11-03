// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { useState } from 'react'
expect.extend(jestDomMatchers)

import { Tabs } from '../Tabs'
import { Steps } from '../Steps'
import { Tally } from '../Tally'
import { Skeleton } from '../Skeleton'
import { EmptyState } from '../EmptyState'
import { FilterBar } from '../FilterBar'
import { PaginationControls } from '../PaginationControls'

afterEach(cleanup)

const ITEMS = [
  { id: 'a', label: 'Details' },
  { id: 'b', label: 'Positions', count: 2 },
  { id: 'c', label: 'Employees', count: 3 },
]

function TabsHarness({ onChange }: { onChange?: (id: string) => void }) {
  const [sel, setSel] = useState('a')
  return (
    <Tabs
      items={ITEMS}
      selected={sel}
      aria-label="Sections"
      onChange={(id) => {
        setSel(id)
        onChange?.(id)
      }}
    />
  )
}

describe('T-1166 — Tabs', () => {
  it('TC-T1166-60: tablist, tabs, aria-selected, count, roving tabindex', () => {
    render(<TabsHarness />)
    expect(screen.getByRole('tablist', { name: 'Sections' })).toBeInTheDocument()
    const tabs = screen.getAllByRole('tab')
    expect(tabs.map((t) => t.getAttribute('aria-selected'))).toEqual(['true', 'false', 'false'])
    expect(tabs.map((t) => t.getAttribute('tabindex'))).toEqual(['0', '-1', '-1'])
    expect(tabs[1]).toHaveTextContent('Positions2')
  })

  it('TC-T1166-61: click selects', () => {
    const onChange = vi.fn()
    render(<TabsHarness onChange={onChange} />)
    fireEvent.click(screen.getByRole('tab', { name: /Employees/ }))
    expect(onChange).toHaveBeenCalledWith('c')
  })

  it('TC-T1166-62: Right/Left wrap and move focus with the selection; Home/End jump', () => {
    render(<TabsHarness />)
    const tabs = screen.getAllByRole('tab')
    fireEvent.keyDown(tabs[0], { key: 'ArrowLeft' })
    expect(screen.getAllByRole('tab')[2]).toHaveAttribute('aria-selected', 'true')
    expect(screen.getAllByRole('tab')[2]).toHaveFocus()
    fireEvent.keyDown(screen.getAllByRole('tab')[2], { key: 'ArrowRight' })
    expect(screen.getAllByRole('tab')[0]).toHaveAttribute('aria-selected', 'true')
    fireEvent.keyDown(screen.getAllByRole('tab')[0], { key: 'End' })
    expect(screen.getAllByRole('tab')[2]).toHaveFocus()
    fireEvent.keyDown(screen.getAllByRole('tab')[2], { key: 'Home' })
    expect(screen.getAllByRole('tab')[0]).toHaveFocus()
  })
})

describe('T-1166 — Steps', () => {
  const STEPS = [{ label: 'Data type' }, { label: 'File' }, { label: 'Check' }, { label: 'Import' }]

  it('TC-T1166-70: done, current and next states; current has aria-current=step', () => {
    render(<Steps steps={STEPS} current={2} aria-label="Import steps" />)
    const items = screen.getAllByTestId('step')
    expect(items.map((i) => i.className.replace('lf-step', '').trim())).toEqual(['is-done', 'is-done', 'is-current', ''])
    expect(items[2]).toHaveAttribute('aria-current', 'step')
    expect(items[0]).not.toHaveAttribute('aria-current')
    expect(items[0].querySelector('svg')).not.toBeNull()
    expect(items[2].querySelector('.lf-step__dot')).toHaveTextContent('3')
    expect(items[3].querySelector('.lf-step__dot')).toHaveTextContent('4')
    expect(screen.getByRole('list', { name: 'Import steps' })).toBeInTheDocument()
  })
})

describe('T-1166 — Tally', () => {
  it('TC-T1166-80: shows value and label; the danger item has the danger box and its glyph', () => {
    render(
      <Tally
        items={[
          { label: 'Created', value: 3, glyph: 'dot' },
          { label: 'Refused', value: 1, tone: 'danger', glyph: 'triangle' },
        ]}
      />,
    )
    const [ok, refused] = screen.getAllByTestId('tally-item')
    expect(ok).toHaveTextContent('3Created')
    expect(ok).not.toHaveClass('lf-tally__item--danger')
    expect(refused).toHaveClass('lf-tally__item--danger')
    expect(refused.querySelector('.lf-glyph--triangle')).not.toBeNull()
  })

  it('TC-T1166-81: no glyph element when none is given', () => {
    render(<Tally items={[{ label: 'Updated', value: 0 }]} />)
    expect(document.querySelector('.lf-glyph')).toBeNull()
  })
})

describe('T-1166 — Skeleton', () => {
  it('TC-T1166-90: decorative bar with the given width', () => {
    render(<Skeleton width={90} />)
    const el = screen.getByTestId('skeleton')
    expect(el).toHaveClass('lf-skel')
    expect(el).toHaveAttribute('aria-hidden', 'true')
    expect(el).toHaveStyle({ width: '90px' })
  })

  it('TC-T1166-91: no inline style without a width', () => {
    render(<Skeleton />)
    expect(screen.getByTestId('skeleton').getAttribute('style')).toBeNull()
  })

  it('TC-T1166-92: reduced motion switches every animation off in the shipped CSS', () => {
    const css = readFileSync(resolve(process.cwd(), 'src/styles/components.css'), 'utf8')
    const block = css.slice(css.indexOf('@media (prefers-reduced-motion: reduce)'))
    expect(block).toMatch(/animation:\s*none\s*!important/)
    expect(css).toMatch(/\.lf-skel::after[^}]*animation: lf-shimmer/)
  })
})

describe('T-1166 — EmptyState', () => {
  it('TC-T1166-100: title, text and action; default icon', () => {
    render(<EmptyState title="No links yet" text="Link one." action={<button type="button">Link</button>} />)
    expect(screen.getByText('No links yet')).toHaveClass('lf-empty__title')
    expect(screen.getByText('Link one.')).toHaveClass('lf-empty__text')
    expect(screen.getByRole('button', { name: 'Link' })).toBeInTheDocument()
    expect(document.querySelector('svg.lf-empty__icon')).not.toBeNull()
  })

  it('TC-T1166-101: text and action are optional', () => {
    render(<EmptyState title="Nothing" />)
    expect(document.querySelector('.lf-empty__text')).toBeNull()
  })
})

describe('T-1166 — FilterBar chips', () => {
  const CHIPS = [
    { id: 'unit', label: 'Unit: Accounting' },
    { id: 'st', label: 'Status: Active' },
  ]

  it('TC-T1166-110: chips render, remove calls onRemoveChip with the id', () => {
    const onRemoveChip = vi.fn()
    render(
      <FilterBar activeChips={CHIPS} onRemoveChip={onRemoveChip} onClear={() => {}}>
        <span>field</span>
      </FilterBar>,
    )
    expect(screen.getAllByTestId('filter-bar-chip')).toHaveLength(2)
    fireEvent.click(screen.getByRole('button', { name: 'Remove filter: Unit: Accounting' }))
    expect(onRemoveChip).toHaveBeenCalledWith('unit')
  })

  it('TC-T1166-111: clear shows only with active chips and calls onClear', () => {
    const onClear = vi.fn()
    const { rerender } = render(
      <FilterBar activeChips={CHIPS} onClear={onClear}>
        x
      </FilterBar>,
    )
    fireEvent.click(screen.getByTestId('filter-bar-clear'))
    expect(onClear).toHaveBeenCalledTimes(1)
    rerender(
      <FilterBar activeChips={[]} onClear={onClear}>
        x
      </FilterBar>,
    )
    expect(screen.queryByTestId('filter-bar-clear')).toBeNull()
    expect(screen.queryByTestId('filter-bar-chip')).toBeNull()
  })

  it('TC-T1166-112: layout only: children render untouched inside the toolbar', () => {
    render(
      <FilterBar>
        <input aria-label="q" defaultValue="abc" />
      </FilterBar>,
    )
    expect(screen.getByTestId('filter-bar')).toHaveClass('lf-toolbar')
    expect(screen.getByLabelText('q')).toHaveValue('abc')
  })
})

describe('T-1166 — PaginationControls markup', () => {
  it('TC-T1166-120: uses the table footer and pager classes; summary numbers are mono', () => {
    render(<PaginationControls page={1} pageSize={25} totalItems={100} onPageChange={() => {}} />)
    expect(screen.getByTestId('pagination-controls')).toHaveClass('lf-table-foot')
    expect(document.querySelector('.lf-pager')).not.toBeNull()
    expect(document.querySelectorAll('[data-testid="pagination-summary"] .mono')).toHaveLength(2)
  })

  it('TC-T1166-121: labels can be translated', () => {
    render(
      <PaginationControls
        page={2}
        pageSize={25}
        totalItems={80}
        onPageChange={() => {}}
        onPageSizeChange={() => {}}
        labels={{ showing: 'Показано', of: 'из', previous: 'Назад', next: 'Вперёд', page: 'стр.', itemsPerPage: 'На странице', pages: 'Страницы' }}
      />,
    )
    expect(screen.getByTestId('pagination-summary')).toHaveTextContent('Показано 26-50 из 80')
    expect(screen.getByRole('button', { name: 'Назад' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Вперёд' })).toBeEnabled()
    expect(screen.getByRole('navigation', { name: 'Страницы' })).toBeInTheDocument()
  })
})
