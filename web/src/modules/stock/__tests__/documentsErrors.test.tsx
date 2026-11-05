// @vitest-environment jsdom
/** C5 — GH 3769 / REQ-722: each refusal shows its own message in the active language; 404, 403, 503 busy. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { DOC_EXTRA_REASONS, DOC_REASONS } from '../documents/documentsModel'
import { stockMessages } from '../stockMessages'
import { LIST, fakeDocument, fakeMasters, refusal, renderStock, stockDoc, withAll, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const VIEW = `${LIST}/d1`
const ALL = [...DOC_REASONS, ...DOC_EXTRA_REASONS]

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  fakeDocument(clientMock, stockDoc())
  window.localStorage.clear()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => {
  cleanup()
  window.localStorage.clear()
  useUiLocaleStore.getState().reloadFromEnvironment()
})

async function issueRefused(err: unknown) {
  const post = clientMock.post
  const base = post.getMockImplementation()!
  post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
    if (p.endsWith('/issue')) throw err
    return base(p, b)
  })
  renderStock(VIEW, withPost)
  fireEvent.click(await screen.findByRole('button', { name: /^(Issue|Выпустить|Шығару)$/ }))
  fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
}

describe('C5-a every reason in every language', () => {
  for (const locale of ['en', 'ru', 'kk'] as const) {
    it(`${locale}: all ${ALL.length} reasons show their own message`, async () => {
      useUiLocaleStore.getState().setLocaleTransient(locale)
      const seen = new Set<string>()
      for (const reason of ALL) {
        cleanup()
        await issueRefused(refusal(reason === 'busy' ? 503 : 422, reason))
        const text = stockMessages[locale][`stock.doc.error.${reason}`]
        expect(text, reason).toBeTruthy()
        const box = await screen.findByTestId('confirm-dialog-error')
        expect(box).toHaveTextContent(text)
        seen.add(text)
      }
      expect(seen.size).toBe(ALL.length)
    })
  }
})

describe('C5-b statuses', () => {
  it('403 says not permitted, an unknown reason the generic refusal, 503 busy try again', async () => {
    await issueRefused(refusal(403))
    expect(await screen.findByTestId('confirm-dialog-error')).toHaveTextContent('You are not permitted to do this.')
    cleanup()
    await issueRefused(refusal(422, 'brand_new'))
    expect(await screen.findByTestId('confirm-dialog-error')).toHaveTextContent('The server refused the request.')
    cleanup()
    await issueRefused(refusal(503, 'busy'))
    expect(await screen.findByTestId('confirm-dialog-error')).toHaveTextContent('Try again in a moment')
  })
  it('404 on the view shows the not-found state, 500 an error with retry', async () => {
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(404))
    renderStock(VIEW)
    expect(await screen.findByText('This view is not available to you.')).toBeInTheDocument()
    cleanup()
    clientMock.get.mockReset()
    clientMock.get.mockRejectedValue(refusal(500))
    renderStock(VIEW)
    expect(await screen.findByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
  it('a reversal refusal stays in the reason dialog', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'posted' }))
    const base = clientMock.post.getMockImplementation()!
    clientMock.post.mockImplementation(async (p: string, b: Record<string, unknown>) => {
      if (p.endsWith('/reverse')) throw refusal(409, 'document_reversed')
      return base(p, b)
    })
    renderStock(VIEW, withAll)
    fireEvent.click(await screen.findByRole('button', { name: 'Reverse' }))
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'wrong_document' } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    const box = await screen.findByTestId('reason-dialog-error')
    expect(within(box).getByText('The document is already reversed.')).toBeInTheDocument()
    expect(clientMock.delete).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.getByTestId('reason-dialog')).toBeInTheDocument())
  })
})
