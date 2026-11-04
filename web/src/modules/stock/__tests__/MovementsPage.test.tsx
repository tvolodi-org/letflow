// @vitest-environment jsdom
/** M1–M5 — GH 3767 / REQ-724: the movements screen (network mocked). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { MOV, fakeMasters, renderStock, routeCalls } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const LEG = { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1' }
const ENTRY = {
  entry_id: 'en1',
  posting_seq: 17,
  cause: 'transfer',
  reason_code: 'wrong_quantity',
  document_type: 'stock_transfer',
  document_id: 'd1',
  event_time: '2026-11-04T18:00:00Z',
  legs: [
    { ...LEG, leg_no: 1, quantity: '-5' },
    { ...LEG, leg_no: 2, location: 'l1', quantity: '5' },
  ],
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.get.mockReset()
  fakeMasters(clientMock)
  clientMock.get.mockResolvedValue({ next_cursor: null, rows: [ENTRY] })
})
afterEach(() => cleanup())

describe('M1 query keys', () => {
  it('filters send only cause, document_id, from_seq and to_seq', async () => {
    renderStock(MOV)
    await screen.findByText('17')
    expect(routeCalls(clientMock, 'movements')).toEqual([{}])
    fireEvent.change(screen.getByLabelText('Cause'), { target: { value: 'receipt' } })
    await waitFor(() => expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cause: 'receipt' }))
    fireEvent.change(screen.getByLabelText('Document'), { target: { value: 'doc-9' } })
    fireEvent.change(screen.getByLabelText('From posting no.'), { target: { value: '3x' } })
    fireEvent.change(screen.getByLabelText('To posting no.'), { target: { value: '9' } })
    await waitFor(() =>
      expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cause: 'receipt', document_id: 'doc-9', from_seq: '3', to_seq: '9' }),
    )
  })

  it('presets the document from the URL query key', async () => {
    renderStock(`${MOV}?document_id=d1`)
    await screen.findByText('17')
    expect(screen.getByLabelText('Document')).toHaveValue('d1')
    expect(routeCalls(clientMock, 'movements')).toEqual([{ document_id: 'd1' }])
  })
})

describe('M2 range', () => {
  it('a from above to is not sent and the field is marked', async () => {
    renderStock(MOV)
    await screen.findByText('17')
    fireEvent.change(screen.getByLabelText('From posting no.'), { target: { value: '9' } })
    fireEvent.change(screen.getByLabelText('To posting no.'), { target: { value: '3' } })
    expect((await screen.findAllByText('The first number is above the last.')).length).toBeGreaterThan(0)
    expect(screen.getByLabelText('From posting no.')).toHaveAttribute('aria-invalid', 'true')
    expect(routeCalls(clientMock, 'movements').some((p) => 'from_seq' in p && 'to_seq' in p)).toBe(false)
  })
})

describe('M3 rows and legs', () => {
  it('shows the row cells and the legs of a two-leg entry with names and signed quantity', async () => {
    renderStock(MOV)
    const row = (await screen.findByText('17')).closest('tr')!
    expect(within(row).getAllByText('Transfer')).toHaveLength(2)
    expect(row).toHaveTextContent('wrong_quantity')
    expect(row).toHaveTextContent('11/04/2026, 23:00:00')
    fireEvent.click(within(row).getByRole('button', { name: 'Show legs' }))
    const legs = await screen.findAllByTestId('leg-row')
    expect(legs).toHaveLength(2)
    await waitFor(() => expect(legs[0]).toHaveTextContent('Bolt M8'))
    expect(legs[0]).toHaveTextContent('Shelf A')
    expect(legs[0]).toHaveTextContent('Aigul B.')
    expect(legs[0]).toHaveTextContent('pcs')
    expect(legs[0]).toHaveTextContent('-5')
    expect(legs[1]).toHaveTextContent('5')
  })
})

describe('M4 masked leg', () => {
  it('shows quantity, unit and the hidden unit text and no slot', async () => {
    clientMock.get.mockResolvedValue({
      next_cursor: null,
      rows: [{ ...ENTRY, legs: [{ leg_no: 1, quantity: '-4', unit_ref: 'm1', masked: true }] }],
    })
    renderStock(MOV)
    fireEvent.click(await screen.findByRole('button', { name: 'Show legs' }))
    const leg = await screen.findByTestId('leg-row')
    expect(leg).toHaveTextContent('Hidden unit')
    expect(leg).toHaveTextContent('-4')
    await waitFor(() => expect(leg).toHaveTextContent('pcs'))
    expect(leg).not.toHaveTextContent('Bolt M8')
  })
})

describe('M5 paging', () => {
  it('Load more sends the cursor and appends', async () => {
    clientMock.get.mockImplementation(async (_p: string, params: Record<string, string>) =>
      params?.cursor === 'c2'
        ? { next_cursor: null, rows: [{ ...ENTRY, entry_id: 'en2', posting_seq: 16 }] }
        : { next_cursor: 'c2', rows: [ENTRY] },
    )
    renderStock(MOV)
    fireEvent.click(await screen.findByTestId('load-more'))
    await screen.findByText('16')
    expect(screen.getByText('17')).toBeInTheDocument()
    expect(routeCalls(clientMock, 'movements').at(-1)).toEqual({ cursor: 'c2' })
    expect(screen.queryByTestId('load-more')).not.toBeInTheDocument()
  })
})
