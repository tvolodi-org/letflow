// @vitest-environment jsdom
/** T1–T3 — T-1954: Tabs ids stay global without `idPrefix` and are scoped with it. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { Tabs } from '../Tabs'

expect.extend(jestDomMatchers)
afterEach(() => cleanup())
const items = [{ id: 'a', label: 'A' }, { id: 'b', label: 'B', count: 3 }]

describe('Tabs', () => {
  it('T1 without idPrefix the ids are tab-<id> and there is no aria-controls', () => {
    render(<Tabs items={items} selected="a" onChange={() => {}} />)
    const tab = screen.getByRole('tab', { name: 'A' })
    expect(tab.id).toBe('tab-a')
    expect(tab).not.toHaveAttribute('aria-controls')
  })

  it('T2 with idPrefix the id and aria-controls are scoped', () => {
    render(<Tabs items={items} selected="a" onChange={() => {}} idPrefix="p" />)
    const tab = screen.getByRole('tab', { name: 'A' })
    expect(tab.id).toBe('p-tab-a')
    expect(tab).toHaveAttribute('aria-controls', 'p-panel-a')
  })

  it('T3 the count badge renders and ArrowRight selects the next tab', () => {
    const onChange = vi.fn()
    const { container } = render(<Tabs items={items} selected="a" onChange={onChange} />)
    expect(container.querySelector('.lf-count')).toHaveTextContent('3')
    fireEvent.keyDown(screen.getByRole('tab', { name: 'A' }), { key: 'ArrowRight' })
    expect(onChange).toHaveBeenCalledWith('b')
  })
})
