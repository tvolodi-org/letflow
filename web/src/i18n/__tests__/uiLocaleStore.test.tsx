// @vitest-environment jsdom
/** D-083: the UI-language store, and providers following it without reload. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen } from '@testing-library/react'
import { useIntl } from 'react-intl'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { LoginIntlProvider } from '../LoginIntlProvider'
import { loginMessages } from '../loginMessages'
import { ImportIntlProvider } from '../ImportIntlProvider'
import { importMessages } from '../importMessages'
import { ThemeToggle, themeToggleMessages } from '@/components/ui/ThemeToggle'
import { useFormMessages, formMessages } from '@/components/ui/formMessages'
import { resolveUiLocale } from '../entitiesMessages'
import { getUiLocale, useUiLocaleStore } from '../uiLocaleStore'

expect.extend(jestDomMatchers)

function setBrowser(langs: string[]) {
  vi.spyOn(window.navigator, 'languages', 'get').mockReturnValue(langs)
}
function setSearch(search: string) {
  window.history.replaceState({}, '', '/' + search)
}
function fresh() {
  useUiLocaleStore.getState().reloadFromEnvironment()
}

beforeEach(() => {
  window.localStorage.clear()
  setSearch('')
  setBrowser(['en-US'])
  fresh()
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  window.localStorage.clear()
  setSearch('')
  fresh()
})

describe('uiLocaleStore', () => {
  it('defaults to the browser language', () => {
    setBrowser(['de', 'kk-KZ'])
    expect(getUiLocale()).toBe('kk')
    setBrowser(['de'])
    expect(getUiLocale()).toBe('en')
  })

  it('a saved choice beats the browser', () => {
    setBrowser(['en'])
    window.localStorage.setItem('lf-locale', 'ru')
    fresh()
    expect(getUiLocale()).toBe('ru')
  })

  it('?lang beats the saved choice and is not saved', () => {
    window.localStorage.setItem('lf-locale', 'ru')
    setSearch('?lang=kk')
    fresh()
    expect(getUiLocale()).toBe('kk')
    expect(window.localStorage.getItem('lf-locale')).toBe('ru')
  })

  it('an unsupported ?lang or saved value is ignored', () => {
    setBrowser(['ru'])
    window.localStorage.setItem('lf-locale', 'uz')
    setSearch('?lang=uz')
    fresh()
    expect(getUiLocale()).toBe('ru')
  })

  it('an unsupported ?lang falls back to the saved choice', () => {
    window.localStorage.setItem('lf-locale', 'kk')
    setSearch('?lang=xx')
    fresh()
    expect(getUiLocale()).toBe('kk')
  })

  it('setLocale saves under lf-locale', () => {
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    expect(window.localStorage.getItem('lf-locale')).toBe('ru')
    expect(resolveUiLocale()).toBe('ru')
  })

  it('setLocaleTransient does not save', () => {
    act(() => useUiLocaleStore.getState().setLocaleTransient('kk'))
    expect(getUiLocale()).toBe('kk')
    expect(window.localStorage.getItem('lf-locale')).toBeNull()
  })
})

function Probe({ id }: { id: string }) {
  return <p data-testid="probe">{useIntl().formatMessage({ id })}</p>
}
function FormProbe() {
  return <p data-testid="probe">{useFormMessages().saving}</p>
}

const AREAS: { name: string; element: () => React.ReactElement; text: (l: 'en' | 'ru' | 'kk') => string }[] = [
  { name: 'login', element: () => <LoginIntlProvider><Probe id={Object.keys(loginMessages.en)[0]} /></LoginIntlProvider>, text: (l) => Object.values(loginMessages[l])[0] },
  { name: 'import', element: () => <ImportIntlProvider><Probe id={Object.keys(importMessages.en)[0]} /></ImportIntlProvider>, text: (l) => Object.values(importMessages[l])[0] },
  { name: 'form messages', element: () => <FormProbe />, text: (l) => formMessages[l].saving },
  { name: 'theme toggle', element: () => <ThemeToggle />, text: (l) => themeToggleMessages[l].label },
]

describe('areas follow the store without reload', () => {
  for (const area of AREAS) {
    it(area.name, () => {
      render(area.element())
      const read = () => (area.name === 'theme toggle' ? screen.getByTestId('theme-toggle').getAttribute('aria-label') ?? '' : screen.getByTestId('probe').textContent)
      const first = read()
      expect(first).toContain(area.text('en'))
      act(() => useUiLocaleStore.getState().setLocale('ru'))
      expect(read()).toContain(area.text('ru'))
      act(() => useUiLocaleStore.getState().setLocale('kk'))
      expect(read()).toContain(area.text('kk'))
    })
  }
})
