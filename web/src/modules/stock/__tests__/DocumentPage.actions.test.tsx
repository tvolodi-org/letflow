// @vitest-environment jsdom
/** C4 — GH 3769 / REQ-722: the document view and its actions (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import {
  DOCS, LIST, fakeDocument, fakeMasters, postsTo, renderStock, stockDoc, withAll, withAtom, withPost, withReverse,
} from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const VIEW = `${LIST}/d1`
const BUTTONS = ['Edit', 'Discard', 'Issue', 'Retry posting', 'Reverse', 'Cancel document']
const present = () => BUTTONS.filter((b) => screen.queryByRole('button', { name: b }) !== null)

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
  fakeDocument(clientMock, stockDoc())
})
afterEach(() => cleanup())

describe('C4-a view', () => {
  it('shows header, lines in line_no order with names, and posting facts', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'reversed', number: 'RC-1', posted_at: '2026-11-04T06:00:00Z', posted_by: 'u-poster', reversed_at: '2026-11-04T07:00:00Z', reversed_by: 'u-rev' }))
    renderStock(VIEW)
    await screen.findByTestId('document-lines')
    expect(clientMock.get).toHaveBeenCalledWith(`${DOCS}/d1`)
    await waitFor(() => expect(within(screen.getAllByTestId('line-row')[0]).getByText('Bolt M8')).toBeInTheDocument())
    const rows = screen.getAllByTestId('line-row')
    expect(rows.map((r) => r.querySelector('td')?.textContent)).toEqual(['1', '2'])
    expect(within(rows[1]).getByText('LOT-9')).toBeInTheDocument()
    const head = screen.getByTestId('document-header')
    expect(head).toHaveTextContent('u-poster')
    expect(head).toHaveTextContent('u-rev')
    expect(head).toHaveTextContent('11/04/2026, 11:00')
    expect(screen.queryByText('Posting check')).not.toBeInTheDocument()
  })
  it('warns when posting_check is mismatch only', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'posted', posting_check: 'mismatch' }))
    renderStock(VIEW)
    expect(await screen.findByText('Posting check')).toBeInTheDocument()
    cleanup()
    fakeDocument(clientMock, stockDoc({ state: 'posted', posting_check: 'ok' }))
    renderStock(VIEW)
    await screen.findByTestId('document-lines')
    expect(screen.queryByText('Posting check')).not.toBeInTheDocument()
  })
})

describe('C4-b draft', () => {
  it('Discard and Issue call after a confirm and re-read', async () => {
    renderStock(VIEW, withPost)
    fireEvent.click(await screen.findByRole('button', { name: 'Issue' }))
    expect(postsTo(clientMock, 'd1/issue')).toHaveLength(0)
    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(postsTo(clientMock, 'd1/issue')).toEqual([[`${DOCS}/d1/issue`]]))
    await waitFor(() => expect(clientMock.get.mock.calls.filter(([p]) => p === `${DOCS}/d1`).length).toBeGreaterThan(1))
    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))
    expect(clientMock.delete).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(clientMock.delete).toHaveBeenCalledWith(`${DOCS}/d1`))
  })
})

describe('C4-c issued', () => {
  beforeEach(() => fakeDocument(clientMock, stockDoc({ state: 'issued', number: 'RC-1' })))
  it('shows the waiting text with the task inbox link, Retry and Cancel with the typed reason', async () => {
    renderStock(VIEW, withAll)
    expect(await screen.findByText('Posting waits for the post task in the task inbox.')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open the task inbox' })).toHaveAttribute('href', '/tasks')
    fireEvent.click(screen.getByRole('button', { name: 'Retry posting' }))
    await waitFor(() => expect(postsTo(clientMock, 'd1/post')).toHaveLength(1))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel document' }))
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    expect(postsTo(clientMock, 'd1/cancel')).toHaveLength(0)
    fireEvent.change(screen.getByLabelText('Reason text'), { target: { value: 'entered twice' } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    await waitFor(() => expect(postsTo(clientMock, 'd1/cancel')).toEqual([[`${DOCS}/d1/cancel`, { reason: 'entered twice' }]]))
  })
})

describe('C4-d posted and reversed', () => {
  it('Reverse sends the code, blocks other without text and text over 500', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'posted', number: 'RC-1' }))
    renderStock(VIEW, withReverse)
    fireEvent.click(await screen.findByRole('button', { name: 'Reverse' }))
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'other' } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    expect(postsTo(clientMock, 'd1/reverse')).toHaveLength(0)
    expect(screen.getByText('Give the reason text.')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Reason text'), { target: { value: 'x'.repeat(501) } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    expect(postsTo(clientMock, 'd1/reverse')).toHaveLength(0)
    fireEvent.change(screen.getByLabelText('Reason text'), { target: { value: 'fix' } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    await waitFor(() => expect(postsTo(clientMock, 'd1/reverse')).toEqual([[`${DOCS}/d1/reverse`, { reason_code: 'other', reason_text: 'fix' }]]))
  })
  it('a code without text is sent with the code only', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'posted' }))
    renderStock(VIEW, withReverse)
    fireEvent.click(await screen.findByRole('button', { name: 'Reverse' }))
    fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'wrong_quantity' } })
    fireEvent.click(screen.getByTestId('reason-dialog-confirm'))
    await waitFor(() => expect(postsTo(clientMock, 'd1/reverse')).toEqual([[`${DOCS}/d1/reverse`, { reason_code: 'wrong_quantity' }]]))
  })
  it('reversed offers Cancel only, cancelled nothing', async () => {
    fakeDocument(clientMock, stockDoc({ state: 'reversed' }))
    renderStock(VIEW, withAll)
    await screen.findByTestId('document-lines')
    expect(present()).toEqual(['Cancel document'])
    cleanup()
    fakeDocument(clientMock, stockDoc({ state: 'cancelled' }))
    renderStock(VIEW, withAll)
    await screen.findByTestId('document-lines')
    expect(present()).toEqual([])
  })
})

describe('C4-e matrix', () => {
  const sets = { read: withAtom, post: withPost, reverse: withReverse } as const
  const want: Record<string, Record<keyof typeof sets, string[]>> = {
    draft: { read: [], post: ['Edit', 'Discard', 'Issue'], reverse: [] },
    issued: { read: [], post: ['Retry posting'], reverse: ['Cancel document'] },
    posted: { read: [], post: [], reverse: ['Reverse'] },
    reversed: { read: [], post: [], reverse: ['Cancel document'] },
    cancelled: { read: [], post: [], reverse: [] },
  }
  for (const [state, bySet] of Object.entries(want)) {
    for (const [name, expected] of Object.entries(bySet)) {
      it(`${state} with ${name}: ${expected.join(', ') || 'no buttons'}`, async () => {
        fakeDocument(clientMock, stockDoc({ state }))
        renderStock(VIEW, sets[name as keyof typeof sets])
        await screen.findByTestId('document-lines')
        expect(present()).toEqual(BUTTONS.filter((b) => expected.includes(b)))
      })
    }
  }
})
