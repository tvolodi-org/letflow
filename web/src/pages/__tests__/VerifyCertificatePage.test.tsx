// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import VerifyCertificatePage from '@/pages/VerifyCertificatePage'
import { clearToken, setToken } from '@/api/client'

function renderPage(handle = 'abc123') {
  return render(
    <MemoryRouter initialEntries={[`/verify/${handle}`]}>
      <Routes>
        <Route path="/verify/:handle" element={<VerifyCertificatePage />} />
      </Routes>
    </MemoryRouter>,
  )
}

const OK = {
  candidate_name: 'Aigerim S.',
  exam_title: 'Safety 101',
  score_pct: 87,
  issued_on: '2026-10-01',
  branding_snapshot: { primary_color: 'oklch(0.5 0.1 200)' },
}

afterEach(() => {
  clearToken()
  cleanup()
  vi.restoreAllMocks()
})

describe('VerifyCertificatePage', () => {
  it('shows valid with projection fields on 200 and sends no Authorization', async () => {
    const fetchMock = vi.spyOn(window, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(OK), { status: 200, headers: { 'content-type': 'application/json' } }),
    )
    setToken('session-token') // a logged-in visitor must still send no credentials
    renderPage('h1')
    expect(await screen.findByTestId('verify-valid')).toBeTruthy()
    expect(screen.getByTestId('verify-candidate-name').textContent).toBe('Aigerim S.')
    expect(screen.getByTestId('verify-exam-title').textContent).toBe('Safety 101')
    expect(screen.getByTestId('verify-score').textContent).toBe('87%')
    expect(screen.getByTestId('verify-issued-on').textContent).toBe('2026-10-01')
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/public/certificate/h1')
    const headers = new Headers(init.headers)
    expect(headers.has('authorization')).toBe(false)
  })

  it('shows not valid on 404 without rendering the error body', async () => {
    vi.spyOn(window, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ title: 'SECRET-DETAIL' }), { status: 404 }),
    )
    renderPage()
    expect(await screen.findByTestId('verify-invalid')).toBeTruthy()
    expect(screen.queryByText(/SECRET-DETAIL/)).toBeNull()
  })

  it('shows the same not valid result on other statuses and network errors', async () => {
    vi.spyOn(window, 'fetch').mockResolvedValueOnce(new Response('x', { status: 500 }))
    const a = renderPage()
    await screen.findByTestId('verify-invalid')
    const htmlStatus = a.container.innerHTML
    a.unmount()

    vi.spyOn(window, 'fetch').mockRejectedValueOnce(new TypeError('network'))
    const b = renderPage()
    await screen.findByTestId('verify-invalid')
    expect(b.container.innerHTML).toBe(htmlStatus)
  })
})
