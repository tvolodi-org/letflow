// @vitest-environment jsdom
/** D1–D6 — T-1954: DetailTabs, the tab slot of a detail pane. */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { DetailTabs } from '../DetailTabs'

expect.extend(jestDomMatchers)
afterEach(() => cleanup())

const tabs = [
  { id: 'one', label: 'One', panel: <input aria-label="first" /> },
  { id: 'two', label: 'Two', count: 4, panel: <p>second panel</p> },
]
function Harness({ initial = 'one' }: { initial?: string }) {
  const [sel, setSel] = useState(initial)
  return <DetailTabs tabs={tabs} selected={sel} onChange={setSel} aria-label="Sections" />
}

describe('DetailTabs', () => {
  it('D1 aria-controls and aria-labelledby point at each other, panels have role tabpanel', () => {
    render(<Harness />)
    for (const tab of screen.getAllByRole('tab')) {
      const panel = document.getElementById(tab.getAttribute('aria-controls') ?? '')
      expect(panel).not.toBeNull()
      expect(panel).toHaveAttribute('role', 'tabpanel')
      expect(panel).toHaveAttribute('aria-labelledby', tab.id)
    }
  })

  it('D2 two instances with the same tab ids make no duplicate ids', () => {
    render(<><Harness /><Harness /></>)
    const ids = [...document.querySelectorAll('[id]')].map((e) => e.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('D3 only the selected panel is visible, the others stay in the DOM hidden', () => {
    render(<Harness />)
    expect(screen.getByTestId('detail-tab-panel-one')).not.toHaveAttribute('hidden')
    expect(screen.getByTestId('detail-tab-panel-two')).toHaveAttribute('hidden')
    expect(screen.getByText('second panel')).toBeInTheDocument()
  })

  it('D4 a typed value survives a switch away and back', () => {
    render(<Harness />)
    fireEvent.change(screen.getByLabelText('first'), { target: { value: 'kept' } })
    fireEvent.click(screen.getByRole('tab', { name: /Two/ }))
    fireEvent.click(screen.getByRole('tab', { name: 'One' }))
    expect(screen.getByLabelText('first')).toHaveValue('kept')
  })

  it('D5 an unknown selected id shows the first tab', () => {
    render(<Harness initial="nope" />)
    expect(screen.getByTestId('detail-tab-panel-one')).not.toHaveAttribute('hidden')
    expect(screen.getByRole('tab', { name: 'One' })).toHaveAttribute('aria-selected', 'true')
  })

  it('D6 the count renders and onChange gets the id on click and ArrowRight', () => {
    const onChange = vi.fn()
    const { container } = render(<DetailTabs tabs={tabs} selected="one" onChange={onChange} aria-label="S" />)
    expect(container.querySelector('.lf-count')).toHaveTextContent('4')
    fireEvent.click(screen.getByRole('tab', { name: /Two/ }))
    expect(onChange).toHaveBeenLastCalledWith('two')
    fireEvent.keyDown(screen.getByRole('tab', { name: 'One' }), { key: 'ArrowRight' })
    expect(onChange).toHaveBeenCalledTimes(2)
  })
})
