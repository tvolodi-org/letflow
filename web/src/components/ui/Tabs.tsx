/** Tabs — `role=tablist` with roving tabindex. Left/Right (and Home/End) move
 *  to a tab and select it (automatic activation); the row scrolls sideways
 *  when it overflows (CSS).
 */

import React, { useRef } from 'react'

export interface TabItem {
  id: string
  label: string
  count?: number
}

export interface TabsProps {
  items: TabItem[]
  selected: string
  onChange: (id: string) => void
  'aria-label'?: string
}

export function Tabs(props: TabsProps): React.ReactElement {
  const { items, selected, onChange } = props
  const listRef = useRef<HTMLDivElement>(null)
  const selectedIndex = items.findIndex((item) => item.id === selected)
  const tabbableIndex = selectedIndex >= 0 ? selectedIndex : 0

  function move(to: number): void {
    const item = items[to]
    if (!item) return
    onChange(item.id)
    listRef.current?.querySelectorAll<HTMLElement>('[role="tab"]')[to]?.focus()
  }

  function handleKeyDown(event: React.KeyboardEvent, index: number): void {
    const last = items.length - 1
    let target: number | null = null
    if (event.key === 'ArrowRight') target = index === last ? 0 : index + 1
    else if (event.key === 'ArrowLeft') target = index === 0 ? last : index - 1
    else if (event.key === 'Home') target = 0
    else if (event.key === 'End') target = last
    if (target === null) return
    event.preventDefault()
    move(target)
  }

  return (
    <div className="lf-tabs" role="tablist" aria-label={props['aria-label']} ref={listRef} data-testid="tabs">
      {items.map((item, index) => (
        <button
          key={item.id}
          type="button"
          role="tab"
          id={`tab-${item.id}`}
          className="lf-tab"
          aria-selected={item.id === selected}
          tabIndex={index === tabbableIndex ? 0 : -1}
          onClick={() => onChange(item.id)}
          onKeyDown={(event) => handleKeyDown(event, index)}
        >
          {item.label}
          {item.count !== undefined && <span className="lf-count">{item.count}</span>}
        </button>
      ))}
    </div>
  )
}
