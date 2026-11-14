// @vitest-environment jsdom
/** NM1–NM7 — T-1953: the header "New" menu (keyboard, focus, disabled items). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { NewMenu } from '../NewMenu'

expect.extend(jestDomMatchers)
afterEach(() => cleanup())

function setup(over: { disabled?: boolean } = {}) {
  const pick = { a: vi.fn(), b: vi.fn(), c: vi.fn() }
  render(
    <NewMenu
      label="New document"
      items={[
        { id: 'a', label: 'Alpha', onSelect: pick.a },
        { id: 'b', label: 'Beta', onSelect: pick.b },
        { id: 'c', label: 'Gamma', onSelect: pick.c, disabled: over.disabled, reason: 'Not now' },
      ]}
    />,
  )
  return { pick, trigger: screen.getByTestId('new-menu') }
}
const items = () => screen.getAllByRole('menuitem')

describe('NM1 trigger and menu', () => {
  it('is closed at first; a click opens a menu named by the label with the items in order', () => {
    const { trigger } = setup()
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu')
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('menu')).toBeNull()
    fireEvent.click(trigger)
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('menu', { name: 'New document' })).toBeInTheDocument()
    expect(items().map((i) => i.textContent)).toEqual(['Alpha', 'Beta', 'Gamma'])
  })
})

describe('NM2 arrows on the closed trigger', () => {
  it('ArrowDown opens and focuses the first item, ArrowUp the last', () => {
    const { trigger } = setup()
    fireEvent.keyDown(trigger, { key: 'ArrowDown' })
    expect(document.activeElement).toBe(items()[0])
    fireEvent.keyDown(items()[0]!, { key: 'Escape' })
    fireEvent.keyDown(trigger, { key: 'ArrowUp' })
    expect(document.activeElement).toBe(items()[2])
  })
})

describe('NM3 moving', () => {
  it('arrows wrap, Home and End jump', () => {
    const { trigger } = setup()
    fireEvent.keyDown(trigger, { key: 'ArrowDown' })
    fireEvent.keyDown(items()[0]!, { key: 'ArrowUp' })
    expect(document.activeElement).toBe(items()[2])
    fireEvent.keyDown(items()[2]!, { key: 'ArrowDown' })
    expect(document.activeElement).toBe(items()[0])
    fireEvent.keyDown(items()[0]!, { key: 'End' })
    expect(document.activeElement).toBe(items()[2])
    fireEvent.keyDown(items()[2]!, { key: 'Home' })
    expect(document.activeElement).toBe(items()[0])
  })
})

describe('NM4 Escape', () => {
  it('closes the menu and returns focus to the trigger', () => {
    const { trigger } = setup()
    fireEvent.click(trigger)
    items()[1]!.focus()
    fireEvent.keyDown(items()[1]!, { key: 'Escape' })
    expect(screen.queryByRole('menu')).toBeNull()
    expect(document.activeElement).toBe(trigger)
  })
})

describe('NM5 choosing', () => {
  it('Enter and a click each call onSelect once and close the menu', () => {
    const { pick, trigger } = setup()
    fireEvent.click(trigger)
    fireEvent.keyDown(items()[0]!, { key: 'Enter' })
    expect(pick.a).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('menu')).toBeNull()
    fireEvent.click(trigger)
    fireEvent.click(items()[1]!)
    expect(pick.b).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('menu')).toBeNull()
    fireEvent.click(trigger)
    fireEvent.keyDown(items()[0]!, { key: ' ' })
    expect(pick.a).toHaveBeenCalledTimes(2)
  })
})

describe('NM6 closing', () => {
  it('a mousedown outside closes; Tab closes', () => {
    const { trigger } = setup()
    fireEvent.click(trigger)
    fireEvent.mouseDown(document.body)
    expect(screen.queryByRole('menu')).toBeNull()
    fireEvent.click(trigger)
    fireEvent.mouseDown(items()[0]!)
    expect(screen.getByRole('menu')).toBeInTheDocument()
    fireEvent.keyDown(items()[0]!, { key: 'Tab' })
    expect(screen.queryByRole('menu')).toBeNull()
  })
})

describe('NM7 disabled item', () => {
  it('shows its reason, is aria-disabled and chooses nothing', () => {
    const { pick, trigger } = setup({ disabled: true })
    fireEvent.click(trigger)
    const gamma = items()[2]!
    expect(gamma).toHaveAttribute('aria-disabled', 'true')
    expect(gamma).toHaveTextContent('Not now')
    fireEvent.click(gamma)
    fireEvent.keyDown(gamma, { key: 'Enter' })
    expect(pick.c).not.toHaveBeenCalled()
    expect(screen.getByRole('menu')).toBeInTheDocument()
  })
})
