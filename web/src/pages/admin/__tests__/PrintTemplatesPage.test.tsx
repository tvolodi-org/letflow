// @vitest-environment jsdom
/**
 * REQ-614 page tests: P1 (list, open, save, refetch), E4/E5 (transitions), V5 (only the
 * print-overrides routes are called), S1-S4 (server errors shown safely).
 * Only window.fetch is stubbed (a URL router); the real client and react-query run.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
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
        display_name: 'Admin',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

import PrintTemplatesPage from '@/pages/admin/PrintTemplatesPage'
import { renderWithAccess } from '@/auth/access/testing'

const BASE = '/api/v1/documents/print-overrides'

function meta(id: string, status: string) {
  return {
    id,
    type_key: 'invoice',
    locale: 'ru',
    version_no: 1,
    status,
    layout_hash: 'hash-' + id,
    layout_schema_version: 1,
    created_by: 'u1',
    activated_by: null,
    activated_at: null,
    retired_at: null,
    reason_code: null,
    inserted_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-01T00:00:00Z',
  }
}

const LAYOUT = { layout_schema_version: 1, blocks: [{ type: 'text', text: 'SECRET-LAYOUT-TEXT' }] }
const ROWS = [meta('o-draft', 'draft'), meta('o-active', 'active'), meta('o-retired', 'retired')]

interface Call {
  method: string
  url: string
  body: unknown
}
let calls: Call[]
let override: ((c: Call) => Response | undefined) | null

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

beforeEach(() => {
  calls = []
  override = null
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const call: Call = {
        method: init?.method ?? 'GET',
        url,
        body: typeof init?.body === 'string' ? JSON.parse(init.body) : undefined,
      }
      calls.push(call)
      const o = override?.(call)
      if (o) return o
      const path = url.split('?')[0]
      if (call.method === 'GET' && path === BASE) return json(200, { overrides: ROWS })
      const m = path.match(/print-overrides\/([^/]+)$/)
      if (call.method === 'GET' && m) {
        const row = ROWS.find((r) => r.id === m[1])
        return row ? json(200, { ...row, layout: LAYOUT }) : json(404, { title: 'not found', status: 404 })
      }
      if (call.method === 'POST' && path === BASE) return json(201, { ...meta('o-new', 'draft'), layout: LAYOUT })
      if (call.method === 'POST') return json(200, { ...ROWS[0], layout: LAYOUT })
      return json(500, {})
    }),
  )
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return renderWithAccess(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <PrintTemplatesPage />
      </MemoryRouter>
    </QueryClientProvider>,
    'tenantAdmin',
  )
}

async function openRow(id: string) {
  fireEvent.click(await screen.findByTestId(`override-row-${id}`))
  await screen.findByTestId('override-detail')
}

const listGets = () => calls.filter((c) => c.method === 'GET' && c.url.split('?')[0] === BASE).length

describe('REQ-614 P1 list, open, save', () => {
  it('shows metadata only, opens a row, saves a new draft and refetches', async () => {
    renderPage()
    await screen.findByTestId('override-row-o-draft')
    expect(screen.getByText('hash-o-draft')).toBeInTheDocument()
    expect(document.body.textContent).not.toContain('SECRET-LAYOUT-TEXT')

    await openRow('o-draft')
    await waitFor(() => expect((screen.getByTestId('editor-layout') as HTMLTextAreaElement).value).toContain('SECRET-LAYOUT-TEXT'))
    expect(screen.getAllByTestId('preview-text')[0].textContent).toBe('SECRET-LAYOUT-TEXT')

    const before = listGets()
    fireEvent.click(screen.getByTestId('editor-save'))
    await waitFor(() => expect(listGets()).toBeGreaterThan(before))
    const writes = calls.filter((c) => c.method !== 'GET')
    expect(writes).toHaveLength(1)
    expect(writes[0].method).toBe('POST')
    expect(writes[0].url).toBe(BASE)
    expect(writes[0].body).toEqual({ type_key: 'invoice', locale: 'ru', layout: LAYOUT })
  })

  it('refetches the list after activate and after retire', async () => {
    renderPage()
    await openRow('o-draft')
    fireEvent.click(screen.getByTestId('activate-btn'))
    fireEvent.change(screen.getByTestId('reason-code'), { target: { value: 'ok_code1' } })
    let before = listGets()
    fireEvent.click(screen.getByTestId('reason-submit'))
    await waitFor(() => expect(listGets()).toBeGreaterThan(before))
    expect(calls.some((c) => c.method === 'POST' && c.url === `${BASE}/o-draft/activate`)).toBe(true)

    await openRow('o-active')
    fireEvent.click(screen.getByTestId('retire-btn'))
    fireEvent.change(screen.getByTestId('reason-code'), { target: { value: 'done_1' } })
    before = listGets()
    fireEvent.click(screen.getByTestId('reason-submit'))
    await waitFor(() => expect(listGets()).toBeGreaterThan(before))
    expect(calls.some((c) => c.method === 'POST' && c.url === `${BASE}/o-active/retire`)).toBe(true)
  })
})

describe('REQ-614 E4/E5 transitions', () => {
  it('E4 Activate only on a draft, Retire only on an active row', async () => {
    renderPage()
    await openRow('o-draft')
    expect(screen.getByTestId('activate-btn')).toBeInTheDocument()
    expect(screen.queryByTestId('retire-btn')).toBeNull()
    await openRow('o-active')
    await waitFor(() => expect(screen.getByTestId('retire-btn')).toBeInTheDocument())
    expect(screen.queryByTestId('activate-btn')).toBeNull()
    await openRow('o-retired')
    await waitFor(() => expect(screen.queryByTestId('retire-btn')).toBeNull())
    expect(screen.queryByTestId('activate-btn')).toBeNull()
  })

  it.each(['Bad', '1x', '', 'a'.repeat(65)])('E5 rejects reason_code %j without a request', async (bad) => {
    renderPage()
    await openRow('o-draft')
    fireEvent.click(screen.getByTestId('activate-btn'))
    fireEvent.change(screen.getByTestId('reason-code'), { target: { value: bad } })
    fireEvent.click(screen.getByTestId('reason-submit'))
    expect(screen.getByTestId('reason-error').textContent).toMatch(/reason_code must start/)
    expect(calls.filter((c) => c.method !== 'GET')).toHaveLength(0)
  })
})

describe('REQ-614 V5 only print-overrides routes', () => {
  it('every fetched URL is a print-overrides route', async () => {
    renderPage()
    await openRow('o-draft')
    await waitFor(() => expect(screen.getByTestId('editor-layout')).toBeInTheDocument())
    expect(calls.length).toBeGreaterThan(0)
    for (const c of calls) expect(c.url).toMatch(/\/api\/v1\/documents\/print-overrides/)
  })
})

describe('REQ-614 S1-S4 server errors', () => {
  async function saveWith(res: Response) {
    renderPage()
    await openRow('o-draft')
    await waitFor(() => expect((screen.getByTestId('editor-layout') as HTMLTextAreaElement).value).toContain('SECRET'))
    override = (c) => (c.method === 'POST' ? res : undefined)
    fireEvent.click(screen.getByTestId('editor-save'))
    return await screen.findByTestId('editor-server-errors')
  }

  it('S1 422 shows rule and path only', async () => {
    const box = await saveWith(
      json(422, {
        title: 'Unprocessable',
        status: 422,
        detail: 'layout failed validation',
        errors: [{ rule: 'field_not_projected', path: ['blocks', 1, 'field_name'] }],
      }),
    )
    expect(box.textContent).toBe('field_not_projected at blocks[1].field_name')
    expect(box.textContent).not.toContain('layout failed validation')
    expect(box.textContent).not.toContain('SECRET-LAYOUT-TEXT')
  })

  it('S2 409 shows the server detail', async () => {
    const box = await saveWith(json(409, { title: 'Conflict', status: 409, detail: 'activation needs a second administrator' }))
    expect(box.textContent).toBe('activation needs a second administrator')
  })

  it('S3 404 shows a generic not found', async () => {
    const box = await saveWith(json(404, { title: 'not found', status: 404, detail: 'internal-detail' }))
    expect(box.textContent).toBe('Not found')
  })

  it('S4 500 shows a generic error and not the body', async () => {
    const box = await saveWith(json(500, { title: 'boom', detail: 'SECRET-MARKER', status: 500 }))
    expect(box.textContent).toBe('Something went wrong. Try again.')
    expect(document.body.textContent).not.toContain('SECRET-MARKER')
  })
})
