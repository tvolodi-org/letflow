// @vitest-environment jsdom
/** R3 -- T-1381: the formatted value next to a native date input. */
import { afterEach, describe, expect, it } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DateValueHint } from '../DateValueHint'

expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('DateValueHint', () => {
  it('ru and kk show the value as DD-MM-YYYY (HH:mm)', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    const { rerender } = render(<DateValueHint value="2026-11-03" kind="date" />)
    expect(screen.getByTestId('date-value-hint')).toHaveTextContent('03-11-2026')
    useUiLocaleStore.getState().setLocaleTransient('kk')
    rerender(<DateValueHint value="2026-11-03T09:05" kind="datetime" />)
    expect(screen.getByTestId('date-value-hint')).toHaveTextContent('03-11-2026 09:05')
  })
  it('en renders nothing', () => {
    useUiLocaleStore.getState().setLocaleTransient('en')
    render(<DateValueHint value="2026-11-03" kind="date" />)
    expect(screen.queryByTestId('date-value-hint')).not.toBeInTheDocument()
  })
  it('empty or malformed renders nothing', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    const { rerender } = render(<DateValueHint value="" kind="date" />)
    expect(screen.queryByTestId('date-value-hint')).not.toBeInTheDocument()
    rerender(<DateValueHint value="nope" kind="date" />)
    expect(screen.queryByTestId('date-value-hint')).not.toBeInTheDocument()
  })
})
