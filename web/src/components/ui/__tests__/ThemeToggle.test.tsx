// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { THEME_STORAGE_KEY } from '@/theming/theme'
import { ThemeToggle, themeToggleMessages } from '../ThemeToggle'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  document.documentElement.removeAttribute('data-theme')
  window.localStorage.clear()
})

describe('ThemeToggle', () => {
  it('starts from the data-theme attribute and reports it with aria-pressed', () => {
    document.documentElement.setAttribute('data-theme', 'dark')
    render(<ThemeToggle locale="en" />)
    expect(screen.getByTestId('theme-toggle')).toHaveAttribute('aria-pressed', 'true')
  })

  it('click switches light to dark: writes data-theme and storage', () => {
    document.documentElement.setAttribute('data-theme', 'light')
    render(<ThemeToggle locale="en" />)
    const btn = screen.getByTestId('theme-toggle')
    expect(btn).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(btn)
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
    expect(btn).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(btn)
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe('light')
  })

  it('works from the keyboard: Tab focuses it, Enter and Space toggle', async () => {
    document.documentElement.setAttribute('data-theme', 'light')
    const user = userEvent.setup()
    render(<ThemeToggle locale="en" />)
    await user.tab()
    expect(screen.getByTestId('theme-toggle')).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    await user.keyboard(' ')
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
  })

  it('has an accessible name in English, Russian and Kazakh', () => {
    for (const locale of ['en', 'ru', 'kk'] as const) {
      render(<ThemeToggle locale={locale} />)
      expect(screen.getByRole('button', { name: themeToggleMessages[locale].label })).toBeInTheDocument()
      cleanup()
    }
  })
})
