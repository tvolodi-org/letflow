// @vitest-environment jsdom
/** T4, T5 — T-1933 / REQ-822 (K7a): local validation and server refusals next to the field. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { COUNTS, FULL, LIST, fakeCounts, refusal, renderAssets, writes } from './assetCountsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

async function openForm() {
  await userEvent.click(await screen.findByTestId('count-new'))
  const form = await screen.findByTestId('count-order-form')
  await waitFor(() => expect(within(form).getByRole('option', { name: /Warehouse/ })).toBeInTheDocument())
  return form
}
const setTimes = (form: HTMLElement, start: [string, string], end: [string, string]) => {
  fireEvent.change(within(form).getByLabelText('Planned start, date'), { target: { value: start[0] } })
  fireEvent.change(within(form).getByLabelText('Planned start, time'), { target: { value: start[1] } })
  fireEvent.change(within(form).getByLabelText('Planned end, date'), { target: { value: end[0] } })
  fireEvent.change(within(form).getByLabelText('Planned end, time'), { target: { value: end[1] } })
}

describe('T4 local checks', () => {
  it('an empty form lists the required fields and sends nothing', async () => {
    fakeCounts(clientMock)
    renderAssets(LIST, FULL)
    const form = await openForm()
    await userEvent.click(within(form).getByTestId('count-save'))
    const banner = await within(form).findByText(/Org unit, Kinds of assets, Planned start, Planned end, Commission chair/)
    expect(banner).toBeInTheDocument()
    expect(within(form).getByText('Choose at least one kind of assets.')).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
  })

  it('an end before the start, and one 97 hours later, give the end-field error; 96 hours passes', async () => {
    fakeCounts(clientMock)
    renderAssets(LIST, FULL)
    const form = await openForm()
    await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
    await userEvent.click(within(form).getByTestId('kind-fixed'))
    await userEvent.selectOptions(within(form).getByLabelText('Commission chair'), 'e1')
    const endText = 'The end must be after the start and at most 96 hours later.'
    setTimes(form, ['2026-11-10', '09:00'], ['2026-11-09', '09:00'])
    await userEvent.click(within(form).getByTestId('count-save'))
    expect(await within(form).findByText(endText)).toBeInTheDocument()
    setTimes(form, ['2026-11-10', '09:00'], ['2026-11-14', '10:00'])
    await userEvent.click(within(form).getByTestId('count-save'))
    expect(await within(form).findByText(endText)).toBeInTheDocument()
    expect(writes(clientMock)).toEqual([])
    setTimes(form, ['2026-11-10', '09:00'], ['2026-11-14', '09:00'])
    await userEvent.click(within(form).getByTestId('count-save'))
    await waitFor(() => expect(writes(clientMock)).toHaveLength(1))
  })
})

describe('T5 server refusals at the field', () => {
  async function submitWith(reason: string) {
    fakeCounts(clientMock, { fail: { 'POST ': refusal(422, reason) } })
    renderAssets(LIST, FULL)
    const form = await openForm()
    await userEvent.selectOptions(within(form).getByLabelText('Org unit'), 'u1')
    await userEvent.click(within(form).getByTestId('kind-fixed'))
    setTimes(form, ['2026-11-10', '09:00'], ['2026-11-11', '09:00'])
    await userEvent.selectOptions(within(form).getByLabelText('Commission chair'), 'e1')
    await userEvent.click(within(form).getByTestId('count-save'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledWith(COUNTS, expect.anything()))
    return form
  }

  it('count_scope_not_linked is shown at the root locations', async () => {
    const form = await submitWith('count_scope_not_linked')
    const locations = within(form).getByTestId('locations')
    expect(await within(locations).findByText('A chosen location is not linked to this org unit.')).toBeInTheDocument()
  })

  it('chair_without_user is shown at the chair, with the text once', async () => {
    const form = await submitWith('chair_without_user')
    expect(await within(form).findAllByText(/The chair has no user account/)).toHaveLength(1)
  })
})
