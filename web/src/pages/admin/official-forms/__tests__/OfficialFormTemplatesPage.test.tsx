// @vitest-environment jsdom
/**
 * T-1983 page tests. IDs: W1 list and state pills, W2 starter download, W3 upload (FormData, accepted), W4 refusal list,
 * W5 preview, W6 activate with reason, W7 rollback, W8 version history, W9 retire / discard, W10 ru and kk,
 * W11 load states. Fake window.fetch; real react-query and the real page.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'admin-id' })) + '.sig',
        display_name: 'Admin', loginSource: 'oidc' as const, tenant_slug: null, tenant_display_name: null,
        tenant_id: 'tenant-1', tenant_type: null,
      },
      isAuthenticated: true, isLoading: false, loginSource: 'oidc' as const,
      login: vi.fn(), logout: vi.fn(), setSession: vi.fn(),
    }),
  }
})

const saveBlob = vi.fn()
vi.mock('@/lib/saveBlob', () => ({ saveBlob: (...a: unknown[]) => saveBlob(...a) }))

import OfficialFormTemplatesPage from '../OfficialFormTemplatesPage'
import { renderWithAccess } from '@/auth/access/testing'
import type { OfficialFormTemplateMeta } from '@/api/officialFormTemplates'
import { dismissToast, getToastSnapshot } from '@/hooks/useToast'
import { officialFormsMessages } from '../officialFormsMessages'

const ID = (n: number) => `00000000-0000-4000-8000-0000000000${String(n).padStart(2, '0')}`
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

function tpl(n: number, over: Partial<OfficialFormTemplateMeta>): OfficialFormTemplateMeta {
  return {
    id: ID(n), form: 'z1', locale: 'ru', version_no: n, status: 'retired', byte_size: 100, sha256: 'a'.repeat(64),
    rollback_of: null, created_by: null, activated_by: null, activated_at: null, retired_at: null, reason_code: null,
    inserted_at: '2026-11-01T09:00:00Z', updated_at: '2026-11-01T09:00:00Z', ...over,
  }
}
const V4 = tpl(4, { status: 'draft' })
const V3 = tpl(3, { status: 'active', activated_at: '2026-11-10T09:00:00Z', reason_code: 'layout_change' })
const V2 = tpl(2, { activated_at: '2026-11-05T09:00:00Z', retired_at: '2026-11-10T09:00:00Z', reason_code: 'superseded' })
const V1 = tpl(1, { activated_at: '2026-11-02T09:00:00Z', retired_at: '2026-11-05T09:00:00Z', reason_code: 'go_live' })
const NEVER = tpl(5, { locale: 'kk', status: 'retired', reason_code: 'draft_not_needed' })
const COPY = tpl(6, { locale: 'default', status: 'draft', rollback_of: ID(1) })
const KK_ACTIVE = tpl(7, { form: 'da3', locale: 'kk', status: 'active', activated_at: '2026-11-03T09:00:00Z', version_no: 2 })

interface Call { method: string; url: string; body: unknown; form?: FormData }
let calls: Call[]
let rows: OfficialFormTemplateMeta[]
let postReply: (() => Response) | null
let getReply: (() => Response) | null
let widthSpy: ReturnType<typeof vi.spyOn> | null = null

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}
function docx(name: string): Response {
  return new Response(new Uint8Array([80, 75]), {
    status: 200,
    headers: { 'Content-Type': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'Content-Disposition': `attachment; filename="${name}"` },
  })
}

beforeEach(() => {
  widthSpy = vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(1400)
  calls = []
  rows = [V4, V3, V2, V1, COPY]
  postReply = null
  getReply = null
  saveBlob.mockClear()
  vi.spyOn(window, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : (input as Request).url
    const method = (init?.method ?? 'GET').toUpperCase()
    const isForm = init?.body instanceof FormData
    const body = init?.body && !isForm ? (JSON.parse(init.body as string) as unknown) : undefined
    calls.push({ method, url, body, form: isForm ? (init!.body as FormData) : undefined })
    if (method === 'GET' && url.endsWith('/official-form-templates')) return getReply ? getReply() : json(200, { templates: rows })
    if (method === 'GET') {
      const name = url.includes('/starter/') ? 'z1-starter.docx' : url.includes('/preview') ? 'z1-ru-v3-preview-ru.docx' : 'z1-ru-v3.docx'
      return docx(name)
    }
    if (postReply) return postReply()
    return json(200, { ...V4, status: 'active' })
  })
})
afterEach(() => {
  widthSpy?.mockRestore()
  for (const e of getToastSnapshot()) dismissToast(e.id)
  cleanup()
  vi.restoreAllMocks()
})

function render(props: Parameters<typeof OfficialFormTemplatesPage>[0] = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <OfficialFormTemplatesPage {...props} />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}
const posts = () => calls.filter((c) => c.method === 'POST')
const gets = () => calls.filter((c) => c.method === 'GET')
async function ready(form = 'z1') {
  render({ initialSelectedKey: form })
  await screen.findByTestId('official-forms-current')
  await waitFor(() => expect(document.querySelector('[aria-busy="true"]')).toBeNull())
}
const tableOf = (name: RegExp) => screen.getAllByRole('table').find((t) => name.test(t.textContent ?? ''))!
const btn = (name: string | RegExp, within_?: HTMLElement) => (within_ ? within(within_) : screen).getByRole('button', { name })

describe('W1 list and state pills', () => {
  it('shows the 12 forms in order, the notice, and a pill per state', async () => {
    rows = [V3, V4, KK_ACTIVE, NEVER]
    render()
    const list = (await screen.findAllByRole('table'))[0]
    await waitFor(() => expect(within(list).getByText('Own template ru v3')).toBeInTheDocument())
    expect(within(list).getAllByRole('row')).toHaveLength(13)
    expect(within(list).getByText('Draft v4')).toBeInTheDocument()
    expect(within(list).getByText('Own template kk v2')).toBeInTheDocument()
    expect(within(list).getAllByText('Standard')).toHaveLength(10)
    expect(screen.getByTestId('official-forms-notice')).toHaveTextContent(/Word prints use the active template of your company/)
    expect(screen.getByTestId('detail-header')).toHaveTextContent('DA-1')
  })

  it('first use: every row Standard, empty versions with both buttons', async () => {
    rows = []
    render()
    await screen.findByText('No own templates yet')
    expect(screen.getByTestId('official-forms-starter')).toBeEnabled()
    expect(screen.getByTestId('official-forms-upload-toggle')).toBeEnabled()
  })
})

describe('W2 starter download', () => {
  it('fetches the starter of the form and saves it under the header name', async () => {
    await ready()
    fireEvent.click(screen.getByTestId('official-forms-starter'))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledTimes(1))
    expect(gets().some((c) => c.url.endsWith('/api/v1/documents/official-form-templates/starter/z1'))).toBe(true)
    expect(saveBlob.mock.calls[0][1]).toBe('z1-starter.docx')
  })
})

describe('W3 upload', () => {
  it('posts form, locale and file only; on 201 closes the section, toasts and keeps the form selected', async () => {
    postReply = () => json(201, tpl(8, { status: 'draft' }))
    await ready()
    fireEvent.click(screen.getByTestId('official-forms-upload-toggle'))
    const input = screen.getByTestId('dropzone-input')
    const file = new File([new Uint8Array([1, 2, 3])], 'my-z1.docx')
    fireEvent.change(input, { target: { files: [file] } })
    fireEvent.change(screen.getByLabelText('Language of the template'), { target: { value: 'kk' } })
    fireEvent.click(screen.getByTestId('official-forms-upload-submit'))
    await waitFor(() => expect(posts()).toHaveLength(1))
    const form = posts()[0].form!
    expect([...form.keys()].sort()).toEqual(['file', 'form', 'locale'])
    expect(form.get('form')).toBe('z1')
    expect(form.get('locale')).toBe('kk')
    expect((form.get('file') as File).name).toBe('my-z1.docx')
    await waitFor(() => expect(screen.queryByTestId('official-forms-upload')).toBeNull())
    expect(getToastSnapshot().some((e) => /Accepted as draft v8/.test(e.message))).toBe(true)
    expect(screen.getByTestId('detail-header')).toHaveTextContent('Z-1')
  })

  it('refuses a file that is not .docx before any request', async () => {
    await ready()
    fireEvent.click(screen.getByTestId('official-forms-upload-toggle'))
    fireEvent.change(screen.getByTestId('dropzone-input'), { target: { files: [new File(['x'], 'a.pdf')] } })
    expect(screen.getByText('Choose a .docx file of up to 1 MB.')).toBeInTheDocument()
    expect(posts()).toHaveLength(0)
  })
})

describe('W4 refusal list', () => {
  it('shows a hint, a place and a name per refusal; an unknown code gets the generic hint; no other field is read', async () => {
    postReply = () =>
      json(422, {
        status: 422, detail: 'template refused',
        refusals: [
          { code: 'missing_legal', rule: 'D3.1', place: { table: 1, row: 2, cell: 5, company_text: 'SECRET' }, name: 'annex_line', category: 'legal', free_text: 'SECRET' },
          { code: 'future_rule', rule: 'D9', place: null, name: null, category: null },
        ],
      })
    await ready()
    fireEvent.click(screen.getByTestId('official-forms-upload-toggle'))
    fireEvent.change(screen.getByTestId('dropzone-input'), { target: { files: [new File(['x'], 'my.docx')] } })
    fireEvent.click(screen.getByTestId('official-forms-upload-submit'))
    const items = await screen.findAllByTestId('official-forms-refusal')
    expect(items).toHaveLength(2)
    expect(items[0]).toHaveTextContent('A required legal text placeholder is missing.')
    expect(items[0]).toHaveTextContent('table 1, row 2, cell 5')
    expect(items[0]).toHaveTextContent('annex_line')
    expect(items[1]).toHaveTextContent('rule this screen has no text for')
    expect(items[1]).toHaveTextContent('future_rule')
    expect(screen.getByTestId('official-forms-refusals')).not.toHaveTextContent('SECRET')
    expect(screen.getByTestId('official-forms-upload')).toBeInTheDocument()
  })

  it('a 500 shows the generic upload error, not a refusal list', async () => {
    postReply = () => json(500, { status: 500 })
    await ready()
    fireEvent.click(screen.getByTestId('official-forms-upload-toggle'))
    fireEvent.change(screen.getByTestId('dropzone-input'), { target: { files: [new File(['x'], 'my.docx')] } })
    fireEvent.click(screen.getByTestId('official-forms-upload-submit'))
    expect(await screen.findByTestId('official-forms-upload-error')).toHaveTextContent('The action failed')
    expect(screen.queryByTestId('official-forms-refusals')).toBeNull()
  })
})

describe('W5 preview', () => {
  it('a ru row previews in ru; a default row offers ru and kk', async () => {
    await ready()
    const versions = tableOf(/Actions/)
    const rowsEl = within(versions).getAllByRole('row')
    const v3 = rowsEl.find((r) => /v3/.test(r.textContent ?? ''))!
    fireEvent.click(btn('Preview', v3))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledTimes(1))
    expect(gets().some((c) => c.url.includes(`/${ID(3)}/preview`) && c.url.includes('lang=ru'))).toBe(true)
    const copy = rowsEl.find((r) => /Copy of v1/.test(r.textContent ?? ''))!
    expect(within(copy).getByRole('button', { name: 'Preview ru' })).toBeInTheDocument()
    expect(within(copy).getByRole('button', { name: 'Preview kk' })).toBeInTheDocument()
    fireEvent.click(within(copy).getByRole('button', { name: 'Preview kk' }))
    await waitFor(() => expect(gets().some((c) => c.url.includes(`/${ID(6)}/preview`) && c.url.includes('lang=kk'))).toBe(true))
  })
})

describe('W6 activate with reason', () => {
  it('confirm is disabled until a reason is chosen, then posts the code and toasts', async () => {
    postReply = () => json(200, { ...V4, status: 'active' })
    await ready()
    const row = within(tableOf(/Actions/)).getAllByRole('row').find((r) => /v4/.test(r.textContent ?? ''))!
    fireEvent.click(btn('Activate', row))
    const dialog = await screen.findByTestId('official-forms-dialog')
    expect(screen.getByTestId('official-forms-effect')).toHaveTextContent('v4 becomes the template of this form for Russian; the current v3 is retired.')
    const confirm = within(dialog).getByRole('button', { name: 'Activate' })
    expect(confirm).toBeDisabled()
    fireEvent.change(within(dialog).getByLabelText('Reason'), { target: { value: 'layout_change' } })
    expect(confirm).toBeEnabled()
    fireEvent.click(confirm)
    await waitFor(() => expect(posts()).toHaveLength(1))
    expect(posts()[0].url).toContain(`/official-form-templates/${ID(4)}/activate`)
    expect(posts()[0].body).toEqual({ reason_code: 'layout_change' })
    await waitFor(() => expect(screen.queryByTestId('official-forms-dialog')).toBeNull())
    expect(getToastSnapshot().some((e) => /Activated v4/.test(e.message))).toBe(true)
  })

  it('a 422 shows the refusal list inside the dialog', async () => {
    postReply = () => json(422, { status: 422, refusals: [{ code: 'column_order', rule: 'D3.4', place: { table: 2 }, name: null, category: null }] })
    render({ initialSelectedKey: 'z1', initialDialog: { action: 'activate', id: ID(4) }, initialReason: 'correction' })
    const dialog = await screen.findByTestId('official-forms-dialog')
    await waitFor(() => expect(within(dialog).getByRole('button', { name: 'Activate' })).toBeEnabled())
    fireEvent.click(within(dialog).getByRole('button', { name: 'Activate' }))
    expect(await within(dialog).findByText(/no longer passes the check/)).toBeInTheDocument()
    expect(within(dialog).getByText(/prescribed order/)).toBeInTheDocument()
  })
})

describe('W7 rollback', () => {
  it('the button exists only on a retired row that was once active', async () => {
    rows = [V4, V3, V2, V1, NEVER]
    await ready()
    const all = within(tableOf(/Actions/)).getAllByRole('row')
    const has = (v: RegExp) => within(all.find((r) => v.test(r.textContent ?? ''))!).queryByRole('button', { name: 'Roll back to this version' })
    expect(has(/v2/)).not.toBeNull()
    expect(has(/v1/)).not.toBeNull()
    expect(has(/v3/)).toBeNull()
    expect(has(/v4/)).toBeNull()
  })

  it('posts the reason, toasts the new active version; a 409 shows the mapped text', async () => {
    postReply = () => json(201, tpl(9, { status: 'active' }))
    await ready()
    const v2 = within(tableOf(/Actions/)).getAllByRole('row').find((r) => /v2/.test(r.textContent ?? ''))!
    fireEvent.click(btn('Roll back to this version', v2))
    const dialog = await screen.findByTestId('official-forms-dialog')
    fireEvent.change(within(dialog).getByLabelText('Reason'), { target: { value: 'new_version_wrong' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Roll back' }))
    await waitFor(() => expect(posts()).toHaveLength(1))
    expect(posts()[0].url).toContain(`/${ID(2)}/rollback`)
    await waitFor(() => expect(getToastSnapshot().some((e) => /v9 is active/.test(e.message))).toBe(true))

    cleanup()
    postReply = () => json(409, { status: 409, detail: 'only a retired template that was once active can be rolled back to' })
    render({ initialSelectedKey: 'z1', initialDialog: { action: 'rollback', id: ID(2) }, initialReason: 'other' })
    const d2 = await screen.findByTestId('official-forms-dialog')
    await waitFor(() => expect(within(d2).getByRole('button', { name: 'Roll back' })).toBeEnabled())
    fireEvent.click(within(d2).getByRole('button', { name: 'Roll back' }))
    expect(await within(d2).findByText(/Only a version that was once active/)).toBeInTheDocument()
  })
})

describe('W8 version history', () => {
  it('shows this form only, status pills, translated reasons, raw unknown reason, copy-of note, no UUID', async () => {
    rows = [V4, V3, V2, V1, COPY, KK_ACTIVE]
    const { container } = render({ initialSelectedKey: 'z1' })
    await screen.findByTestId('official-forms-current')
    await waitFor(() => expect(document.querySelector('[aria-busy="true"]')).toBeNull())
    const versions = tableOf(/Actions/)
    const text = versions.textContent ?? ''
    expect(text).toContain('Draft')
    expect(text).toContain('Active')
    expect(text).toContain('Replaced by a newer version')
    expect(text).toContain('Layout changed')
    expect(text).toContain('go_live')
    expect(text).toContain('Copy of v1')
    const body = within(versions).getAllByRole('row').slice(1)
    expect(body).toHaveLength(5)
    expect(container.textContent).not.toMatch(UUID_RE)
    const first = body.map((r) => r.textContent ?? '')
    expect(first[0]).toContain('Both languages')
    expect(first[1]).toMatch(/v4/)
  })

  it('the Current section names each language', async () => {
    await ready()
    expect(screen.getByTestId('official-forms-current')).toHaveTextContent('Russian: own template v3, active since')
    expect(screen.getByTestId('official-forms-current')).toHaveTextContent('Kazakh: standard layout')
  })
})

describe('W9 retire and discard', () => {
  it('Discard on a draft and Switch back on the active one post retire with a reason', async () => {
    postReply = () => json(200, { ...V4, status: 'retired' })
    await ready()
    const all = within(tableOf(/Actions/)).getAllByRole('row')
    const v4 = all.find((r) => /v4/.test(r.textContent ?? ''))!
    const v3 = all.find((r) => /v3/.test(r.textContent ?? ''))!
    expect(within(v4).queryByRole('button', { name: 'Switch back to standard' })).toBeNull()
    fireEvent.click(btn('Discard', v4))
    let dialog = await screen.findByTestId('official-forms-dialog')
    fireEvent.change(within(dialog).getByLabelText('Reason'), { target: { value: 'draft_not_needed' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Retire' }))
    await waitFor(() => expect(posts()).toHaveLength(1))
    expect(posts()[0].url).toContain(`/${ID(4)}/retire`)
    expect(posts()[0].body).toEqual({ reason_code: 'draft_not_needed' })
    await waitFor(() => expect(screen.queryByTestId('official-forms-dialog')).toBeNull())

    fireEvent.click(btn('Switch back to standard', v3))
    dialog = await screen.findByTestId('official-forms-dialog')
    expect(screen.getByTestId('official-forms-effect')).toHaveTextContent('standard layout for Russian')
  })
})

describe('W10 ru and kk', () => {
  it.each(['ru', 'kk'] as const)('renders the %s title, form names and notice with no English catalog text', async (locale) => {
    render({ locale, initialSelectedKey: 'z1' })
    await screen.findByTestId('official-forms-current')
    await waitFor(() => expect(document.querySelector('[aria-busy="true"]')).toBeNull())
    const m = officialFormsMessages[locale]
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(m['officialForms.title'])
    expect(screen.getByTestId('official-forms-notice')).toHaveTextContent(m['officialForms.notice.printsPending'])
    expect(screen.getByTestId('detail-header')).toHaveTextContent(m['officialForms.form.z1.name'])
    expect(screen.queryByText('Download starter')).toBeNull()
    expect(screen.getByTestId('official-forms-starter')).toHaveTextContent(m['officialForms.action.downloadStarter'])
  })
})

describe('W11 load states', () => {
  it('a 500 shows the error banner and Try again refetches', async () => {
    getReply = () => json(500, { status: 500, message: 'error' })
    render()
    const retry = await screen.findByRole('button', { name: /try again|retry/i })
    const before = gets().length
    getReply = null
    fireEvent.click(retry)
    await waitFor(() => expect(gets().length).toBeGreaterThan(before))
    await waitFor(() => expect(screen.getAllByRole('table').length).toBeGreaterThan(0))
  })

  it('shows a skeleton while the list is pending', async () => {
    getReply = () => new Promise<Response>(() => undefined) as unknown as Response
    vi.mocked(window.fetch).mockImplementationOnce(() => new Promise<Response>(() => undefined))
    render()
    await waitFor(() => expect(document.querySelector('[aria-busy="true"]')).not.toBeNull())
  })
})
