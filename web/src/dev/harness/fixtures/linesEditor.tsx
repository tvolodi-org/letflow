/** Harness fixtures of the lines editor (T-1448, state list of the design repo NOTES.md "Lines editor"). The REAL stock document
 *  screens with invented data: new draft (empty state), 1, 20 and 100 lines (the maximum), validation, read-only posted view of
 *  150 lines, no permission, line by line, and the scan, paste and import results reached by a script that fires the events on
 *  mount. The loading and error states belong to the component, so they render `LFLinesEditor` directly. */
import { useEffect, useState, type ReactElement } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { LFLinesEditor } from '@/components/ui/lines/LFLinesEditor'
import DocumentNewPage from '@/modules/stock/documents/DocumentNewPage'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import type { EntityRecord } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { ACCESS, AUTH, EDIT_LABELS, OpenInEdit, SAVE_LABELS, withAuth } from './stockDocuments'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})

const ITEMS: [string, string, string][] = [
  ['GATEA-M-2611', 'Milk 2.5% 1 l', 'none'],
  ['GATEA-B-0042', 'Wheat bread, sliced', 'lot'],
  ['GATEA-F-0100', 'Flour, premium grade, 50 kg sack', 'lot'],
  ['GATEA-S-0007', 'Sugar, granulated, 1 kg', 'none'],
  ['GATEA-T-0311', 'Black tea, 100 bags', 'none'],
]
const MASTERS: Record<string, EntityRecord[]> = {
  catalog_item: ITEMS.map(([code, name, policy], i) => rec(`i${i}`, 'catalog_item', { code, name, base_uom_id: 'm1', tracking_policy: policy, barcode: `46000${i}` })),
  location_node: [rec('l1', 'location_node', { code: 'WH-1', name: 'Central warehouse' })],
  org_unit: [rec('u1', 'org_unit', { code: 'GATEA', name: 'Gatea bakery' })],
  org_employee: [rec('e1', 'org_employee', { code: 'E-1', full_name: 'Aigerim Sarsenova' })],
  catalog_lot: [rec('t1', 'catalog_lot', { code: 'LOT-2026-001', item_id: 'i1' })],
  catalog_uom: [rec('m1', 'catalog_uom', { name: 'pcs' })],
}

const mkLines = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    line_id: `g${i}`,
    line_no: i + 1,
    catalog_item_id: `i${i % ITEMS.length}`,
    catalog_uom_id: 'm1',
    catalog_lot_id: null,
    quantity: `${1 + (i % 9)}.000`,
    unit_price: `${100 + i}.00`,
    line_value: `${(1 + (i % 9)) * (100 + i)}.00`,
  }))
const doc = (id: string, n: number, over: Record<string, unknown> = {}) => ({
  id,
  kind: 'receipt',
  state: 'draft',
  number: null,
  header_id: 'h1',
  org_unit_id: 'u1',
  location_id: 'l1',
  responsible_id: 'e1',
  counterparty_id: null,
  event_time: '2026-11-03T09:15:00Z',
  note: null,
  lines: mkLines(n),
  posted_at: null,
  posted_by: null,
  entry_id: null,
  reversed_at: null,
  reversed_by: null,
  posting_check: null,
  ...over,
})
const DOCS: Record<string, Record<string, unknown>> = {
  'lines-1': doc('lines-1', 1),
  'lines-20': doc('lines-20', 20),
  'lines-100': doc('lines-100', 100),
  'lines-posted-150': doc('lines-posted-150', 150, { state: 'posted', number: 'RC-000150', posted_at: '2026-11-03T10:00:00Z' }),
  'lines-bad': doc('lines-bad', 3, {
    lines: mkLines(3).map((l, i) => (i === 1 ? { ...l, quantity: '0' } : i === 2 ? { ...l, catalog_item_id: '' } : l)),
  }),
}

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; value?: unknown }[] }
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      let items = MASTERS[b.entity_type ?? ''] ?? []
      if (Array.isArray(ids)) items = items.filter((r) => ids.includes(r.record_id))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/stock/documents/') && method === 'GET',
    reply: (_s, path) => {
      const found = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
      return found ? { status: 200, body: found } : { status: 404, body: { error: 'not_found' } }
    },
  },
]

const STORAGE = 'lf.linesMode.stock-documents.lines'
/** Harness only: the remembered mode is read at mount from localStorage. */
function mode(m: 'grid' | 'form'): void {
  try {
    localStorage.setItem(STORAGE, m)
  } catch {
    /* no storage in this browser profile: the default (grid) shows */
  }
}

/** Harness only: runs `step` every 60 ms until it returns true (bounded to 6 s). */
function Script({ step, children }: { step: () => boolean; children: ReactElement }): ReactElement {
  useEffect(() => {
    const started = Date.now()
    const id = window.setInterval(() => {
      if (Date.now() - started > 6000 || step()) window.clearInterval(id)
    }, 60)
    return () => window.clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return children
}
const button = (labels: string[]) => Array.from(document.querySelectorAll('button')).find((b) => labels.includes(b.textContent?.trim() ?? ''))
const setValue = (el: HTMLInputElement, v: string) => {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(el, v)
  el.dispatchEvent(new Event('input', { bubbles: true }))
}
const ADD = ['Add line', 'Добавить строку', 'Жол қосу']
const SAVE_NEXT = ['Save and add next', 'Сохранить и добавить следующую', 'Сақтап, келесіні қосу']

/** Edit mode of a draft, then `after` once the rows are drawn. */
const editThen = (after: () => boolean) => {
  let opened = false
  return () => {
    if (!opened) {
      const edit = button(EDIT_LABELS)
      if (edit) {
        edit.click()
        opened = true
      }
      return false
    }
    return after()
  }
}
const pasteInto = (text: string) => {
  const qty = document.querySelector<HTMLInputElement>('[data-testid="line-editor-row"] input')
  if (!qty) return false
  const dt = new DataTransfer()
  dt.setData('text', text)
  qty.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
  return true
}
const scan = (code: string) => {
  const input = document.querySelector<HTMLInputElement>('.lf-le__scanf input')
  if (!input) return false
  setValue(input, code)
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
  return true
}

function Direct({ state }: { state: 'loading' | 'error' | 'noperm' }): ReactElement {
  const [m, setM] = useState<'grid' | 'form'>('grid')
  return withAuth(
    <section className="lf-card lf-doc__lines" style={{ height: 420 }}>
      <LFLinesEditor<{ a: string }>
        screenId="lines-direct"
        lines={[{ a: '' }]}
        onChange={() => undefined}
        columns={[{ key: 'a', label: 'Item', view: (l) => l.a }]}
        blank={() => ({ a: '' })}
        duplicate={(l) => l}
        isBlank={() => true}
        max={100}
        mode={m}
        onModeChange={setM}
        state={state === 'noperm' ? 'ready' : state}
        noPermission={state === 'noperm'}
        searchText={(l) => l.a}
      />
    </section>,
  )
}

const NOPERM = { ...ACCESS, info: { ...ACCESS.info, permissions: ['StockRead'] } }

function Page({ id, children }: { id?: string; children?: ReactElement }): ReactElement {
  void id
  return children ?? <DocumentPage />
}

const screen = (name: string, initialPath: string, render: () => ReactElement): HarnessScreen => ({ name, routes, initialPath, routePattern: '/:id', render })

export const linesEditorScreens: HarnessScreen[] = [
  { name: 'lines-grid-empty', routes, initialPath: '/?kind=issue', render: () => (mode('grid'), withAuth(<DocumentNewPage />)) },
  screen('lines-grid-1line', '/lines-1', () => (mode('grid'), withAuth(<OpenInEdit><Page /></OpenInEdit>))),
  screen('lines-grid-20lines', '/lines-20', () => (mode('grid'), withAuth(<OpenInEdit><Page /></OpenInEdit>))),
  screen('lines-grid-max', '/lines-100', () => (mode('grid'), withAuth(<OpenInEdit><Page /></OpenInEdit>))),
  screen('lines-grid-validation', '/lines-bad', () => (mode('grid'), withAuth(
    <Script step={editThen(() => {
      const save = button(SAVE_LABELS)
      if (!save) return false
      save.click()
      return true
    })}><Page /></Script>))),
  screen('lines-grid-paste', '/lines-1', () => (mode('grid'), withAuth(
    <Script step={editThen(() => pasteInto('GATEA-B-0042\t\t12,5\t340\nGATEA-S-0007\t\t3\t520\nNOPE-1\t\t4\t10'))}><Page /></Script>))),
  screen('lines-grid-scan', '/lines-20', () => (mode('grid'), withAuth(
    <Script step={editThen(() => scan('GATEA-T-0311'))}><Page /></Script>))),
  screen('lines-grid-readonly', '/lines-posted-150', () => (mode('grid'), withAuth(<Page />))),
  screen('lines-form-editing', '/lines-20', () => (mode('form'), withAuth(
    <Script step={editThen(() => {
      const add = button(ADD)
      if (!add) return false
      add.click()
      return true
    })}><Page /></Script>))),
  screen('lines-form-list', '/lines-20', () => (mode('form'), withAuth(<OpenInEdit><Page /></OpenInEdit>))),
  screen('lines-form-readonly', '/lines-posted-150', () => (mode('form'), withAuth(<Page />))),
  screen('lines-form-next', '/lines-1', () => (mode('form'), withAuth(
    <Script step={editThen(() => {
      const next = button(SAVE_NEXT)
      if (next) {
        next.click()
        return true
      }
      const add = button(ADD)
      if (add) add.click()
      return false
    })}><Page /></Script>))),
  {
    name: 'lines-noperm-doc',
    routes,
    initialPath: '/lines-20',
    routePattern: '/:id',
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={NOPERM}>
          <div className="lf-main"><main className="lf-content"><DocumentPage /></main></div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
  { name: 'lines-loading', routes, render: () => <Direct state="loading" /> },
  { name: 'lines-error', routes, render: () => <Direct state="error" /> },
  { name: 'lines-noperm', routes, render: () => <Direct state="noperm" /> },
  { name: 'lines-scan-sample', routes, initialPath: '/?kind=issue', render: () => (mode('grid'), withAuth(
    <Script step={() => {
      const add = button(ADD)
      if (add && !document.querySelector('[data-testid="line-editor-row"]')) {
        add.click()
        return false
      }
      return scan('4600012')
    }}><DocumentNewPage /></Script>)) },
]
