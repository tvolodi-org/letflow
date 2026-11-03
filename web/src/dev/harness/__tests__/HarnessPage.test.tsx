// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { HarnessPage } from '../HarnessPage'
import { HARNESS_SCREENS } from '../registry'
import { makeFixtureFetch } from '../fixtureFetch'
import { router } from '@/router'

function renderHarness(query: string, screenName = 'verify-certificate') {
  return render(
    <MemoryRouter initialEntries={[`/__harness/${screenName}${query}`]}>
      <Routes>
        <Route path="/__harness/:screen/*" element={<HarnessPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

afterEach(() => {
  cleanup()
  document.documentElement.removeAttribute('data-theme')
  document.documentElement.removeAttribute('lang')
  window.localStorage.clear()
})

describe('HarnessPage', () => {
  it('default state: renders the screen from fixture data, no backend', async () => {
    renderHarness('')
    expect(await screen.findByTestId('verify-valid')).toBeTruthy()
    expect(screen.getByTestId('verify-candidate-name').textContent).toBe('Aigerim Sarsenova')
  })

  it('empty state: the screen shows its not-valid result', async () => {
    renderHarness('?state=empty')
    expect(await screen.findByTestId('verify-invalid')).toBeTruthy()
  })

  it('error state: a 500 from the fixture seam', async () => {
    renderHarness('?state=error')
    expect(await screen.findByTestId('verify-invalid')).toBeTruthy()
  })

  it('loading state: the request never answers', async () => {
    renderHarness('?state=loading')
    expect(await screen.findByTestId('verify-loading')).toBeTruthy()
    await new Promise(r => setTimeout(r, 30))
    expect(screen.queryByTestId('verify-valid')).toBeNull()
  })

  it('sets theme and lang on <html> without touching the stored theme', () => {
    renderHarness('?theme=dark&lang=kk')
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark')
    expect(document.documentElement.lang).toBe('kk')
    expect(window.localStorage.getItem('lf-theme')).toBeNull()
  })

  it('an unknown theme, lang or state falls back to light, en, default', async () => {
    renderHarness('?theme=neon&lang=xx&state=weird')
    expect(await screen.findByTestId('verify-valid')).toBeTruthy()
    expect(document.documentElement.getAttribute('data-theme')).toBe('light')
    expect(document.documentElement.lang).toBe('en')
  })

  it('an unknown screen lists the registered ones', () => {
    renderHarness('', 'nope')
    expect(screen.getByTestId('harness-unknown').textContent).toContain('verify-certificate')
  })

  it('restores the real fetch on unmount', () => {
    const before = window.fetch
    const view = renderHarness('')
    expect(window.fetch).not.toBe(before)
    view.unmount()
    expect(window.fetch).toBe(before)
  })
})

describe('codes screens (S4)', () => {
  it('lists the invented codes in the requested language, with the write actions', async () => {
    renderHarness('?lang=ru', 'codes')
    expect(await screen.findByText('GATEA-BC-0001')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Коды')
    expect(screen.getAllByRole('button', { name: 'Приём кодов' }).length).toBeGreaterThan(0)
  })

  it('opens the detail panel, the assign dialog and the receive dialog from their presets', async () => {
    renderHarness('', 'codes-detail')
    expect(await screen.findByTestId('codes-detail')).toBeTruthy()
    cleanup()
    renderHarness('', 'codes-assign')
    expect(await screen.findByTestId('assign-dialog')).toBeTruthy()
    cleanup()
    renderHarness('', 'codes-receive')
    expect(await screen.findByTestId('receive-dialog')).toBeTruthy()
  })

  it('empty state shows the receive action', async () => {
    renderHarness('?state=empty', 'codes')
    expect(await screen.findByTestId('datatable-empty-state')).toBeTruthy()
  })
})

describe('fixture fetch seam', () => {
  it('answers 404 for a request no fixture matches', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const f = makeFixtureFetch(HARNESS_SCREENS['verify-certificate'].routes, 'default')
    expect((await f('/api/other')).status).toBe(404)
  })
})

describe('router in dev', () => {
  it('mounts the harness route (import.meta.env.DEV is true under vitest)', () => {
    expect(import.meta.env.DEV).toBe(true)
    expect(router.routes.map(r => r.path)).toContain('/__harness/:screen/*')
  })
})
