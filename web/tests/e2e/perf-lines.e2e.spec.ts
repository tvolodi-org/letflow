/**
 * T-1533 — manual browser performance run of the stock lines editor: open, scroll, search, validate, save and post at
 * 100, 500 and 1000 lines, 3 runs per cell, in a real Chromium against the GATE B stack (scripts/e2e/stack_up.sh) with the
 * fixed item set of scripts/e2e/perf_lines_seed.sh. NOT run in CI (tagged @manual @perf, so `npm run test:e2e` skips it).
 *
 *   npm run test:e2e:perf     (see "Performance run (manual)" in docs/testing/gate-b-browser-e2e.md)
 *
 * Writes web/test-results/perf-lines/<run>.json and prints a markdown table. The numbers and limits live in
 * docs/status/stock-lines-browser-perf-2026-11.md. Writes about 5,000 records per run: never against QA without the owner.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync, writeFileSync } from 'node:fs'
import { choose, ENV, hasAdmin, openRoute, signIn, SKIP_REASON } from './support/gateB'
import { buildPasteText, invalidCount, perfCode, toMarkdownTable, type PerfTable } from './support/perfLines'

const SIZES = (process.env.PERF_SIZES ?? '100,500,1000').split(',').map(Number)
const RUNS = Number(process.env.PERF_RUNS ?? 3)
const POLL_LIMIT_MS = 120_000

test.describe.configure({ mode: 'serial' })
test.skip(!hasAdmin, SKIP_REASON)

const table: PerfTable = {}
const extra: Record<string, unknown> = {}
const rec = (op: string, n: number, ms: number) => {
  const byOp = (table[op] ??= {})
  const runs = (byOp[n] ??= [])
  runs.push(Math.round(ms * 10) / 10)
}

let page: Page

test.beforeAll(async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  page = await context.newPage()
  await signIn(page, ENV.admin, ENV.adminPw)
})

test.afterAll(async () => {
  const dir = 'test-results/perf-lines'
  mkdirSync(dir, { recursive: true })
  const file = `${dir}/${ENV.runTag}.json`
  writeFileSync(file, JSON.stringify({ runTag: ENV.runTag, sizes: SIZES, runs: RUNS, table, extra }, null, 2))
  console.log(`\n${toMarkdownTable(table, SIZES)}\n(median / max ms; raw: ${file})\n`)
  await page?.context().close()
})

const ROW = '[data-testid="line-editor-row"],[data-testid="line-saved-row"],[data-testid="line-row"]'

/** Paste `text` on the item cell of the first row; resolves with the ms until `done` is true (rAF-polled in the page). */
async function pasteAndWait(p: Page, text: string, done: 'errors' | 'clean', n: number): Promise<number> {
  return p.evaluate(
    async ({ text, done, n }) => {
      // the first mounted row is row 1 only at the top of the grid (virtual rows): go there before pasting
      const sc = document.querySelector<HTMLElement>('[data-testid="lines-scroll"]')
      if (sc) sc.scrollTop = 0
      for (let k = 0; k < 3; k += 1) await new Promise((r) => requestAnimationFrame(() => r(null)))
      const td = document.querySelector<HTMLElement>('[data-testid="line-editor-row"] td[data-col="item"]')
      if (!td) throw new Error('no first row cell to paste into')
      const dt = new DataTransfer()
      dt.setData('text', text)
      const t0 = performance.now()
      td.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
      const ok = () => {
        const btn = document.querySelector('.lf-le__errbtn')
        const notice = document.querySelector('[data-testid="lines-notice"]')?.textContent ?? ''
        const count = document.querySelector('.lf-le__count')?.textContent ?? ''
        return (done === 'errors' ? !!btn : !btn && notice !== '') && count.includes(`${n} of`)
      }
      while (!ok()) {
        if (performance.now() - t0 > 20_000) return -1 // never reached the expected state: the caller records it
        await new Promise((r) => requestAnimationFrame(() => r(null)))
      }
      return performance.now() - t0
    },
    { text, done, n },
  )
}

async function scrollRun(p: Page): Promise<{ total: number; maxGap: number; maxRows: number }> {
  return p.evaluate(async () => {
    const el = document.querySelector<HTMLElement>('[data-testid="lines-scroll"],[data-testid="lines-saved"]')
    if (!el) throw new Error('no scroll container')
    const rows = () => document.querySelectorAll('[data-testid="line-editor-row"],[data-testid="line-saved-row"],[data-testid="line-row"]').length
    const frame = () => new Promise<number>((r) => requestAnimationFrame((t) => r(t)))
    const range = el.scrollHeight - el.clientHeight
    let last = await frame()
    let maxGap = 0
    let maxRows = rows()
    const t0 = performance.now()
    const steps = [...Array.from({ length: 20 }, (_, i) => i + 1), ...Array.from({ length: 20 }, (_, i) => 19 - i)]
    for (const s of steps) {
      el.scrollTop = (range * s) / 20
      const now = await frame()
      maxGap = Math.max(maxGap, now - last)
      last = now
      maxRows = Math.max(maxRows, rows())
    }
    return { total: performance.now() - t0, maxGap, maxRows }
  })
}

async function searchRun(p: Page, code: string, n: number): Promise<number> {
  const box = p.getByPlaceholder('Search in lines')
  const t0 = performance.now()
  await box.fill(code)
  await p.waitForFunction((n) => /of \d+ lines shown/.test(document.querySelector('.lf-le__count')?.textContent ?? '') && !(document.querySelector('.lf-le__count')?.textContent ?? '').startsWith(`${n} of`), n, { polling: 'raf', timeout: 30_000 })
  const ms = performance.now() - t0
  await box.fill('')
  await expect(p.locator('.lf-le__count')).toContainText(`${n} of`)
  return ms
}

async function headerNumber(p: Page): Promise<string> {
  const text = (await p.getByTestId('document-header').innerText()).replace(/\s+/g, ' ')
  return /([A-Z]{1,6}[-/]?\d[\w-]*)/.exec(text)?.[1] ?? ''
}

for (const n of SIZES) {
  test(`P${n} lines @manual @perf`, async () => {
    test.setTimeout(40 * 60_000)
    for (let run = 1; run <= RUNS; run += 1) {
      // ---- new receipt, rows in by one paste ----
      await openRoute(page, '/admin/stock/documents/new')
      const form = page.getByTestId('document-form')
      await expect(form).toBeVisible()
      await choose(form.getByLabel('Kind'), 'Receipt')
      await choose(form.getByLabel('Org unit'), 'Warehouse')
      await choose(form.getByLabel('Location'), 'Central')
      await choose(form.getByLabel('Responsible'))
      await form.getByLabel('Note').fill(`perf ${n} run ${run} ${ENV.runTag}`)
      await page.getByRole('button', { name: 'Add line' }).click()
      // the item catalog is loaded when the picker offers PERF-0001 (paste resolves codes against it)
      const first = page.getByTestId('line-editor-row').first()
      await first.getByLabel('Item').fill('PERF-0001')
      await expect(page.getByRole('option', { name: /PERF-0001/ }).first()).toBeVisible({ timeout: 30_000 })
      await page.keyboard.press('Escape')

      // validate: paste with 2% invalid rows -> error button; then paste the valid list over it -> no error button
      rec('validate (paste to errors shown)', n, await pasteAndWait(page, buildPasteText(n, true), 'errors', n))
      const errText = (await page.locator('.lf-le__errbtn').first().innerText()).replace(/\s+/g, ' ')
      extra[`errorButton ${n}`] = errText
      // the invalid rows are 2% of the list; the editor may flag more lines (extra[`errorLines n`] says which)
      expect(Number(/\d+/.exec(errText)?.[0] ?? 0)).toBeGreaterThanOrEqual(invalidCount(n))
      const flagged: string[] = []
      for (let k = 0; k < Math.min(invalidCount(n) + 4, 12); k += 1) {
        await page.locator('.lf-le__errbtn').first().click()
        flagged.push(await page.evaluate(() => (document.activeElement?.closest('tr') as HTMLElement | null)?.children[0]?.textContent?.trim() ?? '?'))
      }
      extra[`errorLines ${n}`] = flagged
      rec('validate (fix paste to clean)', n, await pasteAndWait(page, buildPasteText(n, false), 'clean', n))
      extra[`notice ${n}`] = await page.evaluate(() => document.querySelector('[data-testid="lines-notice"]')?.textContent ?? '')
      extra[`errbtn after valid paste ${n}`] = await page.evaluate(() => document.querySelector('.lf-le__errbtn')?.textContent ?? null)

      // save: browser time, plus the longest write request as the server's share
      const writes: number[] = []
      const onDone = (r: import('@playwright/test').Request) => {
        if (r.method() !== 'GET') writes.push(r.timing().responseEnd)
      }
      page.on('requestfinished', onDone)
      const ts = performance.now()
      await page.getByRole('button', { name: 'Save draft' }).click()
      await expect(page.getByTestId('document-header')).toBeVisible({ timeout: 120_000 })
      await expect(page.getByTestId('document-actions')).toBeVisible()
      rec('save', n, performance.now() - ts)
      page.off('requestfinished', onDone)
      rec('save (longest write request)', n, Math.max(0, ...writes))
      const url = page.url()
      const number = await headerNumber(page)

      // open: fresh load of the saved draft
      const to = performance.now()
      await page.goto(url, { waitUntil: 'domcontentloaded' })
      await expect(page.locator('.lf-le__count')).toContainText(`${n} of`, { timeout: 120_000 })
      await expect(page.locator(ROW).first()).toBeVisible()
      rec('open', n, performance.now() - to)
      if (n === Math.max(...SIZES) && run === 1) {
        extra[`heapBytes ${n}`] = await page.evaluate(() => (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory?.usedJSHeapSize ?? null)
      }

      // scroll + search on the opened document
      const sc = await scrollRun(page)
      rec('scroll (total, 40 steps)', n, sc.total)
      rec('scroll (longest frame gap)', n, sc.maxGap)
      rec('scroll (max mounted rows)', n, sc.maxRows)
      rec('search', n, await searchRun(page, perfCode(n - 1), n))

      // post: issue, then claim + complete the posting task, then wait for Posted
      page.on('requestfinished', onDone)
      writes.length = 0
      const ti = performance.now()
      await page.getByTestId('document-actions').getByRole('button', { name: 'Issue', exact: true }).click()
      await page.getByRole('dialog').getByRole('button', { name: 'Issue', exact: true }).click()
      await expect(page.getByTestId('document-header')).toContainText(/Issued|Posted/i, { timeout: POLL_LIMIT_MS })
      rec('issue', n, performance.now() - ti)
      page.off('requestfinished', onDone)

      await openRoute(page, '/tasks')
      const rows = page.getByTestId('task-row')
      await expect(rows.first()).toBeVisible({ timeout: 30_000 })
      const own = rows.filter({ hasText: number })
      await ((await own.count()) > 0 ? own.first() : rows.first()).click()
      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      const claim = page.getByTestId('task-claim-button')
      await expect(claim.or(page.getByTestId('task-complete-button'))).toBeVisible({ timeout: 20_000 })
      if (await claim.isVisible().catch(() => false)) await claim.click()
      await expect(page.getByTestId('task-complete-button')).toBeVisible({ timeout: 20_000 })
      const tp = performance.now()
      await page.getByTestId('task-complete-button').click()
      await expect
        .poll(
          async () => {
            await page.goto(url, { waitUntil: 'domcontentloaded' })
            return (await page.getByTestId('document-header').innerText().catch(() => '')).includes('Posted')
          },
          { timeout: POLL_LIMIT_MS, intervals: [500, 1000, 2000] },
        )
        .toBe(true)
      rec('post (complete click to Posted)', n, performance.now() - tp)
    }
  })
}
