// @vitest-environment jsdom
/** L3, L4 — T-1391: the document screens render the effective layout (tabs: new -> Header, existing -> Lines; a
 *  problem in the hidden tab shows a badge and Save jumps to it), through the real route table and a mocked client. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { DOCS, LIST, fakeMasters, renderStock, stockDoc, withPost } from './stockTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-stock' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), put: vi.fn(), delete: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const PREFS = '/api/v1/me/preferences'

function serve(layout: string | 'fail', docs: Record<string, unknown>[] = []) {
  clientMock.get.mockImplementation(async (path: string) => {
    if (path === PREFS) {
      if (layout === 'fail') throw { status: 500, message: 'x' }
      return { preferences: {}, effective: { 'ui.document_layout': layout }, tenant_defaults: {} }
    }
    for (const d of docs) if (path === `${DOCS}/${String(d['id'])}`) return d
    if (path === DOCS) return { rows: docs.map((d) => ({ ...d, lines: undefined })), next_cursor: null }
    return { rows: [], next_cursor: null }
  })
}

beforeEach(() => {
  for (const m of Object.values(clientMock)) m.mockReset()
  fakeMasters(clientMock)
})
afterEach(() => cleanup())

describe('L3 layout of the document screens', () => {
  it('tabs: an existing document opens on Lines, a click or arrow key switches, another document resets', async () => {
    serve('tabs', [stockDoc({ id: 'd1', number: 'RC-1', state: 'posted' }), stockDoc({ id: 'd2', number: 'RC-2', state: 'posted' })])
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await waitFor(() => expect(ws).toHaveAttribute('data-layout', 'tabs'))
    await screen.findByTestId('document-tabs')
    expect(ws).toHaveAttribute('data-tab', 'lines')
    expect(screen.getByTestId('document-tab-lines')).toHaveAttribute('aria-selected', 'true')
    expect(ws.querySelector('.lf-doc__lines')).toHaveAttribute('role', 'tabpanel')
    fireEvent.click(screen.getByTestId('document-tab-header'))
    expect(ws).toHaveAttribute('data-tab', 'header')
    fireEvent.keyDown(screen.getByTestId('document-tab-header'), { key: 'ArrowRight' })
    expect(ws).toHaveAttribute('data-tab', 'lines')
    fireEvent.click(screen.getByTestId('document-tab-header'))
    // another document: back to the default tab for an existing one
    const rows = await screen.findAllByTestId('document-row')
    fireEvent.click(rows[1]!)
    await waitFor(() => expect(ws).toHaveAttribute('data-tab', 'lines'))
  })

  it('tabs: a new document opens on Header', async () => {
    serve('tabs')
    renderStock(`${LIST}/new`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await waitFor(() => expect(ws).toHaveAttribute('data-layout', 'tabs'))
    await screen.findByTestId('document-form')
    expect(ws).toHaveAttribute('data-tab', 'header')
    expect(screen.getByTestId('document-tab-header')).toHaveAttribute('aria-selected', 'true')
  })

  it.each([['row'], ['fail']])('%s: no tab list and both cards exist', async (layout) => {
    serve(layout, [stockDoc({ id: 'd1', number: 'RC-1', state: 'posted' })])
    renderStock(`${LIST}/d1`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-header')
    await waitFor(() => expect(clientMock.get).toHaveBeenCalledWith(PREFS))
    expect(ws).toHaveAttribute('data-layout', 'row')
    expect(ws).not.toHaveAttribute('data-tab')
    expect(screen.queryByTestId('document-tabs')).toBeNull()
    expect(ws.querySelector('.lf-doc__header')).not.toBeNull()
    expect(ws.querySelector('.lf-doc__lines')).not.toBeNull()
  })
})

describe('L4 problems in a hidden tab', () => {
  it('Save with an empty form jumps to the first tab with a problem and the badge counts problems', async () => {
    serve('tabs')
    renderStock(`${LIST}/new`, withPost)
    const ws = await screen.findByTestId('document-workspace')
    await screen.findByTestId('document-tab-header')
    fireEvent.click(screen.getByTestId('document-tab-lines'))
    expect(ws).toHaveAttribute('data-tab', 'lines')
    fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
    await waitFor(() => expect(ws).toHaveAttribute('data-tab', 'header'))
    const badge = screen.getByTestId('document-tab-header-problems')
    expect(badge).toHaveAttribute('aria-label', expect.stringMatching(/^\d+ problems?$/))
    expect(clientMock.post.mock.calls.some((c) => c[0] === DOCS)).toBe(false)
  })
})
