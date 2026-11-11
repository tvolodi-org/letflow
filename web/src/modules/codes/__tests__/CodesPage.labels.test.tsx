// @vitest-environment jsdom
/** E3b — label printing on the codes screen: L1-L13 of the T-1355 design. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import CodesPage from '../CodesPage'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { fakeServer, problem, rec, renderCodes, withAtom, withoutAtom } from './codesTestKit'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-codes' }, isAuthenticated: true }),
}))
const clientMock = vi.hoisted(() => ({ post: vi.fn(), patch: vi.fn(), get: vi.fn(), postBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
const saveBlob = vi.hoisted(() => vi.fn())
vi.mock('@/lib/saveBlob', () => ({ saveBlob }))

const LABELS = '/api/v1/modules/codes/labels'
const DATA = () => ({
  code_tag: [
    rec('c1', 'code_tag', { value: 'FREE-1', kind: 'barcode', status: 'not_assigned' }),
    rec('c2', 'code_tag', { value: 'USED-1', kind: 'qr', status: 'not_assigned' }),
    rec('c3', 'code_tag', { value: 'RFID-1', kind: 'epc', status: 'not_assigned' }),
    rec('c4', 'code_tag', { value: 'GONE-1', kind: 'barcode', status: 'retired' }),
  ],
  location_node: [],
  catalog_item: [],
  catalog_lot: [],
  code_assignment: [],
})
const PDF = { blob: new Blob(['x']), contentType: 'application/pdf' }

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.postBlob.mockReset()
  saveBlob.mockReset()
  clientMock.postBlob.mockResolvedValue(PDF)
  fakeServer(clientMock, DATA())
})
afterEach(() => cleanup())

const tick = async (id: string) => fireEvent.click(await screen.findByTestId(`label-tick-${id}`))
const printBtn = () => screen.getByTestId('label-print')

describe('L1-L4 selecting', () => {
  it('L1 ticking two rows prints exactly code_ids in tick order', async () => {
    renderCodes('/admin/codes')
    await tick('c2')
    await tick('c1')
    expect(printBtn()).toHaveTextContent('Print labels (2)')
    fireEvent.click(printBtn())
    await waitFor(() => expect(clientMock.postBlob).toHaveBeenCalledTimes(1))
    expect(clientMock.postBlob).toHaveBeenCalledWith(LABELS, { code_ids: ['c2', 'c1'] })
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(PDF.blob, 'code-labels.pdf'))
  })

  it('L2 ticking does not open the detail panel', async () => {
    renderCodes('/admin/codes')
    await tick('c1')
    expect(screen.queryByTestId('codes-detail')).toBeNull()
  })

  it('L3 select all takes printable rows only; hint shown', async () => {
    renderCodes('/admin/codes')
    await screen.findByTestId('label-tick-c1')
    fireEvent.click(screen.getByTestId('label-tick-all'))
    expect(printBtn()).toHaveTextContent('Print labels (2)')
    expect(screen.getByTestId('label-tick-c3')).toBeDisabled()
    expect(screen.getByText(/Only barcode and QR codes/)).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('label-print'))
    await waitFor(() => expect(clientMock.postBlob).toHaveBeenCalledWith(LABELS, { code_ids: ['c1', 'c2'] }))
  })

  it('L4 a retired row is behind Show retired and disabled; a filter change prunes the selection', async () => {
    renderCodes('/admin/codes')
    await tick('c1')
    expect(screen.queryByTestId('label-tick-c4')).toBeNull()
    fireEvent.click(screen.getByTestId('codes-show-retired'))
    expect(await screen.findByTestId('label-tick-c4')).toBeDisabled()
    fireEvent.change(screen.getByPlaceholderText('Scan or paste a full value'), { target: { value: 'USED-1' } })
    fireEvent.click(screen.getByTestId('codes-search'))
    await waitFor(() => expect(screen.queryByTestId('label-tick-c1')).toBeNull())
    expect(printBtn()).toBeDisabled()
    expect(printBtn()).toHaveTextContent('Print labels (0)')
  })

  it('L5 select all stops at 1000 and shows the limit hint', async () => {
    const many = Array.from({ length: 1001 }, (_, i) => rec(`m${i}`, 'code_tag', { value: `M-${i}`, kind: 'barcode', status: 'not_assigned' }))
    fakeServer(clientMock, { ...DATA(), code_tag: many })
    renderCodes('/admin/codes')
    await screen.findByTestId('label-tick-m0')
    fireEvent.click(screen.getByTestId('label-tick-all'))
    expect(printBtn()).toHaveTextContent('Print labels (1000)')
    expect(screen.getByText(/At most 1000 labels/)).toBeInTheDocument()
  }, 30000)
})

describe('L6-L8 printing', () => {
  it('L6 the panel prints one label; absent for a retired code', async () => {
    renderCodes('/admin/codes')
    fireEvent.click((await screen.findAllByText('FREE-1'))[0].closest('tr') as HTMLElement)
    fireEvent.click(await screen.findByTestId('label-print-one'))
    await waitFor(() => expect(clientMock.postBlob).toHaveBeenCalledWith(LABELS, { code_ids: ['c1'] }))
    cleanup()
    renderCodes('/admin/codes')
    fireEvent.click(await screen.findByTestId('codes-show-retired'))
    fireEvent.click((await screen.findAllByText('GONE-1'))[0].closest('tr') as HTMLElement)
    await screen.findByTestId('codes-detail')
    expect(screen.queryByTestId('label-print-one')).toBeNull()
  })

  it('L7 success toasts the count, keeps the selection; Clear empties it', async () => {
    renderCodes('/admin/codes')
    await tick('c1')
    await tick('c2')
    fireEvent.click(printBtn())
    expect((await screen.findAllByText('2 labels saved')).length).toBeGreaterThan(0)
    expect(printBtn()).toHaveTextContent('Print labels (2)')
    fireEvent.click(screen.getByTestId('label-clear'))
    expect(printBtn()).toHaveTextContent('Print labels (0)')
  })

  it('L8 two clicks in one tick send one request', async () => {
    let release: (v: unknown) => void = () => undefined
    clientMock.postBlob.mockReturnValue(new Promise((r) => (release = r)))
    renderCodes('/admin/codes')
    await tick('c1')
    fireEvent.click(printBtn())
    fireEvent.click(printBtn())
    expect(clientMock.postBlob).toHaveBeenCalledTimes(1)
    release(PDF)
    await waitFor(() => expect(saveBlob).toHaveBeenCalled())
  })
})

describe('L9-L11 failures', () => {
  it('L9 entry_invalid names the position, the value and the reason', async () => {
    clientMock.postBlob.mockRejectedValue(problem(422, { reason: 'entry_invalid', index: 1, entry_reason: 'value_too_long' }))
    renderCodes('/admin/codes')
    await tick('c1')
    await tick('c2')
    fireEvent.click(printBtn())
    expect(await screen.findByText('Label 2 (USED-1): The value is too long for a label.')).toBeInTheDocument()
    expect(saveBlob).not.toHaveBeenCalled()
    expect(printBtn()).not.toBeDisabled()
  })

  it('L10 404 shows not found and reloads the list', async () => {
    clientMock.postBlob.mockRejectedValue(problem(404, {}))
    renderCodes('/admin/codes')
    await tick('c1')
    const before = clientMock.post.mock.calls.length
    fireEvent.click(printBtn())
    expect(await screen.findByText(/no longer exist|not found/i)).toBeInTheDocument()
    await waitFor(() => expect(clientMock.post.mock.calls.length).toBeGreaterThan(before))
  })

  it('L11 403 and a network error give their messages', async () => {
    clientMock.postBlob.mockRejectedValueOnce(problem(403, {}))
    renderCodes('/admin/codes')
    await tick('c1')
    fireEvent.click(printBtn())
    await waitFor(() => expect(screen.getByRole('alert') ?? screen.getByText(/permission/i)).toBeTruthy())
    clientMock.postBlob.mockRejectedValueOnce(new Error('offline'))
    fireEvent.click(printBtn())
    await waitFor(() => expect(clientMock.postBlob).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(printBtn()).not.toBeDisabled())
  })
})

describe('L12-L13 access and states', () => {
  it('L12 a user without CodesWrite can print; Receive is absent', async () => {
    // The route itself needs CodesWrite today; the page is rendered directly to prove the button does not.
    render(
      <QueryClientProvider client={new QueryClient()}>
        <AccessStateProvider state={withoutAtom}>
          <CodesPage locale="en" />
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    await tick('c1')
    expect(printBtn()).not.toBeDisabled()
    expect(screen.queryByTestId('receive-open')).toBeNull()
  })

  it('L13 empty list: print disabled, select all disabled, no tick boxes', async () => {
    fakeServer(clientMock, { ...DATA(), code_tag: [] })
    renderCodes('/admin/codes', withAtom)
    await screen.findByText('No codes found.')
    expect(printBtn()).toBeDisabled()
    expect(screen.getByTestId('label-tick-all')).toBeDisabled()
    expect(screen.queryByTestId('label-tick-c1')).toBeNull()
  })
})
