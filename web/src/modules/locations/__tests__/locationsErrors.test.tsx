// @vitest-environment jsdom
/** E1, E2 — GH 3607 / REQ-671: every refusal reason shows its message; 404 reloads; 403 is named. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, problem, queryBodies, rec, renderLocations } from './locationsTestKit'
import { locationsMessages } from '../locationsMessages'
import { LOCATION_REASONS } from '../locationsModel'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const DATA = {
  location_node: [rec('l-1', 'location_node', { code: 'L1', name: 'Loc one', node_kind: 'zone' })],
  org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Unit one' })],
  location_org_unit_link: [rec('k-1', 'location_org_unit_link', { org_unit_id: 'u-1', location_id: 'l-1' })],
}
const en = locationsMessages.en

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

async function saveNodeWith(err: unknown) {
  fakeServer(clientMock, DATA, () => {
    throw err
  })
  renderLocations('/admin/locations')
  await screen.findByTestId('loc-row-L1')
  fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
  fireEvent.click(screen.getByTestId('loc-save'))
}

async function unlinkWith(err: unknown) {
  fakeServer(clientMock, DATA, () => {
    throw err
  })
  renderLocations('/admin/locations/links')
  await screen.findByLabelText('Org unit')
  fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
  fireEvent.click(await screen.findByRole('button', { name: 'Unlink' }))
}

describe('E1 reasons', () => {
  for (const reason of LOCATION_REASONS) {
    it(`shows the message of ${reason} and keeps the form open`, async () => {
      const status = reason === 'idempotency_key_reuse' ? 409 : 422
      await saveNodeWith(problem(status, { reason, field: 'address', fields: ['code', 'address'] }))
      const alert = await screen.findByRole('alert')
      expect(alert).toHaveTextContent(en[`locations.error.${reason}`].replace('{fields}', 'code, address'))
      expect(screen.getByTestId('loc-save')).toBeInTheDocument()
    })
  }

  it('marks the segment and the address inputs named by field_invalid / record_payload_invalid', async () => {
    await saveNodeWith(problem(422, { reason: 'field_invalid', field: 'segment' }))
    await screen.findByRole('alert')
    expect(screen.getByLabelText('Segment')).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByLabelText('Address')).not.toHaveAttribute('aria-invalid')
    cleanup()
    clientMock.post.mockReset()
    await saveNodeWith(problem(422, { reason: 'record_payload_invalid', fields: ['address'] }))
    await screen.findByRole('alert')
    expect(screen.getByLabelText('Address')).toHaveAttribute('aria-invalid', 'true')
  })

  it('a link 404 shows the link_not_found text', async () => {
    await unlinkWith(problem(404, {}))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['locations.error.link_not_found'])
  })
})

describe('E2 generic answers', () => {
  it('maps 403, 409, unknown 422 and 500', async () => {
    const cases: [unknown, string][] = [
      [problem(403, {}), 'locations.error.forbidden'],
      [problem(409, { reason: 'idempotency_key_reuse' }), 'locations.error.idempotency_key_reuse'],
      [problem(422, { reason: 'brand_new' }), 'locations.error.unknown'],
      [problem(500, {}), 'locations.error.generic'],
    ]
    for (const [err, id] of cases) {
      clientMock.post.mockReset()
      await saveNodeWith(err)
      expect(await screen.findByRole('alert')).toHaveTextContent(en[id])
      cleanup()
    }
  })

  it('a node 404 shows the not-found text, closes the form and reloads the list', async () => {
    await saveNodeWith(problem(404, {}))
    expect(await screen.findByRole('alert')).toHaveTextContent(en['locations.error.notFound'])
    await waitFor(() => expect(screen.queryByTestId('loc-save')).not.toBeInTheDocument())
    await waitFor(() => expect(queryBodies(clientMock, 'location_node').length).toBeGreaterThan(1))
  })
})
