// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { REFERENCE_MESSAGES } from '../referenceMessages'
import { ReferenceLabel } from '../ReferenceLabel'
import { useReferenceLabels } from '../useReferenceLabels'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { noUuidInDom } from '@/test-utils/noUuidInDom'

const queryRecords = vi.fn()
vi.mock('@/api/entities', () => ({ entitiesApi: { queryRecords: (...a: unknown[]) => queryRecords(...a) } }))
vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { tenant_id: 't1' } }) }))

const A = '5b58a738-1c2d-4e3f-8a9b-0c1d2e3f4a5b'
const B = '6c69b849-2d3e-4f40-9bac-1d2e3f4a5b6c'
const rec = (id: string, fv: Record<string, unknown>) => ({ record_id: id, entity_type: 'x', field_values: fv, deleted: false })

function wrap(ui: React.ReactElement) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={qc}>{ui}</QueryClientProvider>)
}

function Probe({ ids }: { ids: string[] }) {
  const name = useReferenceLabels([{ catalog_item: ids }])
  return <ul>{ids.map((id) => <li key={id} data-testid="row">{name('catalog_item', id)}</li>)}</ul>
}

afterEach(cleanup)

beforeEach(() => {
  queryRecords.mockReset()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('useReferenceLabels', () => {
  it('batches one call per type, de-duplicates, shows "code - title"; loading is an ellipsis', async () => {
    queryRecords.mockResolvedValue({ items: [rec(A, { code: 'ITM-1', name: 'Bolt' }), rec(B, { name: 'Nut' })], next_cursor: null })
    const { container } = wrap(<Probe ids={[A, B, A]} />)
    expect(screen.getAllByTestId('row')[0].textContent).toBe('…')
    await waitFor(() => expect(screen.getAllByTestId('row')[0].textContent).toBe('ITM-1 - Bolt'))
    expect(screen.getAllByTestId('row')[1].textContent).toBe('Nut')
    expect(queryRecords).toHaveBeenCalledTimes(1)
    expect(queryRecords.mock.calls[0][1].filters[0]).toEqual({ field: 'record_id', op: 'in', value: [A, B].sort() })
    expect(noUuidInDom(container)).toBe(true)
  })

  it.each(['en', 'ru', 'kk'] as const)('a failed lookup shows the "unknown" text in %s, not the id', async (loc) => {
    useUiLocaleStore.getState().setLocaleTransient(loc)
    queryRecords.mockRejectedValue({ status: 500 })
    const { container } = wrap(<Probe ids={[A]} />)
    await waitFor(() => expect(screen.getByTestId('row').textContent).toBe(REFERENCE_MESSAGES[loc].unknown))
    expect(noUuidInDom(container)).toBe(true)
  })

  it('a record that is not returned (hidden, deleted) shows "unknown"', async () => {
    queryRecords.mockResolvedValue({ items: [], next_cursor: null })
    wrap(<Probe ids={[A]} />)
    await waitFor(() => expect(screen.getByTestId('row').textContent).toBe('Unknown record'))
  })

  it('a value that is not a uuid (a code) is shown as it is; empty is empty', async () => {
    queryRecords.mockResolvedValue({ items: [], next_cursor: null })
    wrap(<Probe ids={['LOT-7', '']} />)
    await waitFor(() => expect(screen.getAllByTestId('row')[0].textContent).toBe('LOT-7'))
    expect(screen.getAllByTestId('row')[1].textContent).toBe('')
  })
})

describe('ReferenceLabel', () => {
  it('renders one reference value', async () => {
    queryRecords.mockResolvedValue({ items: [rec(A, { code: 'MS', name: 'Main store' })], next_cursor: null })
    const { container } = wrap(<p data-testid="p"><ReferenceLabel type="catalog_item" id={A} /></p>)
    await waitFor(() => expect(screen.getByTestId('p').textContent).toBe('MS - Main store'))
    expect(noUuidInDom(container)).toBe(true)
  })
})

describe('reference messages', () => {
  it('en, ru and kk carry the same keys, none empty', () => {
    const keys = (l: 'en' | 'ru' | 'kk') => Object.keys(REFERENCE_MESSAGES[l]).sort()
    expect(keys('ru')).toEqual(keys('en'))
    expect(keys('kk')).toEqual(keys('en'))
    const doc = (l: 'en' | 'ru' | 'kk') => Object.keys(REFERENCE_MESSAGES[l].docType).sort()
    expect(doc('ru')).toEqual(doc('en'))
    expect(doc('kk')).toEqual(doc('en'))
    for (const l of ['en', 'ru', 'kk'] as const) {
      expect(REFERENCE_MESSAGES[l].unknown).not.toBe('')
      expect(Object.values(REFERENCE_MESSAGES[l].docType).every((v) => v !== '')).toBe(true)
    }
  })
})
