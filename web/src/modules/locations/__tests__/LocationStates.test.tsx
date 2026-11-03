// @vitest-environment jsdom
/** S1–S10 — T-1172 (style S3): the states and the keyboard of the restyled location screens: loading, empty,
 *  load error with retry, the detail panel (stays open, close button, Escape, retired behind the switch), toast. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { clearAllToasts } from '@/hooks/useToast'
import { fakeServer, problem, rec, renderLocations, withoutAtom } from './locationsTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-loc' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

const node = (id: string, code: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'location_node', { code, name: `Loc ${code}`, node_kind: 'zone', ...extra })
const DATA = {
  location_node: [node('n-a', 'A'), node('n-b', 'B', { location_type: 'pick' }), node('n-r', 'R', { active: false })],
}
const select = (code: string) => fireEvent.click(screen.getByTitle(code))

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.patch.mockReset()
})
afterEach(() => {
  cleanup()
  clearAllToasts()
})

describe('S1 loading', () => {
  it('shows the skeleton while the rows load', async () => {
    clientMock.post.mockImplementation(() => new Promise(() => undefined))
    renderLocations('/admin/locations')
    expect(await screen.findByLabelText('Loading content')).toBeInTheDocument()
    expect(screen.queryByTestId('loc-create')).toBeInTheDocument()
  })
})

describe('S2 empty', () => {
  it('shows the empty text with a create action that opens the panel', async () => {
    fakeServer(clientMock, { location_node: [] })
    renderLocations('/admin/locations')
    expect(await screen.findByText('No locations yet')).toBeInTheDocument()
    const empty = screen.getByTestId('empty-state')
    fireEvent.click(within(empty).getByRole('button', { name: 'Create' }))
    expect(await screen.findByRole('form', { name: 'New location' })).toBeInTheDocument()
  })
})

describe('S3 load error', () => {
  it('shows the retry button and loads again on retry', async () => {
    let fail = true
    fakeServer(clientMock, DATA)
    const answer = clientMock.post.getMockImplementation() as (p: string, b: unknown) => Promise<unknown>
    clientMock.post.mockImplementation(async (p: string, b: unknown) => {
      if (fail) throw problem(500, {})
      return answer(p, b)
    })
    renderLocations('/admin/locations')
    const retry = await screen.findByRole('button', { name: 'Retry' })
    fail = false
    fireEvent.click(retry)
    expect(await screen.findByTitle('A')).toBeInTheDocument()
  })
})

describe('S4 detail panel', () => {
  it('stays open while other rows are clicked, shows the record, closes by the button and by Escape', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    expect(screen.getByTestId('loc-pick-hint')).toBeInTheDocument()
    select('A')
    expect(screen.getByRole('heading', { level: 2, name: 'Loc A' })).toBeInTheDocument()
    expect((screen.getByLabelText('Code') as HTMLInputElement).value).toBe('A')
    select('B')
    expect(screen.getByRole('heading', { level: 2, name: 'Loc B' })).toBeInTheDocument()
    expect((screen.getByLabelText('Location type') as HTMLSelectElement).value).toBe('pick')
    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(screen.getByTestId('loc-pick-hint')).toBeInTheDocument()
    select('A')
    fireEvent.keyDown(screen.getByLabelText('Name'), { key: 'Escape' })
    expect(screen.getByTestId('loc-pick-hint')).toBeInTheDocument()
  })

  it('does not close the panel when Escape closes a dialog', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    select('A')
    fireEvent.click(screen.getByRole('button', { name: 'Retire' }))
    expect(await screen.findByTestId('confirm-dialog')).toBeInTheDocument()
    fireEvent.keyDown(window, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument())
    expect(screen.getByRole('heading', { level: 2, name: 'Loc A' })).toBeInTheDocument()
  })
})

describe('S5 retired records', () => {
  it('hides retired rows behind Show retired and shows a retired record read-only without actions', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    expect(screen.queryByTitle('R')).not.toBeInTheDocument()
    fireEvent.click(screen.getByLabelText('Show retired'))
    fireEvent.click(await screen.findByTitle('R'))
    expect(screen.getByRole('heading', { level: 2, name: 'Loc R' })).toBeInTheDocument()
    expect(screen.queryByTestId('loc-save')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Retire' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Move' })).not.toBeInTheDocument()
  })
})

describe('S6 success toast and busy state', () => {
  it('shows a success toast after a save and closes the panel', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    select('A')
    fireEvent.click(screen.getByTestId('loc-save'))
    expect(await screen.findByText('Location saved')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument())
  })

  it('shows the dirty hint once a value changed', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    select('A')
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent(/no unsaved|saved/i)
    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Other' } })
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent(/unsaved/i)
  })
})

describe('S7 write error next to the field', () => {
  it('puts the field error text next to the marked input and keeps the page banner', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'field_invalid', field: 'segment' })
    })
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    select('A')
    fireEvent.click(screen.getByTestId('loc-save'))
    await screen.findByRole('alert')
    const segment = screen.getByLabelText('Segment')
    expect(segment).toHaveAttribute('aria-invalid', 'true')
    const described = document.getElementById(segment.getAttribute('aria-describedby') ?? '')
    expect(described).toHaveTextContent('Check this value.')
  })

  it('shows a failed move inside the move dialog', async () => {
    fakeServer(clientMock, DATA, () => {
      throw problem(422, { reason: 'cycle' })
    })
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    select('A')
    fireEvent.click(screen.getByRole('button', { name: 'Move' }))
    fireEvent.click(await screen.findByTestId('loc-move-confirm'))
    expect(await within(await screen.findByTestId('loc-move-error')).findByText(/cannot be moved under itself/)).toBeInTheDocument()
  })
})

describe('S8 keyboard', () => {
  it('moves through the tree with the arrow keys and selects with Enter', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    const rowA = screen.getByTitle('A').closest('.lf-tree__row') as HTMLElement
    rowA.focus()
    fireEvent.keyDown(rowA, { key: 'ArrowDown' })
    const rowB = screen.getByTitle('B').closest('.lf-tree__row') as HTMLElement
    await waitFor(() => expect(rowB).toHaveFocus())
    fireEvent.keyDown(rowB, { key: 'Enter' })
    expect(screen.getByRole('heading', { level: 2, name: 'Loc B' })).toBeInTheDocument()
  })

  it('the create button comes before the tree in the tab order and the tree is one tab stop', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations')
    await screen.findByTitle('A')
    const tabbable = [...document.querySelectorAll<HTMLElement>('button, input, [tabindex="0"]')]
    expect(tabbable[0]).toBe(screen.getByTestId('loc-create'))
    expect(document.querySelectorAll('.lf-tree__row[tabindex="0"]')).toHaveLength(1)
  })
})

describe('S9 no permission', () => {
  it('the screen is not reachable without the permission (route guard hides it)', async () => {
    fakeServer(clientMock, DATA)
    renderLocations('/admin/locations', withoutAtom)
    expect(await screen.findByText(/do not have access/i)).toBeInTheDocument()
    expect(screen.queryByTestId('loc-create')).not.toBeInTheDocument()
  })
})

describe('S10 links page states', () => {
  const LINK_DATA = {
    org_unit: [rec('u-1', 'org_unit', { code: 'U1', name: 'Unit one' })],
    location_node: [node('l-1', 'L1')],
    location_org_unit_link: [rec('k-1', 'location_org_unit_link', { org_unit_id: 'u-1', location_id: 'l-1' })],
  }

  it('asks to choose an end first, then shows an empty text for an end without links and a toast after linking', async () => {
    fakeServer(clientMock, { ...LINK_DATA, location_org_unit_link: [] })
    renderLocations('/admin/locations/links')
    await screen.findByLabelText('Org unit')
    expect(screen.getByText('Choose an org unit to see its locations.')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Org unit'), { target: { value: 'u-1' } })
    expect(await screen.findByText('No links yet.')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Location to link'), { target: { value: 'l-1' } })
    fireEvent.click(screen.getByTestId('link-add'))
    expect(await screen.findByText('Link added')).toBeInTheDocument()
  })

  it('the two ends are tabs that follow the arrow keys', async () => {
    fakeServer(clientMock, LINK_DATA)
    renderLocations('/admin/locations/links')
    await screen.findByLabelText('Org unit')
    const tabs = screen.getAllByRole('tab')
    expect(tabs.map((t) => t.getAttribute('aria-selected'))).toEqual(['true', 'false'])
    fireEvent.keyDown(tabs[0], { key: 'ArrowRight' })
    await waitFor(() => expect(screen.getByRole('tab', { name: 'By location' })).toHaveAttribute('aria-selected', 'true'))
  })

  it('shows the retry button when a list fails to load', async () => {
    clientMock.post.mockRejectedValue(problem(500, {}))
    renderLocations('/admin/locations/links')
    expect(await screen.findByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
})
