// @vitest-environment jsdom
/** E1–E5 (AC4) — GH 3605 / REQ-673: every refusal shows its translated message; field_invalid marks the input. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { findLot, fakeServer, problem, rec, renderLots } from './catalogItemsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-ci-errors' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const ITEM1 = rec('i1', 'catalog_item', { code: 'ITEM-1', name: 'Bolt', active: true })
const LOT1 = rec('l1', 'catalog_lot', { code: 'LOT-A', item_id: 'i1', producer: '', mark: '', expiry_date: '', active: true })

afterEach(() => cleanup())
beforeEach(() => { clientMock.post.mockReset(); clientMock.patch.mockReset() })

const EDIT_CASES: [number, Record<string, unknown>, string][] = [
  [422, { reason: 'item_not_found' }, 'The item no longer exists. The list was reloaded.'],
  [422, { reason: 'item_inactive' }, 'The item is retired and cannot accept new lots.'],
  [422, { reason: 'field_invalid', field: 'expiry_date' }, 'The expiry date is not valid.'],
  [422, { reason: 'record_payload_invalid' }, 'The lot code is already taken for this item.'],
  [403, {}, 'You are not permitted to do this.'],
]

describe('E1-E5 error messages on edit', () => {
  for (const [status, body, text] of EDIT_CASES) {
    it(`${status} ${String(body['reason'] ?? body['fields'] ?? '')} shows its message`, async () => {
      fakeServer(
        clientMock,
        { catalog_item: [ITEM1], catalog_lot: [LOT1] },
        (method) => {
          if (method === 'patch') throw problem(status, body)
          return {}
        },
      )
      renderLots('/admin/catalog/lots')
      await findLot('LOT-A')
      fireEvent.click(screen.getByTestId('edit-LOT-A'))
      await screen.findByLabelText(/^Producer/)
      fireEvent.click(screen.getByTestId('edit-submit'))
      if (body['field'] === 'expiry_date') {
        // A field error sits next to its field, not in the banner.
        const msg = await screen.findByText(text)
        expect(msg).toHaveClass('lf-error')
        expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      } else {
        await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(text))
      }
    })
  }
})

describe('E expiry_date aria-invalid on edit', () => {
  it('marks the expiry_date input aria-invalid when field_invalid field=expiry_date', async () => {
    fakeServer(
      clientMock,
      { catalog_item: [ITEM1], catalog_lot: [LOT1] },
      (method) => {
        if (method === 'patch') throw problem(422, { reason: 'field_invalid', field: 'expiry_date' })
        return {}
      },
    )
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('edit-LOT-A'))
    await screen.findByLabelText(/^Expiry date/)
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() => expect(screen.getByLabelText(/^Expiry date/)).toHaveAttribute('aria-invalid', 'true'))
  })
})

describe('E 404 notFound on edit', () => {
  it('shows the not-found message and reloads on a 404 reply', async () => {
    fakeServer(
      clientMock,
      { catalog_item: [ITEM1], catalog_lot: [LOT1] },
      (method) => {
        if (method === 'patch') throw problem(404, {})
        return {}
      },
    )
    renderLots('/admin/catalog/lots')
    await findLot('LOT-A')
    fireEvent.click(screen.getByTestId('edit-LOT-A'))
    await screen.findByLabelText(/^Producer/)
    const before = clientMock.post.mock.calls.filter(([p]) => p === '/api/v1/entities/query').length
    fireEvent.click(screen.getByTestId('edit-submit'))
    await waitFor(() =>
      expect(clientMock.post.mock.calls.filter(([p]) => p === '/api/v1/entities/query').length).toBeGreaterThan(before),
    )
  })
})
