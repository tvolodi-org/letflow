// @vitest-environment jsdom
/**
 * GH #3321 / REQ-587 part B (criteria 9-10): the candidate's "My results" screen.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const getBlob = vi.fn()
vi.mock('@/api/client', () => ({
  client: { get: vi.fn(), getBlob: (...args: unknown[]) => getBlob(...args) },
}))

vi.mock('../exam.api', async () => {
  const { client } = await import('@/api/client')
  return {
    examApi: {
      listMySessions: vi.fn(),
      downloadCertificate: (id: string) =>
        client.getBlob(`/api/v1/modules/exam/exam-sessions/${id}/certificate/download`),
    },
  }
})

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 't',
      display_name: 'T',
      loginSource: 'oidc',
      tenant_slug: 's',
      tenant_display_name: 'S',
      tenant_id: 'tid',
      tenant_type: 'test',
    },
    isAuthenticated: true,
  }),
}))

import ExamMyResultsPage from '../ExamMyResultsPage'
import { examApi } from '../exam.api'
import { examMessages, EXAM_UI_LOCALES } from '../examMessages'

const en = examMessages.en
const listMock = examApi.listMySessions as unknown as ReturnType<typeof vi.fn>

function item(over: Record<string, unknown> = {}) {
  return {
    session_id: 's1',
    exam_id: 'e1',
    exam_title: 'Algebra',
    status: 'submitted',
    started_at: null,
    submitted_at: null,
    score_pct: 80,
    passed: true,
    certificate_issued: false,
    certificate_id: null,
    ...over,
  }
}

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <ExamMyResultsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  URL.createObjectURL = vi.fn(() => 'blob:x')
  URL.revokeObjectURL = vi.fn()
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
})
afterEach(cleanup)

describe('REQ-587 AC9 — My results screen states', () => {
  it('(a) shows loading while the call is pending', () => {
    listMock.mockReturnValue(new Promise(() => {}))
    renderPage()
    expect(screen.getByLabelText('Loading content')).toBeInTheDocument()
  })

  it('(b) one row per item with title, status, score, outcome and a result link', async () => {
    listMock.mockResolvedValue({
      items: [item(), item({ session_id: 's2', exam_title: 'Geometry', passed: false, score_pct: 20 })],
      next_cursor: null,
    })
    renderPage()
    await screen.findByTestId('exam-my-results-row-s1')
    expect(screen.getByTestId('exam-my-results-row-s2')).toHaveTextContent('Geometry')
    expect(screen.getByTestId('exam-my-results-row-s1')).toHaveTextContent('Algebra')
    expect(screen.getByTestId('exam-my-results-row-s1')).toHaveTextContent('80.0%')
    expect(screen.getByTestId('exam-my-results-outcome-s1')).toHaveTextContent(en['exam.myResults.passed'])
    expect(screen.getByTestId('exam-my-results-outcome-s2')).toHaveTextContent(en['exam.myResults.failed'])
    expect(screen.getByTestId('exam-my-results-link-s1')).toHaveAttribute('href', '/exam/sessions/s1/result')
  })

  it('(c) shows the empty state', async () => {
    listMock.mockResolvedValue({ items: [], next_cursor: null })
    renderPage()
    expect(await screen.findByTestId('exam-my-results-empty')).toBeInTheDocument()
  })

  it('(d) shows the failure state and retries', async () => {
    listMock.mockRejectedValueOnce(new Error('boom'))
    listMock.mockResolvedValueOnce({ items: [item()], next_cursor: null })
    renderPage()
    await screen.findByTestId('exam-my-results-error')
    fireEvent.click(screen.getByTestId('exam-my-results-retry'))
    await screen.findByTestId('exam-my-results-row-s1')
    expect(listMock).toHaveBeenCalledTimes(2)
  })

  it('(e) Download certificate only on rows with passed true', async () => {
    listMock.mockResolvedValue({
      items: [item(), item({ session_id: 's2', passed: false }), item({ session_id: 's3', passed: null })],
      next_cursor: null,
    })
    renderPage()
    await screen.findByTestId('exam-my-results-row-s1')
    expect(screen.getByTestId('exam-my-results-download-s1')).toBeInTheDocument()
    expect(screen.queryByTestId('exam-my-results-download-s2')).toBeNull()
    expect(screen.queryByTestId('exam-my-results-download-s3')).toBeNull()
  })

  it('(f) next-page control only when next_cursor is non-null, and it passes the cursor', async () => {
    listMock.mockResolvedValueOnce({ items: [item()], next_cursor: 'cur2' })
    listMock.mockResolvedValueOnce({ items: [item({ session_id: 's9' })], next_cursor: null })
    renderPage()
    fireEvent.click(await screen.findByTestId('exam-my-results-next-page'))
    await screen.findByTestId('exam-my-results-row-s9')
    expect(listMock).toHaveBeenLastCalledWith({ cursor: 'cur2', page_size: 20 })
    expect(screen.queryByTestId('exam-my-results-next-page')).toBeNull()
  })
})

describe('REQ-587 AC10 — certificate download and i18n', () => {
  it('downloads once through client.getBlob and saves the PDF', async () => {
    getBlob.mockResolvedValue({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), contentType: 'application/pdf' })
    listMock.mockResolvedValue({ items: [item()], next_cursor: null })
    renderPage()
    fireEvent.click(await screen.findByTestId('exam-my-results-download-s1'))
    await waitFor(() => expect(URL.createObjectURL).toHaveBeenCalledTimes(1))
    expect(getBlob).toHaveBeenCalledTimes(1)
    expect(getBlob).toHaveBeenCalledWith('/api/v1/modules/exam/exam-sessions/s1/certificate/download')
  })

  for (const status of [409, 404, 500]) {
    it(`on ${status} shows the failure message, keeps the list and allows a retry`, async () => {
      getBlob.mockRejectedValueOnce({ status })
      getBlob.mockResolvedValueOnce({ blob: new Blob(['%PDF']), contentType: 'application/pdf' })
      listMock.mockResolvedValue({ items: [item()], next_cursor: null })
      renderPage()
      fireEvent.click(await screen.findByTestId('exam-my-results-download-s1'))
      expect(await screen.findByTestId('exam-my-results-download-error-s1')).toHaveTextContent(
        en['exam.myResults.downloadFailed'],
      )
      expect(screen.getByTestId('exam-my-results-row-s1')).toBeInTheDocument()
      fireEvent.click(screen.getByTestId('exam-my-results-download-s1'))
      await waitFor(() => expect(getBlob).toHaveBeenCalledTimes(2))
      await waitFor(() => expect(screen.queryByTestId('exam-my-results-download-error-s1')).toBeNull())
    })
  }

  it('every myResults string exists in every locale', () => {
    const ids = Object.keys(en).filter((k) => k.startsWith('exam.myResults.') || k === 'exam.list.myResultsLink')
    expect(ids.length).toBeGreaterThan(10)
    for (const locale of EXAM_UI_LOCALES) {
      for (const id of ids) expect(examMessages[locale][id], `${locale} ${id}`).toBeTruthy()
    }
  })
})
