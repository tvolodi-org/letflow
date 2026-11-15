// @vitest-environment jsdom
/** T-1888 — the counts screen on the shared document grid: the empty record pane, Back and Escape (owned by DocLayout) close the open
 *  count, and Escape with a dialog open does not. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { LIST, fakeCounts, renderCounts, order, line } from './countsTestKit'

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
    expect(screen.getByTestId('document-workspace')).not.toHaveAttribute('data-detail')
    fireEvent.click((await screen.findByText('CNT-0001')).closest('tr')!)
    await waitFor(() => expect(screen.getByTestId('document-workspace')).toHaveAttribute('data-detail', 'open'))
    fireEvent.click(screen.getByRole('button', { name: 'Back to the list' }))
    await waitFor(() => expect(screen.getByTestId('document-workspace')).not.toHaveAttribute('data-detail'))
  })

  it('Escape inside the open count closes it', async () => {
    fakeCounts(clientMock)
    renderCounts(LIST)
    fireEvent.click((await screen.findByText('CNT-0001')).closest('tr')!)
    await waitFor(() => expect(screen.getByTestId('document-workspace')).toHaveAttribute('data-detail', 'open'))
    fireEvent.keyDown(await screen.findByTestId('count-facts'), { key: 'Escape' })
    await waitFor(() => expect(screen.getByTestId('document-workspace')).not.toHaveAttribute('data-detail'))
  })
})

describe('T-2006 document preferences and panel containment', () => {
  it.each(['row', 'tabs'])('%s puts every count panel in the shared layout', async (layout) => {
    fakeCounts(clientMock, { orders: [order({ id: 'c2', status: 'counting' })], linePages: [[line(1)]] })
    const get = clientMock.get.getMockImplementation()!
    clientMock.get.mockImplementation((path: string) => path === '/api/v1/me/preferences'
      ? Promise.resolve({ effective: { 'ui.document_layout': layout } })
      : get(path))
    renderCounts(`${LIST}/c2`)
    const grid = await screen.findByTestId('document-workspace')
    await screen.findByTestId('count-facts')
    await waitFor(() => expect(grid).toHaveAttribute('data-layout', layout))
    for (const pane of ['list', 'header', 'lines']) expect(grid.querySelectorAll(`:scope > .lf-doc__${pane}`)).toHaveLength(1)
    // The sheet and its supporting panels all live inside the lines cell, never below the grid.
    expect(screen.getByTestId('count-facts').closest('.lf-doc__header')?.parentElement).toBe(grid)
    expect((await screen.findByTestId('count-sheet')).closest('.lf-doc__lines')?.parentElement).toBe(grid)
    if (layout === 'tabs') {
      expect(grid).toHaveAttribute('data-tab', 'lines')
      fireEvent.click(screen.getByTestId('document-tab-header'))
      expect(grid).toHaveAttribute('data-tab', 'header')
    } else expect(screen.queryByTestId('document-tabs')).toBeNull()
  })
})
