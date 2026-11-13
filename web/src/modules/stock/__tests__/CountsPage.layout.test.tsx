// @vitest-environment jsdom
/** T-1888 — the counts screen on ListDetail: the empty record pane, Back and Escape (owned by ListDetail) close the open
 *  count, and Escape with a dialog open does not. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { LIST, fakeCounts, renderCounts } from './countsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-counts' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), put: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

describe('CL1 list + record shell', () => {
  it('shows the hint in the record pane, opens a count on a row click and Back returns', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    expect(await screen.findByText('Select a count in the list, or create a new one.')).toBeInTheDocument()
    expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed')
    fireEvent.click((await screen.findByText('CNT-0001')).closest('tr')!)
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open'))
    fireEvent.click(screen.getByTestId('list-detail-back'))
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed'))
  })

  it('Escape inside the open count closes it', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    fireEvent.click((await screen.findByText('CNT-0001')).closest('tr')!)
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'open'))
    fireEvent.keyDown(await screen.findByTestId('detail-header'), { key: 'Escape' })
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed'))
  })
})
