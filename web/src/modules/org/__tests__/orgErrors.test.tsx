// @vitest-environment jsdom
/** E1, E2 — GH 3609 / REQ-669: every refusal reason of the routes shows its message; 404 reloads; 403 is named. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { fakeServer, problem, queryBodies, rec, renderOrg } from './orgTestKit'
import { orgMessages } from '../orgMessages'
import { ORG_REASONS } from '../orgModel'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-org' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const LE = rec('le-1', 'org_legal_entity', { code: 'LE1', name: 'Alpha LLP', bin: '123456789012' })
const UNIT = rec('u-1', 'org_unit', { code: 'U1', name: 'Unit U1', legal_entity_id: 'le-1', site_id: 's-1' })
const DATA = {
  org_legal_entity: [LE],
  org_unit: [UNIT, rec('u-2', 'org_unit', { code: 'U2', name: 'Unit U2', legal_entity_id: 'le-1', site_id: 's-1' })],
  org_site: [rec('s-1', 'org_site', { code: 'S1', name: 'Main', legal_entity_id: 'le-1' })],
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => cleanup())

/** Opens the edit form of the legal company and saves; the server answers with `err`. */
async function saveLegalWith(err: unknown) {
  fakeServer(clientMock, DATA, () => {
    throw err
  })
  renderOrg('/admin/org/legal-entities')
  await screen.findByText('Alpha LLP')
  fireEvent.click(screen.getByText('Alpha LLP'))
  fireEvent.click(screen.getByTestId('org-save'))
}

describe('E1 reasons', () => {
  for (const reason of ORG_REASONS) {
    it(`shows the message of ${reason} and keeps the form open`, async () => {
      const status = reason === 'idempotency_key_reuse' ? 409 : 422
      await saveLegalWith(problem(status, { reason, field: 'bin', fields: ['code', 'bin'] }))
      const expected = orgMessages.en[`org.error.${reason}`].replace('{fields}', 'code, bin')
      const alert = await screen.findByRole('alert')
      expect(alert).toHaveTextContent(expected)
      expect(screen.getByTestId('org-save')).toBeInTheDocument()
      const marked = reason === 'field_invalid' || reason === 'field_not_allowed'
      expect(screen.getByLabelText('BIN').hasAttribute('aria-invalid')).toBe(marked)
    })
  }

  it('falls back for an unknown reason', async () => {
    await saveLegalWith(problem(422, { reason: 'brand_new' }))
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.unknown'])
  })

  it('shows the unit refusals on retire and move', async () => {
    fakeServer(clientMock, DATA, (_m, path) => {
      throw problem(422, { reason: path.endsWith('/move') ? 'cycle' : 'unit_has_active_staff' })
    })
    renderOrg('/admin/org/units')
    fireEvent.click(await screen.findByText('Unit U1'))
    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    fireEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.unit_has_active_staff'])
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    fireEvent.change(screen.getByLabelText('New parent'), { target: { value: 'u-2' } })
    fireEvent.click(screen.getByTestId('org-move-confirm'))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(orgMessages.en['org.error.cycle']))
  })
})

describe('E2 status answers', () => {
  it('404 shows the not-found text and reloads the list', async () => {
    await saveLegalWith({ status: 404, message: 'x', code: '404' })
    const before = queryBodies(clientMock, 'org_legal_entity').length
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.notFound'])
    await waitFor(() => expect(queryBodies(clientMock, 'org_legal_entity').length).toBeGreaterThanOrEqual(before))
    await waitFor(() => expect(screen.queryByTestId('org-save')).not.toBeInTheDocument())
  })

  it('403 names the missing permission', async () => {
    await saveLegalWith({ status: 403, message: 'x', code: '403' })
    expect(await screen.findByRole('alert')).toHaveTextContent(orgMessages.en['org.error.forbidden'])
  })
})
