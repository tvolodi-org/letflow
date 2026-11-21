// @vitest-environment jsdom
/** GH 4802 / REQ-898 (CMMS slice 1 part 6): the form of a new work request.
 *
 *  AC2 — the validation of the form, the one POST /requests with the idempotency key, the upload of every photo
 *  and the refusal of the request in words.
 *  AC3 — a refused photo: the request stays, the screen opens it and the refused file is named with the reason.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { API, WITH_ALL, fakeServer, renderMaintenance, type ClientMock } from './maintenanceTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-m' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const client = clientMock as unknown as ClientMock

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeServer(client)
})
afterEach(() => cleanup())

/** A file of the form (a JPEG is enough: the server does the real check). */
function photoFile(name: string): File {
  return new File([new Uint8Array([1, 2, 3])], name, { type: 'image/jpeg' })
}

const createCalls = () => clientMock.post.mock.calls.filter(([p]) => p === `${API}/requests`)
const uploadCalls = () => clientMock.post.mock.calls.filter(([p]) => String(p).endsWith('/photos'))

describe('AC2 the form of a request', () => {
  it('refuses Save with an empty description and sends nothing', async () => {
    renderMaintenance('/admin/maintenance/requests/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.click(screen.getByTestId('request-save'))
    await waitFor(() => expect(screen.getByText('Describe the fault.')).toBeInTheDocument())
    expect(createCalls()).toHaveLength(0)
  })

  it('refuses Save with 2001 characters and sends nothing', async () => {
    renderMaintenance('/admin/maintenance/requests/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.change(screen.getByTestId('request-description'), { target: { value: 'x'.repeat(2001) } })
    fireEvent.click(screen.getByTestId('request-save'))
    await waitFor(() => expect(screen.getByText(/too long/i)).toBeInTheDocument())
    expect(createCalls()).toHaveLength(0)
  })

  it('sends one POST /requests with an idempotency key and one upload per photo', async () => {
    renderMaintenance('/admin/maintenance/requests/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.change(screen.getByTestId('request-description'), { target: { value: 'The press does not start.' } })
    const input = screen.getByTestId('request-photos-input') as HTMLInputElement
    fireEvent.change(input, { target: { files: [photoFile('one.jpg'), photoFile('two.jpg')] } })
    fireEvent.click(screen.getByTestId('request-save'))
    await waitFor(() => expect(createCalls()).toHaveLength(1))
    const body = createCalls()[0]![1] as Record<string, unknown>
    expect(body['asset_card_id']).toBe('c-1')
    expect(body['description']).toBe('The press does not start.')
    expect(body['urgency']).toBe('normal')
    expect(typeof body['idempotency_key']).toBe('string')
    await waitFor(() => expect(uploadCalls()).toHaveLength(2))
  })

  it('shows a refusal of the request in words, not as a code', async () => {
    fakeServer(client, {
      create: () => ({ status: 422, details: { reason: 'asset_card_inactive' } }),
    })
    renderMaintenance('/admin/maintenance/requests/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.change(screen.getByTestId('request-description'), { target: { value: 'The press does not start.' } })
    fireEvent.click(screen.getByTestId('request-save'))
    await waitFor(() => expect(screen.getByTestId('request-form-error')).toBeInTheDocument())
    const text = screen.getByTestId('request-form-error').textContent ?? ''
    expect(text).toBe('This equipment is retired. Choose an active one.')
    expect(text).not.toContain('asset_card_inactive')
  })
})

describe('AC3 a refused photo', () => {
  it('opens the created request with two photos and names the refused file', async () => {
    fakeServer(client, {
      uploadPhoto: (index) =>
        index === 2
          ? { status: 422, details: { reason: 'photo_too_large' } }
          : { id: `p-${index + 1}`, position: index + 1, caption: null, has_thumbnail: false, inserted_at: '2026-11-21T09:10:00Z' },
    })
    renderMaintenance('/admin/maintenance/requests/new', WITH_ALL)
    const card = await screen.findByLabelText('Equipment')
    await screen.findByRole('option', { name: /FA-1/ })
    fireEvent.change(card, { target: { value: 'c-1' } })
    fireEvent.change(screen.getByTestId('request-description'), { target: { value: 'The press does not start.' } })
    const input = screen.getByTestId('request-photos-input') as HTMLInputElement
    fireEvent.change(input, { target: { files: [photoFile('one.jpg'), photoFile('two.jpg'), photoFile('three.jpg')] } })
    fireEvent.click(screen.getByTestId('request-save'))
    await waitFor(() => expect(uploadCalls()).toHaveLength(3))
    // the created request stays and the screen opens it
    const detail = await screen.findByTestId('maintenance-request-detail')
    expect(detail).toBeInTheDocument()
    // the two uploaded photos are on the request
    await waitFor(() => expect(screen.getAllByTestId('request-photo')).toHaveLength(2))
    // the refused file is named with the server's reason
    const banner = await screen.findByTestId('request-photo-errors')
    expect(banner.textContent).toContain('three.jpg')
    expect(banner.textContent).toContain('The image is too large.')
  })
})
