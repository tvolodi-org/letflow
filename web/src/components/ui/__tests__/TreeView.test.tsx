// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { useState } from 'react'
expect.extend(jestDomMatchers)

import { TreeView, type TreeNode } from '../TreeView'

afterEach(cleanup)

const NODES: TreeNode[] = [
  {
    id: 'ho',
    name: 'Head office',
    code: 'OU-HO',
    meta: 1,
    children: [
      { id: 'fin', name: 'Finance', children: [{ id: 'acc', name: 'Accounting', code: 'OU-ACC' }] },
      { id: 'old', name: 'Night shift', retired: true },
    ],
  },
  { id: 'svc', name: 'Service company' },
]

function Harness(props: { initialExpanded?: string[]; showRetired?: boolean; onSelect?: (id: string) => void }) {
  const [expanded, setExpanded] = useState<string[]>(props.initialExpanded ?? [])
  const [selected, setSelected] = useState<string | null>(null)
  return (
    <TreeView
      nodes={NODES}
      aria-label="Org units"
      selectedId={selected}
      expandedIds={expanded}
      showRetired={props.showRetired}
      onSelect={(id) => {
        setSelected(id)
        props.onSelect?.(id)
      }}
      onToggle={(id) => setExpanded((e) => (e.includes(id) ? e.filter((x) => x !== id) : [...e, id]))}
    />
  )
}

const row = (id: string): HTMLElement => document.querySelector(`[data-node-id="${id}"]`) as HTMLElement
const key = (id: string, k: string): void => {
  fireEvent.keyDown(row(id), { key: k })
}

describe('T-1166 — TreeView', () => {
  it('TC-T1166-40: roles, levels, aria-expanded and collapsed children not rendered', () => {
    render(<Harness />)
    expect(screen.getByRole('tree', { name: 'Org units' })).toBeInTheDocument()
    const items = screen.getAllByRole('treeitem')
    expect(items).toHaveLength(2)
    expect(items[0]).toHaveAttribute('aria-expanded', 'false')
    expect(items[0]).toHaveAttribute('aria-level', '1')
    expect(items[1]).not.toHaveAttribute('aria-expanded')
    expect(row('fin')).toBeNull()
  })

  it('TC-T1166-41: expanded node shows children inside a group at the next level', () => {
    render(<Harness initialExpanded={['ho', 'fin']} />)
    expect(screen.getAllByRole('group')).toHaveLength(2)
    expect(screen.getByText('Accounting').closest('[role="treeitem"]')).toHaveAttribute('aria-level', '3')
  })

  it('TC-T1166-42: the toggle button expands and collapses without selecting', () => {
    const onSelect = vi.fn()
    render(<Harness onSelect={onSelect} />)
    fireEvent.click(screen.getByRole('button', { name: 'Expand' }))
    expect(row('fin')).not.toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Collapse' }))
    expect(row('fin')).toBeNull()
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('TC-T1166-43: roving tabindex: exactly one row has tabindex 0 (first by default, selected after select)', () => {
    render(<Harness initialExpanded={['ho']} />)
    const tabbable = () => Array.from(document.querySelectorAll('.lf-tree__row[tabindex="0"]'))
    expect(tabbable()).toEqual([row('ho')])
    fireEvent.click(row('fin'))
    expect(tabbable()).toEqual([row('fin')])
    expect(row('fin')).toHaveAttribute('aria-selected', 'true')
  })

  it('TC-T1166-44: Down/Up move focus between visible rows; Home/End jump', () => {
    render(<Harness initialExpanded={['ho']} />)
    row('ho').focus()
    key('ho', 'ArrowDown')
    expect(row('fin')).toHaveFocus()
    key('fin', 'ArrowUp')
    expect(row('ho')).toHaveFocus()
    key('ho', 'End')
    expect(row('svc')).toHaveFocus()
    key('svc', 'Home')
    expect(row('ho')).toHaveFocus()
  })

  it('TC-T1166-45: Right opens a closed node, then goes to its first child; Left goes to the parent, then closes', () => {
    render(<Harness />)
    row('ho').focus()
    key('ho', 'ArrowRight')
    expect(row('fin')).not.toBeNull()
    key('ho', 'ArrowRight')
    expect(row('fin')).toHaveFocus()
    key('fin', 'ArrowLeft')
    expect(row('ho')).toHaveFocus()
    key('ho', 'ArrowLeft')
    expect(row('fin')).toBeNull()
  })

  it('TC-T1166-46: Enter and Space select the focused row', () => {
    const onSelect = vi.fn()
    render(<Harness onSelect={onSelect} />)
    row('svc').focus()
    key('svc', 'Enter')
    key('svc', ' ')
    expect(onSelect).toHaveBeenCalledTimes(2)
    expect(onSelect).toHaveBeenCalledWith('svc')
  })

  it('TC-T1166-47: typing a letter jumps to the next visible name starting with it', () => {
    render(<Harness initialExpanded={['ho']} />)
    row('ho').focus()
    key('ho', 's')
    expect(row('svc')).toHaveFocus()
    key('svc', 'f')
    expect(row('fin')).toHaveFocus()
  })

  it('TC-T1166-48: retired nodes are hidden unless showRetired, then struck and labelled', () => {
    const { rerender } = render(<Harness initialExpanded={['ho']} />)
    expect(row('old')).toBeNull()
    cleanup()
    render(<Harness initialExpanded={['ho']} showRetired />)
    expect(row('old')).toHaveClass('is-retired')
    expect(row('old')).toHaveTextContent('Retired')
    void rerender
  })

  it('TC-T1166-49: name and code carry the full text in title for cut text', () => {
    render(<Harness />)
    expect(screen.getByText('Head office')).toHaveAttribute('title', 'Head office')
    expect(screen.getByText('OU-HO')).toHaveAttribute('title', 'OU-HO')
  })

  it('TC-T1166-50: a loading node shows a loading row when expanded', () => {
    render(
      <TreeView
        nodes={[{ id: 'x', name: 'Lazy', loading: true }]}
        expandedIds={['x']}
        onSelect={() => {}}
        onToggle={() => {}}
      />,
    )
    expect(screen.getByRole('status')).toHaveTextContent('Loading…')
  })
})
