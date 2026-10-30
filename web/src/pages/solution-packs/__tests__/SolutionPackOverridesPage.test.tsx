// @vitest-environment jsdom
/**
 * REQ-631 part A — SolutionPackOverridesPage (list, create, edit, retire).
 *
 *   L1 loading  L2 empty  L3 error + retry  L4 404  L5 one row per override_id
 *   C1 create body  C2 blank reason / bad JSON send nothing
 *   E1 edit sends the whole patch + reason + base_version  E2 422 field messages, list unchanged
 *   E3 404/422 version_taken/403/network  R1 retire  R2 orphaned / retired rows  R3 no PATCH/PUT/DELETE
 *   G2 DefinitionsRead only: no controls  G3 tenant admin: all controls
 *   K1 launcher link  K2 query key shape  I2 kk and ru render
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import type { AccessState } from '@/auth/access'
import type { PackOverride } from '@/api/solutionPacks'
import { SolutionPackOverridesPage } from '../SolutionPackOverridesPage'
import SolutionPackUpdateLauncherPage from '../SolutionPackUpdateLauncherPage'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: null,
      tenant_slug: 'fixture-co',
      tenant_display_name: 'Fixture Co',
      tenant_id: 'tid-fixture-co',
      tenant_type: 'production',
    },
    logout: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  }),
}))

vi.mock('@/api/solutionPacks', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/solutionPacks')>()
  return {
    ...actual,
    solutionPacksApi: {
      ...actual.solutionPacksApi,
      listOverrides: vi.fn(),
      createOverride: vi.fn(),
      newOverrideVersion: vi.fn(),
      retireOverride: vi.fn(),
    },
  }
})

import { solutionPacksApi } from '@/api/solutionPacks'

const api = vi.mocked(solutionPacksApi)

function row(over: Partial<PackOverride> = {}): PackOverride {
  return {
    override_id: 'o1',
    override_version: 1,
    pack_id: 'pack-a',
    artefact_type: 'process_definition',
    artefact_id: 'def-1',
    made_against: '1.0.0',
    status: 'active',
    reason: 'first reason',
    created_by: 'u1',
    inserted_at: '2026-10-30T10:00:00Z',
    patch: { name: 'Mine', nested: { a: 1 } },
    ...over,
  }
}

const MANAGE = accessState('tenantAdmin')
const READ_ONLY = accessState('auditor')

function renderPage(access: AccessState = MANAGE) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={['/solution-packs/pack-a/overrides']}>
          <Routes>
            <Route path="/solution-packs/:packId/overrides" element={<SolutionPackOverridesPage />} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const apiError = (status: number, detail?: string) =>
  Object.assign(new Error('x'), { status, details: detail ? { detail } : {} })

const T = entitiesMessages.en
const alerts = () => screen.queryAllByRole('alert').map((a) => a.textContent ?? '')

async function openEdit() {
  fireEvent.click(await screen.findByTestId('override-edit-o1'))
  return screen.findByTestId('override-form')
}

function setReason(value: string) {
  fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.reason']), { target: { value } })
}

beforeEach(() => {
  api.listOverrides.mockResolvedValue({ overrides: [row()] })
  api.createOverride.mockResolvedValue(row())
  api.newOverrideVersion.mockResolvedValue(row({ override_version: 2 }))
  api.retireOverride.mockResolvedValue(row({ status: 'retired' }))
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('REQ-631 overrides list', () => {
  it('L1 shows loading, then the list', async () => {
    renderPage()
    expect(screen.queryByTestId('overrides-table')).not.toBeInTheDocument()
    expect(await screen.findByTestId('overrides-table')).toBeInTheDocument()
    expect(api.listOverrides).toHaveBeenCalledWith('pack-a')
  })

  it('L2 empty list message', async () => {
    api.listOverrides.mockResolvedValue({ overrides: [] })
    renderPage()
    expect(await screen.findByTestId('overrides-empty')).toHaveTextContent(T['solutionOverrides.list.empty'])
  })

  it('L3 error shows a retry that refetches', async () => {
    api.listOverrides.mockRejectedValueOnce(apiError(500))
    renderPage()
    const retry = await screen.findByRole('button', { name: /retry|try again/i })
    fireEvent.click(retry)
    expect(await screen.findByTestId('overrides-table')).toBeInTheDocument()
    expect(api.listOverrides).toHaveBeenCalledTimes(2)
  })

  it('L4 a 404 shows the single not-found text', async () => {
    api.listOverrides.mockRejectedValue(apiError(404))
    renderPage()
    expect(await screen.findByTestId('overrides-not-found')).toHaveTextContent(T['solutionOverrides.notFound'])
  })

  it('L5 one row per override_id, latest version, with the fields and no patch value', async () => {
    api.listOverrides.mockResolvedValue({
      overrides: [
        row({ override_version: 1, reason: 'old' }),
        row({ override_version: 3, reason: 'newest', made_against: '2.0.0' }),
        row({ override_id: 'o2', artefact_type: 'variable_schema', artefact_id: 'vs-1', status: 'orphaned' }),
      ],
    })
    renderPage()
    const r1 = await screen.findByTestId('override-row-o1')
    expect(screen.getAllByTestId(/^override-row-/)).toHaveLength(2)
    expect(r1).toHaveTextContent('process_definition')
    expect(r1).toHaveTextContent('def-1')
    expect(r1).toHaveTextContent('3')
    expect(r1).toHaveTextContent('2.0.0')
    expect(r1).toHaveTextContent(T['solutionOverrides.status.active'])
    expect(r1).toHaveTextContent('newest')
    expect(r1).not.toHaveTextContent('old')
    expect(r1).not.toHaveTextContent('Mine')
    expect(screen.getByTestId('override-row-o2')).toHaveTextContent(T['solutionOverrides.status.orphaned'])
  })
})

describe('REQ-631 create and edit', () => {
  it('C1 create sends the body and refetches', async () => {
    renderPage()
    fireEvent.click(await screen.findByTestId('override-new'))
    fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.type']), { target: { value: 'variable_schema' } })
    fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.id']), { target: { value: ' vs-9 ' } })
    fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.patch']), { target: { value: '{"x": 1}' } })
    setReason('because')
    fireEvent.click(screen.getByTestId('override-save'))
    await waitFor(() => expect(api.createOverride).toHaveBeenCalledTimes(1))
    expect(api.createOverride).toHaveBeenCalledWith('pack-a', {
      artefact_type: 'variable_schema',
      artefact_id: 'vs-9',
      patch: { x: 1 },
      reason: 'because',
    })
    await waitFor(() => expect(api.listOverrides).toHaveBeenCalledTimes(2))
    expect(screen.queryByTestId('override-form')).not.toBeInTheDocument()
  })

  it('C2 blank reason, bad JSON and empty id send nothing', async () => {
    renderPage()
    fireEvent.click(await screen.findByTestId('override-new'))
    fireEvent.click(screen.getByTestId('override-save'))
    expect(await screen.findByTestId('override-error-reason')).toHaveTextContent(T['solutionOverrides.error.reasonRequired'])
    expect(screen.getByTestId('override-error-id')).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.patch']), { target: { value: '[1]' } })
    fireEvent.click(screen.getByTestId('override-save'))
    expect(await screen.findByTestId('override-error-patch')).toHaveTextContent(T['solutionOverrides.error.patchInvalid'])
    expect(api.createOverride).not.toHaveBeenCalled()
  })

  it('C2 edit with a blank reason sends nothing', async () => {
    renderPage()
    await openEdit()
    fireEvent.click(screen.getByTestId('override-save'))
    expect(await screen.findByTestId('override-error-reason')).toBeInTheDocument()
    expect(api.newOverrideVersion).not.toHaveBeenCalled()
  })

  it('E1 edit opens with the latest patch and sends the whole patch, reason and base_version', async () => {
    api.listOverrides.mockResolvedValue({ overrides: [row({ override_version: 4 })] })
    renderPage()
    await openEdit()
    const patch = screen.getByLabelText(T['solutionOverrides.field.patch']) as HTMLTextAreaElement
    expect(JSON.parse(patch.value)).toEqual({ name: 'Mine', nested: { a: 1 } })
    fireEvent.change(patch, { target: { value: JSON.stringify({ name: 'Changed', nested: { a: 1 } }) } })
    setReason('rename')
    fireEvent.click(screen.getByTestId('override-save'))
    await waitFor(() => expect(api.newOverrideVersion).toHaveBeenCalledTimes(1))
    expect(api.newOverrideVersion).toHaveBeenCalledWith('pack-a', 'o1', {
      patch: { name: 'Changed', nested: { a: 1 } },
      reason: 'rename',
      base_version: 4,
    })
    await waitFor(() => expect(api.listOverrides).toHaveBeenCalledTimes(2))
  })

  it.each([
    ['property_not_overridable', 'override-error-patch'],
    ['override_exists', 'override-error-id'],
    ['reason_required', 'override-error-reason'],
  ])('E2 422 %s shows its own message, keeps the input and leaves the list', async (detail, testId) => {
    api.createOverride.mockRejectedValue(apiError(422, detail))
    renderPage()
    fireEvent.click(await screen.findByTestId('override-new'))
    fireEvent.change(screen.getByLabelText(T['solutionOverrides.field.id']), { target: { value: 'vs-9' } })
    setReason('because')
    fireEvent.click(screen.getByTestId('override-save'))
    expect(await screen.findByTestId(testId)).toHaveTextContent(T[`solutionOverrides.error.${detail}`])
    expect(api.listOverrides).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('override-row-o1')).toBeInTheDocument()
    expect((screen.getByLabelText(T['solutionOverrides.field.id']) as HTMLInputElement).value).toBe('vs-9')
  })

  it.each([
    [404, undefined, 'solutionOverrides.notFound'],
    [422, 'override_version_taken', 'solutionOverrides.error.override_version_taken'],
    [403, undefined, 'solutionOverrides.error.forbidden'],
    [undefined, undefined, 'solutionOverrides.error.network'],
  ])('E3 version failure %s %s shows its own message', async (status, detail, id) => {
    api.newOverrideVersion.mockRejectedValue(status ? apiError(status, detail) : new Error('offline'))
    renderPage()
    await openEdit()
    setReason('why')
    fireEvent.click(screen.getByTestId('override-save'))
    expect(await screen.findByTestId('override-error-general')).toHaveTextContent(T[id])
    expect(api.listOverrides).toHaveBeenCalledTimes(1)
  })
})

describe('REQ-631 retire', () => {
  it('R1 retire needs a reason, posts it, and the row becomes read-only', async () => {
    renderPage()
    fireEvent.click(await screen.findByTestId('override-retire-o1'))
    const confirm = screen.getByTestId('override-retire-confirm')
    expect(confirm).toBeDisabled()
    setReason('obsolete')
    expect(confirm).not.toBeDisabled()
    api.listOverrides.mockResolvedValue({ overrides: [row({ status: 'retired', override_version: 2 })] })
    fireEvent.click(confirm)
    await waitFor(() => expect(api.retireOverride).toHaveBeenCalledTimes(1))
    expect(api.retireOverride).toHaveBeenCalledWith('pack-a', 'o1', { reason: 'obsolete', base_version: 1 })
    await waitFor(() =>
      expect(screen.getByTestId('override-row-o1')).toHaveTextContent(T['solutionOverrides.status.retired']),
    )
    expect(screen.queryByTestId('override-edit-o1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('override-retire-o1')).not.toBeInTheDocument()
  })

  it('R1 a failed retire keeps the panel and shows the message', async () => {
    api.retireOverride.mockRejectedValue(apiError(404))
    renderPage()
    fireEvent.click(await screen.findByTestId('override-retire-o1'))
    setReason('obsolete')
    fireEvent.click(screen.getByTestId('override-retire-confirm'))
    expect(await screen.findByTestId('override-retire-error')).toHaveTextContent(T['solutionOverrides.notFound'])
    expect(api.listOverrides).toHaveBeenCalledTimes(1)
  })

  it('R2 orphaned offers retire only; retired offers nothing', async () => {
    api.listOverrides.mockResolvedValue({
      overrides: [
        row({ override_id: 'o2', status: 'orphaned' }),
        row({ override_id: 'o3', status: 'retired' }),
      ],
    })
    renderPage()
    await screen.findByTestId('override-row-o2')
    expect(screen.getByTestId('override-retire-o2')).toBeInTheDocument()
    expect(screen.queryByTestId('override-edit-o2')).not.toBeInTheDocument()
    expect(screen.queryByTestId('override-edit-o3')).not.toBeInTheDocument()
    expect(screen.queryByTestId('override-retire-o3')).not.toBeInTheDocument()
  })

  it('R3 neither the page nor the client uses PATCH, PUT or DELETE', () => {
    for (const rel of ['../SolutionPackOverridesPage.tsx', '../../../api/solutionPacks.ts']) {
      const src = readFileSync(path.join(__dirname, rel), 'utf-8')
      expect(src).not.toMatch(/\b(PATCH|PUT|DELETE)\b/)
      expect(src).not.toMatch(/\.(put|patch|delete)\(/)
    }
  })
})

describe('REQ-631 permission gating', () => {
  it('G2 DefinitionsRead only: the list shows and no write control is in the DOM', async () => {
    renderPage(READ_ONLY)
    await screen.findByTestId('override-row-o1')
    expect(screen.queryByTestId('override-new')).not.toBeInTheDocument()
    expect(screen.queryByTestId('override-edit-o1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('override-retire-o1')).not.toBeInTheDocument()
  })

  it('G3 tenant admin sees create, edit and retire', async () => {
    renderPage(MANAGE)
    await screen.findByTestId('override-row-o1')
    expect(screen.getByTestId('override-new')).toBeInTheDocument()
    expect(screen.getByTestId('override-edit-o1')).toBeInTheDocument()
    expect(screen.getByTestId('override-retire-o1')).toBeInTheDocument()
  })
})

describe('REQ-631 launcher link, key and locales', () => {
  it('K1 the launcher links to the overrides screen once a pack id is typed', async () => {
    const queryClient = new QueryClient()
    render(
      <QueryClientProvider client={queryClient}>
        <AccessStateProvider state={accessState('tenantAdmin')}>
          <MemoryRouter>
            <SolutionPackUpdateLauncherPage />
          </MemoryRouter>
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    expect(screen.queryByTestId('solution-pack-overrides-link')).not.toBeInTheDocument()
    fireEvent.change(screen.getByTestId('solution-pack-id-input'), { target: { value: ' a/b ' } })
    const link = screen.getByTestId('solution-pack-overrides-link')
    expect(link).toHaveAttribute('href', '/solution-packs/a%2Fb/overrides')
    expect(link).toHaveTextContent(T['solutionOverrides.link'])
  })

  it('K2 the page keys its query through the tenant-scoped builder, no inline queryKey', async () => {
    const { queryKeys } = await import('@/api/queryKeys')
    expect(queryKeys.solutionPackOverrides.list('t1', 'p1')).toEqual(['tenant', 't1', 'solutionPackOverrides', 'p1'])
    const src = readFileSync(path.join(__dirname, '..', 'SolutionPackOverridesPage.tsx'), 'utf-8')
    expect(src).not.toMatch(/queryKey\s*:\s*\[/)
    expect(src).toContain('QueryStateBoundary')
  })

  it.each([
    ['ru', 'solutionOverrides.status.active'],
    ['kk', 'solutionOverrides.status.active'],
  ])('I2 renders in %s', async (locale, id) => {
    const spy = vi.spyOn(window.navigator, 'languages', 'get').mockReturnValue([locale])
    renderPage()
    const r1 = await screen.findByTestId('override-row-o1')
    expect(r1).toHaveTextContent(entitiesMessages[locale as 'ru' | 'kk'][id])
    expect(alerts()).toEqual([])
    spy.mockRestore()
  })
})
