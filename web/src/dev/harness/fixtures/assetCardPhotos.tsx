/** Harness fixtures of the asset card gallery (T-2042, photos P3): the Photos tab and the main-photo thumbnail in the
 *  card list, one distinct screen per state (a second shot never overwrites another). Invented data only; the photos are
 *  small drawn images answered as real bytes. States that need a user action (stage files, press Upload, type a caption,
 *  press Delete, pick another card) are driven by `Drive` through the real inputs, as a shot cannot click. Own file,
 *  one registry line. */
import { useEffect, useRef, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import AssetCardsPage from '@/modules/assets/AssetCardsPage'
import { listOf, type PhotoSpec } from './assetCardPhotosData'
import type { EntityRecord, UserSession } from '@/types/api'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id,
  entity_type: type,
  field_values: { active: true, ...fields },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
})
const card = (id: string, no: string, name: string, extra: Record<string, unknown> = {}) =>
  rec(id, 'assets_card', { inventory_number: no, name, kind: 'fixed', org_unit_id: 'u-wh', ...extra })

const CARDS: EntityRecord[] = [
  card('c-1', 'FA-0001', 'Delivery van Gazelle Next'),
  card('c-2', 'FA-0002', 'Reach truck with a long model name for the wrapping check'),
  card('c-3', 'FA-0003', 'Office laser printer'),
  card('c-4', 'FA-0004', 'Monitor 27 inch'),
  card('c-8', 'FA-0009', 'Forklift (sold)', { active: false }),
]
const UNITS = [rec('u-wh', 'org_unit', { code: 'WH', name: 'Warehouse team' })]

type Clause = { field: string; op: string; value?: unknown }

const baseRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (_s, _p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
      const filters = b.filters ?? []
      const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
      const one = filters.find((f) => f.field === 'record_id' && f.op === 'eq')?.value
      const all = b.entity_type === 'assets_card' ? CARDS : b.entity_type === 'org_unit' ? UNITS : []
      const items = all.filter((r) => (!onlyActive || r.field_values['active'] === true) && (one === undefined || r.record_id === one))
      return { status: 200, body: { items, next_cursor: null } }
    },
  },
  { match: (path, method) => /\/modules\/assets\/cards\/[^/]+\/lock$/.test(path) && method === 'GET', reply: () => ({ status: 200, body: { posted: false, held: true } }) },
  { match: (path, method) => path === '/api/v1/modules/assets/balances' && method === 'GET', reply: () => ({ status: 200, body: { next_cursor: null, rows: [] } }) },
]

const cardOf = (path: string) => decodeURIComponent(path.split('/')[6] ?? '')
const PHOTOS = /^\/api\/v1\/modules\/assets\/cards\/[^/]+\/photos$/

interface Variant {
  /** photos by card id; a card not listed has none */
  photos?: Record<string, PhotoSpec[]>
  canAdd?: boolean
  canDelete?: boolean
  max?: number
  /** the list never answers (loading) or answers 500 */
  listPending?: boolean
  listError?: boolean
  /** upload answer: never, a refusal, or ok */
  post?: 'pending' | 'refuse'
}

const FOUR: PhotoSpec[] = [
  { id: 'p1', caption: 'Front, with the plate number', color: 'steelblue' },
  { id: 'p2', caption: null, color: 'darkseagreen' },
  { id: 'p3', caption: 'Damaged door', color: 'goldenrod' },
  { id: 'p4', caption: null, color: 'indianred' },
]

function routes(v: Variant): FixtureRoute[] {
  const photosOf = (card: string) => v.photos?.[card] ?? []
  return [
    ...baseRoutes,
    {
      match: (path, method) => PHOTOS.test(path) && method === 'GET',
      pending: v.listPending === true,
      reply: (_s, path) =>
        v.listError === true
          ? { status: 500, body: { type: 'about:blank', title: 'Fixture error', status: 500 } }
          : { status: 200, body: listOf(photosOf(cardOf(path)), { canAdd: v.canAdd ?? true, canDelete: v.canDelete ?? true, max: v.max ?? 10 }) },
    },
    {
      match: (path, method) => PHOTOS.test(path) && method === 'POST',
      pending: v.post === 'pending',
      reply: () =>
        v.post === 'refuse'
          ? { status: 503, body: { type: 'about:blank', title: 'Unavailable', status: 503, reason: 'scan_unavailable' } }
          : { status: 201, body: {} },
    },
    {
      match: (path, method) => /\/photos\/[^/]+\/(original|thumbnail)$/.test(path) && method === 'GET',
      reply: (_s, path) => {
        const parts = path.split('/')
        const spec = photosOf(cardOf(path)).find((p) => p.id === parts[8])
        return { status: 200, body: svgBlob(spec?.color ?? 'gray', parts[9] === 'original') }
      },
    },
  ]
}

function svgBlob(color: string, large: boolean): Blob {
  const size = large ? 640 : 160
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100"><rect width="100" height="100" fill="${color}"/><circle cx="50" cy="42" r="22" fill="white" fill-opacity="0.55"/><rect x="18" y="72" width="64" height="12" rx="4" fill="white" fill-opacity="0.45"/></svg>`
  return new Blob([svg], { type: 'image/svg+xml' })
}

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, permissions: ['AssetsRead', 'AssetsPost', 'AssetsCardWrite', 'PhotosAdd', 'PhotosDelete'] },
}
const withAuth = (page: ReactElement): ReactElement => (
  <AuthContext.Provider value={AUTH}>
    <AccessStateProvider state={ACCESS}>
      <div className="lf-main">
        <main className="lf-content lf-content--fluid">{page}</main>
      </div>
    </AccessStateProvider>
  </AuthContext.Provider>
)

const wait = (ms: number) => new Promise((r) => window.setTimeout(r, ms))
async function until<T>(find: () => T | null | undefined | false, tries = 200): Promise<T | null> {
  for (let i = 0; i < tries; i++) {
    const hit = find()
    if (hit) return hit
    await wait(30)
  }
  return null
}
const byId = <E extends HTMLElement = HTMLElement>(id: string) => document.querySelector<E>(`[data-testid="${id}"]`)

/** A real PNG made in the browser, so the gallery's own canvas preparation has something to decode. */
function drawnFile(name: string, color: string): Promise<File> {
  const canvas = document.createElement('canvas')
  canvas.width = 320
  canvas.height = 240
  const ctx = canvas.getContext('2d')
  if (ctx) {
    ctx.fillStyle = color
    ctx.fillRect(0, 0, 320, 240)
  }
  return new Promise((resolve) => canvas.toBlob((b) => resolve(new File([b ?? new Blob()], name, { type: 'image/png' })), 'image/png'))
}

async function stage(names: [string, string][]) {
  const input = await until(() => byId<HTMLInputElement>('photo-file-input'))
  if (!input) return
  const files: File[] = []
  for (const [name, color] of names) files.push(name.endsWith('.gif') ? new File(['GIF89a'], name, { type: 'image/gif' }) : await drawnFile(name, color))
  const dt = new DataTransfer()
  files.forEach((f) => dt.items.add(f))
  input.files = dt.files
  input.dispatchEvent(new Event('change', { bubbles: true }))
  await until(() => document.querySelectorAll('[data-testid="photo-staged"]').length === names.length)
  await wait(300)
}

type Script = () => Promise<void>

/** Harness only: runs `script` once per mount (also under StrictMode), holding the ready signal until it has finished. */
function Drive({ script, children }: { script: Script; children: ReactElement }): ReactElement {
  // StrictMode runs every effect twice on mount; a ref survives that, so the script (which stages files) runs once.
  const running = useRef<Promise<void> | null>(null)
  useEffect(() => {
    const release = holdHarnessReady()
    running.current ??= script()
    void running.current.finally(() => window.setTimeout(release, 250))
    return release
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
  return children
}

const setCaption = (text: string): Script => async () => {
  const box = await until(() => document.querySelector<HTMLTextAreaElement>('textarea[name="photo_caption"]'))
  if (!box) return
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(box, text)
  box.dispatchEvent(new Event('input', { bubbles: true }))
  await wait(100)
  byId('photo-caption-save')?.click()
  await wait(200)
}

const photosScreen = (name: string, card: string | undefined, v: Variant, script?: Script, tab = 'photos'): HarnessScreen => ({
  name,
  routes: routes(v),
  render: () => {
    const page = <AssetCardsPage initialSelectedId={card} initialCardTab={tab} />
    return withAuth(script ? <Drive script={script}>{page}</Drive> : page)
  },
})

const WITH_PHOTOS: Record<string, PhotoSpec[]> = { 'c-1': FOUR, 'c-3': [{ id: 'q1', caption: null, color: 'cadetblue', noThumbnail: true }], 'c-4': FOUR.slice(0, 1) }
const longCaption = 'x'.repeat(201)

export const assetCardPhotosScreens: HarnessScreen[] = [
  photosScreen('asset-card-photos-list-only', undefined, { photos: WITH_PHOTOS }, undefined, 'main'),
  photosScreen('asset-card-photos-list', 'c-1', { photos: WITH_PHOTOS }, undefined, 'main'),
  photosScreen('asset-card-photos-empty', 'c-2', { photos: WITH_PHOTOS }),
  photosScreen('asset-card-photos-view', 'c-1', { photos: WITH_PHOTOS }),
  photosScreen('asset-card-photos-upload', 'c-2', { photos: WITH_PHOTOS, post: 'pending' }, async () => {
    await stage([['front.png', 'steelblue'], ['side.png', 'darkseagreen'], ['scan.gif', 'gray']])
    byId('photo-upload')?.click()
    await wait(300)
  }),
  photosScreen('asset-card-photos-upload-failed', 'c-2', { photos: WITH_PHOTOS, post: 'refuse' }, async () => {
    await stage([['front.png', 'steelblue'], ['side.png', 'darkseagreen']])
    byId('photo-upload')?.click()
    await until(() => byId('photo-retry'))
  }),
  photosScreen('asset-card-photos-caption-validation', 'c-1', { photos: WITH_PHOTOS }, setCaption(longCaption)),
  photosScreen('asset-card-photos-delete', 'c-1', { photos: WITH_PHOTOS }, async () => {
    const del = await until(() => byId('photo-delete'))
    del?.click()
    await until(() => byId('confirm-dialog'))
  }),
  photosScreen('asset-card-photos-readonly', 'c-1', { photos: WITH_PHOTOS, canAdd: false, canDelete: false }),
  photosScreen('asset-card-photos-max', 'c-1', { photos: WITH_PHOTOS, max: 4 }),
  photosScreen('asset-card-photos-loading', 'c-1', { photos: WITH_PHOTOS, listPending: true }),
  photosScreen('asset-card-photos-error', 'c-1', { photos: WITH_PHOTOS, listError: true }),
  photosScreen('asset-card-photos-pending-leave', 'c-2', { photos: WITH_PHOTOS }, async () => {
    await stage([['front.png', 'steelblue']])
    const row = await until(() => Array.from(document.querySelectorAll<HTMLElement>('tr')).find((r) => r.textContent?.includes('FA-0003')))
    row?.click()
    await until(() => byId('confirm-dialog'))
  }),
]
