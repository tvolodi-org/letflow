// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as matchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { RecordCodes } from '../RecordCodes'
import { useRecordCodes } from '@/hooks/useRecordCodes'
import { recordCodesKeys } from '@/lib/codes/recordCodes.api'
import { useUiLocaleStore, type UiLocale } from '@/i18n/uiLocaleStore'
import { getToastSnapshot, clearAllToasts } from '@/hooks/useToast'

expect.extend(matchers)
vi.mock('@/auth/AuthContext', async (original) => ({ ...await original<object>(), useAuth: () => ({ session: { tenant_id: 'tenant-a' }, isAuthenticated: true }) }))
const setUiLocale = (l: UiLocale) => useUiLocaleStore.getState().setLocale(l)
const post = vi.hoisted(() => vi.fn())
vi.mock('@/api/client', async (original) => ({ ...await original<object>(), client: { post } }))
const tag = { record_id: 'c-1', field_values: { value: 'ABC', kind: 'barcode', status: 'assigned' } }
let empty = false
let assignError: unknown
let receiveError: unknown
let releaseError: unknown
let queryError: unknown
let more = false
let hang = false
let readCount = 0
function Host(props: { active?: boolean; onDialogChange?: (open: boolean) => void }) {
  const data = useRecordCodes('catalog_item', 'item-a', true)
  return <RecordCodes targetType="catalog_item" targetId="item-a" targetActive={props.active ?? true} data={data} onDialogChange={props.onDialogChange} />
}
function mount(options: { write?: boolean; active?: boolean; onDialogChange?: (open: boolean) => void; truncated?: boolean } = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  if (options.truncated) qc.setQueryData(recordCodesKeys.record('tenant-a', 'catalog_item', 'item-a'), { rows: [{ codeId: 'c-1', value: 'ABC', kind: 'barcode', status: 'assigned', assignedAt: '' }], truncated: true })
  const rendered = render(<QueryClientProvider client={qc}><AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CodesRead', ...(options.write === false ? [] : ['CodesWrite'])] } }}><MemoryRouter><Host {...options} /></MemoryRouter></AccessStateProvider></QueryClientProvider>)
  return { ...rendered, qc }
}
beforeEach(() => {
  setUiLocale('en'); empty = false; more = false; hang = false; assignError = receiveError = releaseError = queryError = undefined; readCount = 0
  post.mockReset().mockImplementation(async (path: string, body: Record<string, unknown>) => {
    if (path.endsWith('/query')) {
      readCount++
      if (hang) return new Promise(() => {})
      if (queryError) throw queryError
      if (body['entity_type'] === 'code_assignment') return { items: empty ? [] : [{ record_id: 'a-1', field_values: { code_id: 'c-1', assigned_at: '2026-11-14T07:00:00Z' } }], next_cursor: null }
      return { items: [tag], next_cursor: more ? 'next' : null }
    }
    if (path.endsWith('/receive')) { if (receiveError) throw receiveError; return [{ code_id: 'new-code' }] }
    if (path.endsWith('/assign') && assignError) throw assignError
    if (path.endsWith('/release') && releaseError) throw releaseError
    return {}
  })
})
afterEach(() => { cleanup(); clearAllToasts(); setUiLocale('en') })
const problem = (reason: string, entry_reason?: string) => ({ status: 422, details: { reason, entry_reason } })
const writes = () => post.mock.calls.filter(([path]) => !path.endsWith('/query'))
async function open() { fireEvent.click(await screen.findByTestId('record-codes-new')) }
function type(value: string) { fireEvent.change(screen.getByTestId('record-codes-value'), { target: { value } }) }
async function confirm() { fireEvent.click(screen.getByTestId('record-codes-dialog-confirm')); await waitFor(() => expect(screen.getByTestId('record-codes-dialog-confirm')).not.toBeDisabled()) }

it('C1 lists value, kind, status and queries only this record without a tenant key', async () => {
  mount(); expect(await screen.findByText('ABC')).toHaveClass('mono')
  expect(screen.getByText('Barcode')).toBeInTheDocument(); expect(screen.getByText('Assigned')).toBeInTheDocument()
  expect(post.mock.calls[0]).toEqual(['/api/v1/entities/query', { entity_type: 'code_assignment', filters: [{ field: 'deleted', op: 'eq', value: false }, { field: 'target_type', op: 'eq', value: 'catalog_item' }, { field: 'target_id', op: 'eq', value: 'item-a' }, { field: 'released_at', op: 'is_null' }], sort: [{ field: 'assigned_at', dir: 'asc' }], page_size: 200 }])
  expect(post.mock.calls[1]).toEqual(['/api/v1/entities/query', { entity_type: 'code_tag', filters: [{ field: 'deleted', op: 'eq', value: false }, { field: 'record_id', op: 'in', value: ['c-1'] }], sort: [{ field: 'value', dir: 'asc' }], page_size: 200 }])
})
it('C2 empty makes no tag request and offers New code', async () => {
  empty = true; mount(); await screen.findByText('No codes are attached to this record.')
  expect(post).toHaveBeenCalledTimes(1); expect(screen.getByTestId('record-codes-new')).toBeVisible()
})
it('C3 read-only hides all writes and the write-guarded Codes link', async () => {
  mount({ write: false }); await screen.findByText('ABC')
  expect(screen.queryByTestId('record-codes-new')).toBeNull(); expect(screen.queryByText('Release')).toBeNull(); expect(screen.queryByRole('link')).toBeNull()
})
it('C4 receive then assign carries exact bodies and refreshes the shared prefix', async () => {
  const { qc } = mount(); const invalidate = vi.spyOn(qc, 'invalidateQueries'); await screen.findByText('ABC'); await open(); type(' X-1 ')
  fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'qr' } }); fireEvent.click(screen.getByTestId('record-codes-dialog-confirm'))
  await waitFor(() => expect(screen.queryByTestId('record-codes-dialog')).toBeNull())
  const key = writes()[0][1].idempotency_key
  expect(writes()).toEqual([['/api/v1/modules/codes/receive', { entries: [{ value: ' X-1 ', kind: 'qr' }], idempotency_key: key }], ['/api/v1/modules/codes/new-code/assign', { target_type: 'catalog_item', target_id: 'item-a', idempotency_key: `${key}-assign` }]])
  expect(invalidate).toHaveBeenCalledWith({ queryKey: ['codes', 'tenant-a'] }); expect(readCount).toBeGreaterThan(2)
  expect(getToastSnapshot()[0]?.message).toBe('Code created and attached.')
})
it('C5 retries a partial receive with the same keys and changes keys on edit', async () => {
  assignError = problem('target_inactive'); mount(); await open(); type('X-1'); await confirm()
  await screen.findByText('The record is retired and cannot get new codes.')
  await confirm(); expect(writes()[2]).toEqual(writes()[0]); expect(writes()[3]).toEqual(writes()[1])
  type('X-2'); await confirm(); expect(writes()[4][1].idempotency_key).not.toBe(writes()[0][1].idempotency_key)
})
it('C6 duplicate value is a field error, without assigning', async () => {
  receiveError = problem('entry_invalid', 'value_taken'); mount(); await open(); type('ABC'); await confirm()
  expect(await screen.findByText(/This code already exists/)).toBeInTheDocument()
  expect(screen.getByTestId('record-codes-value')).toHaveAttribute('aria-invalid', 'true'); expect(writes()).toHaveLength(1)
})
it('C7 picker caps at 100, exact-searches and only assigns', async () => {
  more = true; empty = true; mount(); await open(); fireEvent.click(screen.getByLabelText('Choose a received code'))
  await screen.findByText(/The first 100/)
  const pickBody = post.mock.calls.find(([, b]) => b.page_size === 100)?.[1]
  expect(pickBody).toEqual({ entity_type: 'code_tag', filters: [{ field: 'deleted', op: 'eq', value: false }, { field: 'status', op: 'eq', value: 'not_assigned' }], sort: [{ field: 'value', dir: 'asc' }], page_size: 100 })
  fireEvent.change(screen.getByTestId('record-codes-search'), { target: { value: 'ABC' } }); fireEvent.click(screen.getByText('Search'))
  await waitFor(() => expect(post.mock.calls.some(([, b]) => b.filters?.some((f: { field: string; value?: unknown }) => f.field === 'value' && f.value === 'ABC'))).toBe(true))
  fireEvent.change(await screen.findByLabelText('Received code'), { target: { value: 'c-1' } }); fireEvent.click(screen.getByTestId('record-codes-dialog-confirm'))
  await waitFor(() => expect(writes()).toHaveLength(1)); expect(writes()[0][0]).toBe('/api/v1/modules/codes/c-1/assign')
})
it('C8 release refreshes, toasts, and reports a rejected release in the section', async () => {
  mount(); fireEvent.click(await screen.findByTestId('record-codes-release-c-1'))
  await waitFor(() => expect(getToastSnapshot()[0]?.message).toBe('Code released.'))
  expect(writes()[0]).toEqual(['/api/v1/modules/codes/c-1/release', { idempotency_key: expect.any(String) }])
  releaseError = problem('code_not_assigned'); fireEvent.click(screen.getByTestId('record-codes-release-c-1'))
  expect(await screen.findByTestId('record-codes-error')).toHaveTextContent('This code is no longer assigned.')
})
it('C9 error retries and loading draws skeletons', async () => {
  queryError = new Error('offline'); mount(); await screen.findByTestId('datatable-error'); queryError = undefined
  fireEvent.click(screen.getByTestId('datatable-retry')); await screen.findByText('ABC')
  cleanup(); hang = true; mount(); expect(screen.getAllByTestId('datatable-skeleton-row')).toHaveLength(5)
})
it('C10 a capped read is disclosed', async () => {
  hang = true; mount({ truncated: true }); expect(screen.getByTestId('list-truncated')).toHaveTextContent('first 1 codes')
})
it.each([['ru', 'Штрихкод', 'Назначен'], ['kk', 'Штрих-код', 'Тағайындалған']] as const)('C11 %s translates kind and status', async (locale, kind, status) => {
  setUiLocale(locale); mount(); await screen.findByText('ABC'); expect(screen.getByText(kind)).toBeInTheDocument(); expect(screen.getByText(status)).toBeInTheDocument(); expect(document.body.textContent).not.toContain('recordCodes.')
})
it('C12 retired target permits release only; dialog reports open, close, cancel and unmount', async () => {
  mount({ active: false }); await screen.findByText('ABC'); expect(screen.queryByTestId('record-codes-new')).toBeNull(); expect(screen.getByTestId('record-codes-release-c-1')).toBeVisible(); expect(screen.getByText(/A retired record/)).toBeVisible()
  cleanup(); const onDialogChange = vi.fn(); const result = mount({ onDialogChange }); await open(); expect(onDialogChange).toHaveBeenLastCalledWith(true)
  fireEvent.keyDown(screen.getByTestId('record-codes-value'), { key: 'Escape' }); expect(onDialogChange).toHaveBeenLastCalledWith(false)
  await open(); fireEvent.click(screen.getByTestId('record-codes-dialog-cancel')); expect(onDialogChange).toHaveBeenLastCalledWith(false)
  await open(); result.unmount(); expect(onDialogChange).toHaveBeenLastCalledWith(false)
})
