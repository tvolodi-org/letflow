// @vitest-environment jsdom
/**
 * T-1501: /admin/metrics must not show the generic "Something went wrong" when the SPA origin answers
 * /metrics with a non-Prometheus 200 (for example the SPA fallback page). It shows a not-available
 * message; real HTTP errors still get the generic failure with Retry.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { screen, cleanup, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
expect.extend(jestDomMatchers)

vi.mock('react-router-dom', () => ({
  Navigate: ({ to }: { to: string }) => <div data-testid="navigate" data-to={to} />,
}))

vi.mock('@/api/metrics', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/metrics')>()
  return { ...actual, metricsApi: { prometheusText: vi.fn() } }
})

import { metricsApi } from '@/api/metrics'
import MetricsPage from '@/pages/admin/MetricsPage'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { renderWithAccess } from '@/auth/access/testing'

const mockText = vi.mocked(metricsApi.prometheusText)

function renderPage(role: Parameters<typeof renderWithAccess>[1] = 'platformAdmin') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MetricsPage />
    </QueryClientProvider>,
    role,
  )
}

describe('MetricsPage', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('M1: renders families and samples from Prometheus text', async () => {
    mockText.mockResolvedValue('# HELP up Up.\n# TYPE up gauge\nup{job="a"} 1\n')
    renderPage()
    expect(await screen.findByText('up', { selector: 'strong' })).toBeInTheDocument()
    expect(screen.getByText('job=a')).toBeInTheDocument()
  })

  it('M2: an HTML 200 shows the not-available message, no generic failure, no Retry', async () => {
    mockText.mockResolvedValue('<!doctype html><html><body>app</body></html>')
    renderPage()
    expect(await screen.findByText(/not available on this deployment/i)).toBeInTheDocument()
    expect(screen.queryByText(/something went wrong/i)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /retry/i })).not.toBeInTheDocument()
  })

  it('M3: an HTTP 500 keeps the generic failure with Retry', async () => {
    mockText.mockRejectedValue(Object.assign(new Error('boom'), { status: 500 }))
    renderPage()
    await waitFor(() => expect(screen.getByRole('button', { name: /retry/i })).toBeInTheDocument())
    expect(screen.queryByText(/not available on this deployment/i)).not.toBeInTheDocument()
  })

  it('M4: a user without MetricsRead is redirected to /instances', () => {
    mockText.mockResolvedValue('')
    renderPage('taskWorker')
    expect(screen.getByTestId('navigate')).toHaveAttribute('data-to', '/instances')
  })

  it('M5: an empty body shows the no-metrics message', async () => {
    mockText.mockResolvedValue('')
    renderPage()
    expect(await screen.findByText('No metrics are currently exposed.')).toBeInTheDocument()
  })

  it('M6: the not-available banner comes from the catalog (ru) with a text tag', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    try {
      mockText.mockResolvedValue('<!doctype html><html><body>app</body></html>')
      renderPage()
      expect(await screen.findByText(/Метрики недоступны в этой установке/)).toBeInTheDocument()
      expect(screen.getByText('Недоступно.')).toBeInTheDocument()
    } finally {
      useUiLocaleStore.getState().setLocaleTransient('en')
    }
  })
})
