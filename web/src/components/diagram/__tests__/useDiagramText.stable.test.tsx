// @vitest-environment jsdom
/** T-2738 (pilot gap G9c): `useDiagramText` handed out a NEW object on every render. The designer lists it in the
 *  dependencies of the node and edge lists it gives React Flow, so those lists were new on every render, React Flow's
 *  store was written on every render, and on QA the screen of `platform.register_tenant` died with React error 185
 *  (maximum update depth) in a real browser (jsdom does not run the store feedback, so the page tests stay green).
 *  S1 the object is the same across re-renders of one locale, S2 a locale change gives a new one that answers in it. */
import { describe, it, expect } from 'vitest'
import { renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { IntlProvider } from 'react-intl'
import { useDiagramText } from '../useDiagramText'

const quiet = () => {}
const wrap = (locale: string, messages: Record<string, string>) =>
  function W({ children }: { children: ReactNode }) {
    return <IntlProvider locale={locale} messages={messages} onError={quiet}>{children}</IntlProvider>
  }

describe('T-2738 useDiagramText', () => {
  it('S1 returns the same object across re-renders', () => {
    const { result, rerender } = renderHook(() => useDiagramText(), { wrapper: wrap('en', { 'processDiagram.type.END': 'End' }) })
    const first = result.current
    rerender()
    rerender()
    expect(result.current).toBe(first)
    expect(first.typeName('END')).toBe('End')
  })

  it('S2 follows the locale', () => {
    let locale = 'en'
    const messages: Record<string, Record<string, string>> = { en: { 'processDiagram.type.END': 'End' }, ru: { 'processDiagram.type.END': 'Конец' } }
    const { result, rerender } = renderHook(() => useDiagramText(), {
      wrapper: ({ children }: { children: ReactNode }) => <IntlProvider locale={locale} messages={messages[locale]} onError={quiet}>{children}</IntlProvider>,
    })
    const en = result.current
    locale = 'ru'
    rerender()
    expect(result.current).not.toBe(en)
    expect(result.current.typeName('END')).toBe('Конец')
  })
})
