// @vitest-environment jsdom
/** D-083: the codes screens follow the UI-language store at once, without reload. */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen } from '@testing-library/react'
import { useIntl } from 'react-intl'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { CodesIntlProvider } from '../CodesIntlProvider'
import { codesMessages } from '../codesMessages'

expect.extend(jestDomMatchers)

function Probe({ id }: { id: string }) {
  return <p data-testid="probe">{useIntl().formatMessage({ id })}</p>
}

beforeEach(() => {
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

describe('CodesIntlProvider follows the store', () => {
  it('re-renders in ru and kk without reload', () => {
    const text = (l: 'en' | 'ru' | 'kk') => Object.values(codesMessages[l])[0]
    render(
      <CodesIntlProvider>
        <Probe id={Object.keys(codesMessages.en)[0]} />
      </CodesIntlProvider>,
    )
    expect(screen.getByTestId('probe')).toHaveTextContent(text('en'))
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    expect(screen.getByTestId('probe')).toHaveTextContent(text('ru'))
    act(() => useUiLocaleStore.getState().setLocale('kk'))
    expect(screen.getByTestId('probe')).toHaveTextContent(text('kk'))
  })
})
