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
import { SUMMARY_MESSAGES } from '@/pages/admin/MetricsSummaryPanel'
import { renderWithAccess } from '@/auth/access/testing'

const POOL = (used: number, cap: number) =>
  `\n# TYPE letflow_db_admission_in_use gauge\nletflow_db_admission_in_use ${used}\n# TYPE letflow_db_admission_cap gauge\nletflow_db_admission_cap ${cap}\n`

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

  const counters = (req: number, err: number) =>
    `letflow_http_requests_total{method="GET",route_template="/a",status="200"} ${req}\nletflow_http_errors_total{route_template="/a"} ${err}\n`

  it('P1/P2: first poll measures, second poll shows a red error rate with its sentence and routes', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    try {
      vi.setSystemTime(new Date('2026-01-01T00:00:00Z'))
      mockText.mockResolvedValue(counters(0, 0))
      const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      renderWithAccess(
        <QueryClientProvider client={qc}>
          <MetricsPage />
        </QueryClientProvider>,
        'platformAdmin',
      )
      expect(await screen.findByTestId('support-summary')).toBeInTheDocument()
      expect(screen.getAllByText('Measuring…').length).toBe(2)
      expect(screen.queryByText(/NaN/)).not.toBeInTheDocument()
      expect(screen.getByText('letflow_http_errors_total', { selector: 'strong' })).toBeInTheDocument()

      vi.setSystemTime(new Date('2026-01-01T00:01:00Z'))
      mockText.mockResolvedValue(counters(1000, 100))
      await qc.refetchQueries()
      await waitFor(() => expect(screen.getByTestId('figure-errors-status')).toHaveTextContent('Problem'))
      expect(screen.getByText(SUMMARY_MESSAGES.en.errorsDo)).toBeInTheDocument()
      expect(screen.getByTestId('error-routes')).toHaveTextContent('/a (100)')
    } finally {
      vi.useRealTimers()
    }
  })

  it('P3: the three unmeasured items say Not measured yet with a missing-source sentence and no number', async () => {
    mockText.mockResolvedValue(counters(1, 0))
    renderPage()
    const cards = await screen.findAllByTestId('figure-unmeasured')
    expect(cards).toHaveLength(3)
    const sentences = [SUMMARY_MESSAGES.en.jobsDo, SUMMARY_MESSAGES.en.modulesDo, SUMMARY_MESSAGES.en.upgradeDo]
    expect(new Set(sentences).size).toBe(3)
    cards.forEach((c, i) => {
      expect(c).toHaveTextContent('Not measured yet')
      expect(c).toHaveTextContent(sentences[i])
      expect(c.textContent ?? '').not.toMatch(/\d/)
    })
  })

  it('P3a: pool card shows slots in use with status OK', async () => {
    mockText.mockResolvedValue(counters(1, 0) + POOL(2, 10))
    renderPage()
    const card = await screen.findByTestId('figure-pool')
    expect(card).toHaveTextContent('2 / 10 slots in use')
    expect(screen.getByTestId('figure-pool-status')).toHaveTextContent('OK')
  })

  it('P3b: pool at 9 of 10 is a Problem with its sentence', async () => {
    mockText.mockResolvedValue(counters(1, 0) + POOL(9, 10))
    renderPage()
    const card = await screen.findByTestId('figure-pool')
    expect(screen.getByTestId('figure-pool-status')).toHaveTextContent('Problem')
    expect(card).toHaveTextContent(SUMMARY_MESSAGES.en.poolDo)
  })

  it('P3c: pool gauges absent shows No data and no number', async () => {
    mockText.mockResolvedValue(counters(1, 0))
    renderPage()
    const card = await screen.findByTestId('figure-pool')
    expect(screen.getByTestId('figure-pool-status')).toHaveTextContent('No data')
    expect(card.textContent ?? '').not.toMatch(/\d/)
  })

  it('P4: ru renders the translated panel', async () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    try {
      mockText.mockResolvedValue(counters(1, 0))
      renderPage()
      expect(await screen.findByText(SUMMARY_MESSAGES.ru.heading)).toBeInTheDocument()
      expect(screen.getAllByText(SUMMARY_MESSAGES.ru.notMeasured).length).toBe(3)
    } finally {
      useUiLocaleStore.getState().setLocaleTransient('en')
    }
  })

  it('P5: en, ru and kk summary messages have the same keys', () => {
    const keys = (o: object) => Object.keys(o).sort()
    expect(keys(SUMMARY_MESSAGES.ru)).toEqual(keys(SUMMARY_MESSAGES.en))
    expect(keys(SUMMARY_MESSAGES.kk)).toEqual(keys(SUMMARY_MESSAGES.en))
  })
})
