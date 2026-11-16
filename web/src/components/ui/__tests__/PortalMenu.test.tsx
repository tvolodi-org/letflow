// @vitest-environment jsdom
/** PortalMenu — T-2020: a long menu stays reachable on a short window (CI e2e P9: Inv-18 items were below the fold). */
import { cleanup, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, describe, expect, it } from 'vitest'
import { PortalMenu } from '../PortalMenu'

afterEach(cleanup)

describe('PortalMenu', () => {
  it('caps the menu height to the window below the trigger and scrolls inside it', () => {
    const anchor = createRef<HTMLButtonElement>()
    const menuRef = createRef<HTMLDivElement>()
    render(
      <>
        <button ref={anchor}>t</button>
        <PortalMenu anchor={anchor} menuRef={menuRef} label="Print">
          <a role="menuitem">one</a>
        </PortalMenu>
      </>,
    )
    const menu = screen.getByRole('menu')
    expect(menu.style.overflowY).toBe('auto')
    expect(parseInt(menu.style.maxHeight, 10)).toBeGreaterThanOrEqual(120)
    expect(parseInt(menu.style.maxHeight, 10)).toBeLessThanOrEqual(window.innerHeight)
  })
})
