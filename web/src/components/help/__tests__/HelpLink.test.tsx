// @vitest-environment jsdom
/** HL7 HL8 HL9 — T-1872: the Help link is a side panel, never a navigation: texts in en/ru/kk, no router import,
 *  full-width panel at phone size with a Close button. */
import { readFileSync } from 'node:fs'
import { afterEach, describe, expect, it } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { CoreHelpLink } from '@/pages/help/CoreHelpLink'
import { HelpLink } from '../HelpLink'

expect.extend(jestDomMatchers)
afterEach(() => cleanup())

const Where = () => <span data-testid="where">{useLocation().pathname}</span>

describe('HL7 texts in the three languages (core topic, own IntlProvider)', () => {
  it.each([
    ['en', 'Help', 'Close'],
    ['ru', 'Справка', 'Закрыть'],
    ['kk', 'Анықтама', 'Жабу'],
  ] as const)('%s: link, Close and panel title; opening and closing does not change the route', (locale, link, close) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    render(
      <MemoryRouter initialEntries={['/admin/users/import']}>
        <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['UsersImport', 'UsersManage'] } }}>
          <CoreHelpLink topic="instanceReplay" />
        </AccessStateProvider>
        <Where />
      </MemoryRouter>,
    )
    expect(screen.getByTestId('help-link')).toHaveTextContent(link)
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getByRole('dialog')).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByTestId('help-side-close')).toHaveTextContent(close)
    expect(screen.getByTestId('help-side-title').textContent).toBeTruthy()
    expect(screen.getByTestId('help-purpose-text').textContent).toBeTruthy()
    expect(screen.getByTestId('where')).toHaveTextContent('/admin/users/import')
    fireEvent.click(screen.getByTestId('help-side-close'))
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(screen.getByTestId('where')).toHaveTextContent('/admin/users/import')
  })
  it('follows a language switch while open without closing the panel', () => {
    useUiLocaleStore.getState().setLocaleTransient('en')
    render(
      <MemoryRouter>
        <CoreHelpLink topic="instanceReplay" defaultOpen />
      </MemoryRouter>,
    )
    expect(screen.getByTestId('help-side-close')).toHaveTextContent('Close')
    act(() => useUiLocaleStore.getState().setLocaleTransient('ru'))
    expect(screen.getByTestId('help-side-close')).toHaveTextContent('Закрыть')
  })
})

describe('HL8 Help is not a navigation', () => {
  it('HelpLink and HelpSidePanel import nothing from react-router-dom and render no anchor', () => {
    for (const f of ['../HelpLink.tsx', '../HelpSidePanel.tsx']) {
      const src = readFileSync(new URL(f, import.meta.url), 'utf8')
      expect(src, f).not.toMatch(/react-router/)
      expect(src, f).not.toMatch(/<a\s|<Link|navigate\(|window\.open|target=/)
    }
  })
})

describe('HL9 phone width', () => {
  it('the panel is at most 420px and never wider than the viewport (100vw), with a Close button in a sticky header', () => {
    render(
      <HelpLink label="Help" closeLabel="Close" title="T" defaultOpen>
        <p>body</p>
      </HelpLink>,
    )
    const panel = screen.getByTestId('help-side-panel')
    expect(panel.style.width).toBe('min(420px, 100vw)')
    expect(screen.getByTestId('help-side-close').parentElement?.style.position).toBe('sticky')
  })
  it('a second click on Help does not stack panels', () => {
    render(
      <HelpLink label="Help" closeLabel="Close" title="T">
        <p>body</p>
      </HelpLink>,
    )
    fireEvent.click(screen.getByTestId('help-link'))
    expect(screen.getAllByTestId('help-side-panel')).toHaveLength(1)
  })
})
