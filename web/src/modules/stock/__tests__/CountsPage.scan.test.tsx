// @vitest-environment jsdom
/** S1–S7 — GH 3761 / REQ-720 criterion 1: keyboard-scanner input on the count sheet. Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn } from '../counts/countsMessages'
import { BASE, LIST, READ_ONLY, fakeCounts, line, order, problem, renderCounts, writes } from './countsTestKit'

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

const COUNTING = order({ status: 'counting' })
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const setup = (extra: Parameters<typeof fakeCounts>[1] = {}) =>
  fakeCounts(clientMock, { orders: [COUNTING], linePages: [[line(1), line(2)]], ...extra })
const scans = () => writes(clientMock).filter(([, p]) => p.endsWith('/scan'))

async function pickPlace() {
  const place = await screen.findByTestId('scan-place')
  await waitFor(() => expect(place.querySelectorAll('option').length).toBeGreaterThan(1))
  await userEvent.selectOptions(place.querySelector('select')!, 'l1')
}

describe('S1 focus', () => {
  it('the scan input is focused after load and after each answer', async () => {
    setup({ postAnswers: { '/scan': { line_no: 1, counted_quantity: '1', duplicate: false } } })
    renderCounts(`${LIST}/c1`)
    const input = await screen.findByTestId('scan-input')
    expect(input).toHaveFocus()
    await pickPlace()
    await userEvent.type(input, 'ABC{Enter}')
    await waitFor(() => expect(scans()).toHaveLength(1))
    await waitFor(() => expect(input).toHaveFocus())
  })
})

describe('S2 body', () => {
  it('Enter posts exactly {scanned_text unchanged, location_id, scan_id}', async () => {
    setup({ postAnswers: { '/scan': { line_no: 1, counted_quantity: '1', duplicate: false } } })
    renderCounts(`${LIST}/c1`)
    await pickPlace()
    await userEvent.type(await screen.findByTestId('scan-input'), ' 460 123 {Enter}')
    await waitFor(() => expect(scans()).toHaveLength(1))
    const body = scans()[0]![2] as Record<string, string>
    expect(Object.keys(body).sort()).toEqual(['location_id', 'scan_id', 'scanned_text'])
    expect(body['scanned_text']).toBe(' 460 123 ')
    expect(body['location_id']).toBe('l1')
    expect(body['scan_id']).toMatch(UUID)
    expect(scans()[0]![1]).toBe(`${BASE}/c1/scan`)
  })
})

describe('S3 answers', () => {
  it('a location answer sets the place; a line answer highlights the line; a duplicate is an info message', async () => {
    let n = 0
    setup({
      postAnswers: {
        '/scan': () => [
          { kind: 'location', location_id: 'l2', scanned_text: 'LOC' },
          { line_no: 2, counted_quantity: '5', duplicate: false },
          { line_no: 2, counted_quantity: '5', duplicate: true },
        ][n++],
      },
    })
    renderCounts(`${LIST}/c1`)
    await pickPlace()
    const input = await screen.findByTestId('scan-input')
    await userEvent.type(input, 'LOC{Enter}')
    await waitFor(() => expect((screen.getByTestId('scan-place').querySelector('select') as HTMLSelectElement).value).toBe('l2'))
    await userEvent.type(input, 'X{Enter}')
    expect(await screen.findByText('Scanned')).toBeInTheDocument()
    await userEvent.type(input, 'X{Enter}')
    expect(await screen.findByText(countsEn['counts.scan.duplicate'].replace('{line}', '2'))).toBeInTheDocument()
    expect(scans()).toHaveLength(3)
  })
})

describe('S4 needs', () => {
  it('empty input or no place sends nothing and shows a field message', async () => {
    setup()
    renderCounts(`${LIST}/c1`)
    const input = await screen.findByTestId('scan-input')
    await userEvent.type(input, '{Enter}')
    expect(await screen.findByText(countsEn['counts.scan.needText'])).toBeInTheDocument()
    await userEvent.type(input, 'ABC{Enter}')
    expect(await screen.findByText(countsEn['counts.scan.needPlace'])).toBeInTheDocument()
    expect(scans()).toHaveLength(0)
  })
})

describe('S5 retry', () => {
  it('after a network failure Retry resends the same body with the same scan_id', async () => {
    let n = 0
    setup({
      postAnswers: {
        '/scan': () => {
          if (n++ === 0) throw new TypeError('Failed to fetch')
          return { line_no: 1, counted_quantity: '1', duplicate: true }
        },
      },
    })
    renderCounts(`${LIST}/c1`)
    await pickPlace()
    await userEvent.type(await screen.findByTestId('scan-input'), 'ABC{Enter}')
    await userEvent.click(await screen.findByTestId('scan-retry'))
    await waitFor(() => expect(scans()).toHaveLength(2))
    expect(scans()[1]![2]).toEqual(scans()[0]![2])
    expect(await screen.findByText(countsEn['counts.scan.duplicate'].replace('{line}', '1'))).toBeInTheDocument()
  })
})

describe('S6 visibility', () => {
  it('is absent when the status is not counting and without StockCountRecord', async () => {
    setup({ orders: [order({ status: 'counted' })] })
    renderCounts(`${LIST}/c1`)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('scan-input')).toBeNull()
    cleanup()
    setup()
    renderCounts(`${LIST}/c1`, READ_ONLY)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('scan-input')).toBeNull()
  })
})

describe('S7 unknown code', () => {
  it('a 404 on a scan shows the unknown-code message, not the not-found state', async () => {
    setup({ fail: { 'POST /c1/scan': problem(404) } })
    renderCounts(`${LIST}/c1`)
    await pickPlace()
    await userEvent.type(await screen.findByTestId('scan-input'), 'ZZZ{Enter}')
    expect(await screen.findByText(countsEn['counts.scan.unknownCode'])).toBeInTheDocument()
    expect(screen.queryByText(countsEn['counts.error.notFound'])).toBeNull()
  })
})
