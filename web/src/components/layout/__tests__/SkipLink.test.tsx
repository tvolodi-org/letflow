// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { SkipLink } from '../SkipLink'

expect.extend(jestDomMatchers)

afterEach(cleanup)

describe('SkipLink', () => {
  it('is clipped until focused, visible while focused, clipped again after blur', async () => {
    const user = userEvent.setup()
    render(<><SkipLink label="Skip" /><main id="main-content" tabIndex={-1} /></>)
    const link = screen.getByRole('link', { name: 'Skip' })
    expect(link).toHaveAttribute('href', '#main-content')
    expect(link.style.width).toBe('1px')
    expect(link.style.overflow).toBe('hidden')

    await user.tab()
    expect(link).toHaveFocus()
    expect(link.style.position).toBe('fixed')
    expect(link.style.width).toBe('auto')

    await user.tab()
    expect(link.style.width).toBe('1px')
  })

  it('moves focus to #main-content on click and Enter without changing the hash', async () => {
    const user = userEvent.setup()
    render(<><SkipLink label="Skip" /><main id="main-content" tabIndex={-1} /></>)
    const main = document.getElementById('main-content')
    await user.click(screen.getByRole('link', { name: 'Skip' }))
    expect(main).toHaveFocus()
    expect(window.location.hash).toBe('')

    ;(main as HTMLElement).blur()
    await user.tab()
    await user.keyboard('{Enter}')
    expect(main).toHaveFocus()
    expect(window.location.hash).toBe('')
  })
})
