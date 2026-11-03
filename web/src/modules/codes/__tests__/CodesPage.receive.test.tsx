// @vitest-environment jsdom
/** R1–R4 — GH 3606 / REQ-672: receive in bulk, line-level error marking, batch size, key reuse on retry. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, problem, queryBodies, renderCodes, writeCalls } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const RECEIVE = '/api/v1/modules/codes/receive'

beforeEach(() => {
  clientMock.post.mockReset()
})
afterEach(() => cleanup())

async function openDialog() {
  fireEvent.click(await screen.findByTestId('receive-open'))
  return screen.findByRole('dialog')
}

async function typeAndSubmit(text: string) {
  if (!screen.queryByRole('dialog')) await openDialog()
  const area = await screen.findByLabelText('Values, one per line')
  fireEvent.change(area, { target: { value: text } })
  fireEvent.click(screen.getByTestId('receive-dialog-confirm'))
}

describe('R1 receive sends one call', () => {
  it('posts all non-empty lines in one request with the chosen kind and an idempotency key, then reloads', async () => {
    fakeServer(clientMock, {})
    renderCodes('/admin/codes')
    await openDialog()
    fireEvent.change(await screen.findByLabelText('Kind of the batch'), { target: { value: 'qr' } })
    const before = queryBodies(clientMock, 'code_tag').length
    await typeAndSubmit('A1\r\n\nB2\nC3\n')
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    const [call] = writeCalls(clientMock)
    expect(call.path).toBe(RECEIVE)
    expect(Object.keys(call.body).sort()).toEqual(['entries', 'idempotency_key'])
    expect(call.body['entries']).toEqual([
      { value: 'A1', kind: 'qr' },
      { value: 'B2', kind: 'qr' },
      { value: 'C3', kind: 'qr' },
    ])
    expect(call.body['idempotency_key']).toBeTruthy()
    await waitFor(() => expect(queryBodies(clientMock, 'code_tag').length).toBeGreaterThan(before))
    expect(await screen.findByText('3 codes received')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  })

  it('disables the button for empty input', async () => {
    fakeServer(clientMock, {})
    renderCodes('/admin/codes')
    await openDialog()
    expect(screen.getByTestId('receive-dialog-confirm')).toBeDisabled()
  })
})

describe('R2 entry_invalid marks the line', () => {
  it('names the text line of the refused entry (blank lines counted) and its reason', async () => {
    fakeServer(clientMock, {}, () => {
      throw problem(422, { reason: 'entry_invalid', index: 1, entry_reason: 'duplicate_in_batch' })
    })
    renderCodes('/admin/codes')
    await typeAndSubmit('A1\n\nA1\nZ9')
    expect(await screen.findByText('Line 3: the value is repeated in this batch')).toBeInTheDocument()
    expect(screen.getByLabelText('Values, one per line')).toHaveAttribute('aria-invalid', 'true')
  })
})

describe('R3 batch_size', () => {
  it('shows the limit message with 1000', async () => {
    fakeServer(clientMock, {}, () => {
      throw problem(422, { reason: 'batch_size' })
    })
    renderCodes('/admin/codes')
    await typeAndSubmit('A1')
    expect(await screen.findByText('A batch holds at most 1000 codes.')).toBeInTheDocument()
  })
})

describe('R4 key reuse', () => {
  it('reuses the key for the same text after a failure and takes a new one for an edited text', async () => {
    fakeServer(clientMock, {}, () => {
      throw problem(500, {})
    })
    renderCodes('/admin/codes')
    await typeAndSubmit('A1')
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(1))
    await waitFor(() => expect(screen.getByTestId('receive-dialog-confirm')).not.toBeDisabled())
    fireEvent.click(screen.getByTestId('receive-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(2))
    await waitFor(() => expect(screen.getByTestId('receive-dialog-confirm')).not.toBeDisabled())
    fireEvent.change(screen.getByLabelText('Values, one per line'), { target: { value: 'A1\nA2' } })
    fireEvent.click(screen.getByTestId('receive-dialog-confirm'))
    await waitFor(() => expect(writeCalls(clientMock)).toHaveLength(3))
    const keys = writeCalls(clientMock).map((c) => c.body['idempotency_key'])
    expect(keys[1]).toBe(keys[0])
    expect(keys[2]).not.toBe(keys[0])
  })
})
