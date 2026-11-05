// @vitest-environment jsdom
/** W1–W3 — GH 3763 / REQ-718: the posting panel of a signed count (Post, Issue posting record, Reverse). Network mocked. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { countsEn, countsKk, countsRu } from '../counts/countsMessages'
import { BASE, LIST, accessOf, fakeCounts, order, problem, renderCounts, writes } from './countsTestKit'

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

const ALL = accessOf('StockRead', 'StockCountRecord', 'StockPost', 'StockReverse')
const SIGNED = order({
  status: 'signed', sheet_document_id: 's1', differences_document_id: 'd2', differences_signed_at: '2026-11-10T10:00:00Z',
  posting_state: 'none', post_pending: false, reverse_pending: false, posting_check: null,
})
const POSTED = { ...SIGNED, posting_state: 'posted' as const, entry_id: 'en-7', posted_at: '2026-11-10T11:00:00Z', posting_check: 'ok' as const }

describe('W1 Post', () => {
  it('shows Post for StockPost on a signed count; click, confirm, POST post', async () => {
    fakeCounts(clientMock, { orders: [SIGNED], postAnswers: { '/post': { ...SIGNED, posting_state: 'pending', post_pending: true } } })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByTestId('posting-state')).toHaveTextContent('Not posted')
    await userEvent.click(await screen.findByTestId('count-post'))
    await userEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/post`, undefined]]))
  })

  it('hides Post without the atom, and when posting is pending or done', async () => {
    fakeCounts(clientMock, { orders: [SIGNED] })
    renderCounts(`${LIST}/c1`, accessOf('StockRead', 'StockCountRecord'))
    await screen.findByTestId('posting-panel')
    expect(screen.queryByTestId('count-post')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [{ ...SIGNED, posting_state: 'pending', post_pending: true }] })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByText(countsEn['counts.posting.waiting.post'])).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open the task inbox' })).toHaveAttribute('href', '/tasks')
    expect(screen.queryByTestId('count-post')).toBeNull()
  })

  it('shows no panel before the count is signed', async () => {
    fakeCounts(clientMock, { orders: [order({ status: 'counted', sheet_document_id: 's1' })] })
    renderCounts(`${LIST}/c1`, ALL)
    await screen.findByTestId('count-facts')
    expect(screen.queryByTestId('posting-panel')).toBeNull()
  })
})

describe('W2 posting record and Reverse', () => {
  it('Issue posting record for a posted, signed count with StockCountRecord', async () => {
    fakeCounts(clientMock, { orders: [POSTED], postAnswers: { '/posting-record': { ...POSTED, status: 'posted', posting_document_id: 'p1' } } })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByTestId('posting-state')).toHaveTextContent('Posted')
    expect(screen.getByText('en-7')).toBeInTheDocument()
    await userEvent.click(await screen.findByTestId('count-posting-record'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/posting-record`, undefined]]))
  })

  it('Reverse needs a reason code, and text for Other; then POST reverse', async () => {
    fakeCounts(clientMock, { orders: [POSTED], postAnswers: { '/reverse': { ...POSTED, reverse_pending: true } } })
    renderCounts(`${LIST}/c1`, ALL)
    await userEvent.click(await screen.findByTestId('count-reverse'))
    const dialog = await screen.findByTestId('count-reverse-dialog')
    const confirm = () => userEvent.click(screen.getByTestId('count-reverse-dialog-confirm'))
    await confirm()
    expect(writes(clientMock)).toEqual([])
    await userEvent.selectOptions(dialog.querySelector('select') as HTMLSelectElement, 'other')
    await confirm()
    expect(writes(clientMock)).toEqual([])
    await userEvent.type(dialog.querySelector('textarea') as HTMLTextAreaElement, 'wrong sheet')
    await confirm()
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/reverse`, { reason_code: 'other', reason_text: 'wrong sheet' }]]))
  })

  it('hides Reverse without StockReverse and while a reversal is pending', async () => {
    fakeCounts(clientMock, { orders: [POSTED] })
    renderCounts(`${LIST}/c1`, accessOf('StockRead', 'StockCountRecord', 'StockPost'))
    await screen.findByTestId('posting-panel')
    expect(screen.queryByTestId('count-reverse')).toBeNull()
    cleanup()

    fakeCounts(clientMock, { orders: [{ ...POSTED, reverse_pending: true }] })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByText(countsEn['counts.posting.waiting.reverse'])).toBeInTheDocument()
    expect(screen.queryByTestId('count-reverse')).toBeNull()
  })
})

describe('W3 refusals and the posting check', () => {
  it.each([
    [409, 'posting_pending'],
    [422, 'no_differences'],
    [409, 'count_posted'],
    [409, 'definition_not_active'],
  ])('shows the own message of %s %s', async (status, reason) => {
    fakeCounts(clientMock, { orders: [SIGNED], fail: { 'POST /c1/post': problem(status, reason) } })
    renderCounts(`${LIST}/c1`, ALL)
    await userEvent.click(await screen.findByTestId('count-post'))
    await userEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    expect(await screen.findByText(countsEn[`counts.reason.${reason}`])).toBeInTheDocument()
  })

  it('shows a refusal of the posting record next to the button', async () => {
    fakeCounts(clientMock, { orders: [POSTED], fail: { 'POST /c1/posting-record': problem(422, 'not_chair') } })
    renderCounts(`${LIST}/c1`, ALL)
    await userEvent.click(await screen.findByTestId('count-posting-record'))
    expect(await screen.findByText(countsEn['counts.reason.not_chair'])).toBeInTheDocument()
  })

  it('shows the mismatch banner and no detail', async () => {
    fakeCounts(clientMock, { orders: [{ ...POSTED, posting_check: 'mismatch' }] })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByText(countsEn['counts.posting.mismatch'])).toBeInTheDocument()
  })
})

describe('P50c empty sheet, shortage and rules', () => {
  const EMPTY = { ...SIGNED, differences_empty: true }

  it('W2 a signed empty sheet shows the hint and the record button, which posts the record', async () => {
    fakeCounts(clientMock, { orders: [EMPTY], postAnswers: { '/posting-record': { ...EMPTY, status: 'posted', posting_document_id: 'p1' } } })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByTestId('posting-empty-hint')).toHaveTextContent(countsEn['counts.posting.emptyHint'])
    expect(screen.queryByTestId('count-post')).toBeNull()
    await userEvent.click(await screen.findByTestId('count-posting-record'))
    await waitFor(() => expect(writes(clientMock)).toEqual([['POST', `${BASE}/c1/posting-record`, undefined]]))
  })

  it('W2b a signed count with differences shows no empty hint and no record button before posting', async () => {
    fakeCounts(clientMock, { orders: [{ ...SIGNED, differences_empty: false }] })
    renderCounts(`${LIST}/c1`, ALL)
    await screen.findByTestId('posting-panel')
    expect(screen.queryByTestId('posting-empty-hint')).toBeNull()
    expect(screen.queryByTestId('count-posting-record')).toBeNull()
  })

  it.each([
    ['en', countsEn, 'The shortage of Bolt M8 at Shelf A is larger than the current balance.'],
    ['ru', countsRu, 'Недостача по Bolt M8 в Shelf A больше текущего остатка.'],
    ['kk', countsKk, 'Shelf A орнындағы Bolt M8 жетіспеушілігі ағымдағы қалдықтан көп.'],
  ] as const)('W3 a shortage refusal names the item and the location in %s', async (lang, msgs, start) => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    const err = { status: 422, message: 'x', code: '422', details: { reason: 'shortage_exceeds_balance', line_no: 1, catalog_item_id: 'i1', location_id: 'l1' } }
    fakeCounts(clientMock, { orders: [SIGNED], fail: { 'POST /c1/post': err } })
    renderCounts(`${LIST}/c1`, ALL)
    await userEvent.click(await screen.findByTestId('count-post'))
    await userEvent.click(await screen.findByTestId('confirm-dialog-confirm'))
    const box = await screen.findByTestId('confirm-dialog-error')
    await waitFor(() => expect(box).toHaveTextContent(start))
    expect(msgs['counts.reason.shortage_exceeds_balance']).toContain('{item}')
  })

  it.each([
    ['en', countsEn],
    ['ru', countsRu],
    ['kk', countsKk],
  ] as const)('W4 the signed rule is shown in %s; a reversed count shows its rule and no Post button', async (lang, msgs) => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    fakeCounts(clientMock, { orders: [{ ...POSTED, posting_state: 'reversed', reversed_at: '2026-11-10T12:00:00Z' }] })
    renderCounts(`${LIST}/c1`, ALL)
    expect(await screen.findByTestId('posting-reversed-rule')).toHaveTextContent(msgs['counts.posting.reversedRule'])
    expect(screen.getByTestId('posting-no-cancel-rule')).toHaveTextContent(msgs['counts.posting.noCancelRule'])
    expect(screen.queryByTestId('count-post')).toBeNull()
  })
})
