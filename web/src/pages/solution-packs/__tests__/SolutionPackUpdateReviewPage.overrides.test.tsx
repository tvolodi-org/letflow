// @vitest-environment jsdom
/**
 * REQ-631 part B — SolutionPackUpdateReviewPage with the REQ-617 override object.
 *
 *   O4 apply gating by unresolved override_conflict  E1 409  E2 403  E3 422
 *   G1/G2 apply control gated on SolutionOverridesManage  G3 route guard  D1 no patch value shown
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import type { AccessState } from '@/auth/access'
import type { PackUpdateOverride, PackUpdateReviewEntry } from '@/api/solutionPacks'
import SolutionPackUpdateReviewPage from '../SolutionPackUpdateReviewPage'
expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', display_name: 'Test User', tenant_slug: 'fixture-co' } }),
}))

vi.mock('@/api/solutionPacks', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/solutionPacks')>()
  return {
    ...actual,
    solutionPacksApi: {
      ...actual.solutionPacksApi,
      updateReview: vi.fn(),
      updateApply: vi.fn(),
      listOverrides: vi.fn(),
    },
  }
})

import { solutionPacksApi } from '@/api/solutionPacks'

const api = vi.mocked(solutionPacksApi)
const T = entitiesMessages.en

const withManage: AccessState = { status: 'ready', info: ACCESS_FIXTURES.tenantAdmin }
const modulesOnly: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: ACCESS_FIXTURES.tenantAdmin.permissions.filter((p) => p !== 'SolutionOverridesManage'),
  },
}
const noModules: AccessState = {
  status: 'ready',
  info: { ...ACCESS_FIXTURES.auditor, permissions: ACCESS_FIXTURES.auditor.permissions.filter((p) => p !== 'ModulesManage') },
}

function ov(outcome: PackUpdateOverride['outcome']): PackUpdateOverride {
  return { override_id: 'o1', override_version: 1, made_against: '1.0.0', outcome }
}
function ent(id: string, classification: PackUpdateReviewEntry['classification'], over: Partial<PackUpdateReviewEntry> = {}) {
  return { artefact_type: 'process_definition', artefact_id: id, classification, resolved: false, ...over } as PackUpdateReviewEntry
}

function review(entries: PackUpdateReviewEntry[]) {
  api.updateReview.mockResolvedValue({
    pack_id: 'pack-a',
    target_version: '2.0.0',
    entries,
    has_unresolved_conflicts: false,
  })
}

const apiError = (status: number, detail?: string) =>
  Object.assign(new Error('x'), { status, details: detail ? { detail } : {} })

function renderPage(access: AccessState = withManage) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AccessStateProvider state={access}>
        <MemoryRouter
          initialEntries={[
            { pathname: '/solution-packs/pack-a/update-review', state: { targetVersion: '2.0.0', theirsArtefacts: [], incomingArtefacts: [] } },
          ]}
        >
          <Routes>
            <Route path="/solution-packs/:packId/update-review" element={<SolutionPackUpdateReviewPage />} />
            <Route path="/instances" element={<div data-testid="redirected" />} />
          </Routes>
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

const applyBtn = () => screen.findByTestId('update-apply-btn')
const clickApply = async () => fireEvent.click(await applyBtn())

beforeEach(() => {
  vi.clearAllMocks()
})
afterEach(() => {
  cleanup()
})

describe('O4 apply gating', () => {
  it('unresolved override_conflict blocks until keep_local or take_incoming', async () => {
    for (const radio of ['update-review-resolution-keep-local', 'update-review-resolution-take-incoming']) {
      review([ent('c1', 'safe_to_update', { override: ov('override_conflict') })])
      const { unmount } = renderPage()
      expect(await applyBtn()).toBeDisabled()
      expect(screen.getByTestId('update-apply-unresolved-hint')).toHaveTextContent('1 artefact still needs')
      fireEvent.click(screen.getByTestId(radio))
      await waitFor(async () => expect(await applyBtn()).toBeEnabled())
      unmount()
    }
  })

  it('orphaned and property_gone (non-conflict) do not block', async () => {
    review([ent('o', 'safe_to_update', { override: ov('orphaned') }), ent('p', 'local_only', { override: ov('property_gone') })])
    renderPage()
    expect(await applyBtn()).toBeEnabled()
    expect(screen.queryByTestId('update-apply-unresolved-hint')).toBeNull()
  })

  it('both_sides_conflict + orphaned does not block and is not counted', async () => {
    review([ent('o', 'both_sides_conflict', { override: ov('orphaned') })])
    renderPage()
    expect(await applyBtn()).toBeEnabled()
    expect(screen.queryByTestId('update-apply-unresolved-hint')).toBeNull()
    expect(screen.getAllByRole('radio')).toHaveLength(2)
  })

  it('both_sides_conflict + property_gone still blocks until resolved', async () => {
    review([ent('p', 'both_sides_conflict', { override: ov('property_gone') })])
    renderPage()
    expect(await applyBtn()).toBeDisabled()
    fireEvent.click(screen.getByTestId('update-review-resolution-keep-local'))
    await waitFor(async () => expect(await applyBtn()).toBeEnabled())
  })
})

describe('E1-E3 error replies', () => {
  async function chooseAndApply() {
    review([ent('c1', 'safe_to_update', { override: ov('override_conflict') })])
    renderPage()
    fireEvent.click(await screen.findByTestId('update-review-resolution-take-incoming'))
    await waitFor(async () => expect(await applyBtn()).toBeEnabled())
    await clickApply()
  }
  const kept = () => {
    expect(screen.getByTestId('update-review-resolution-take-incoming')).toBeChecked()
    expect(screen.queryByTestId('update-attribution-panel')).toBeNull()
    expect(screen.queryByTestId('update-override-actions')).toBeNull()
  }

  it('E1 409 unresolved conflict shows the banner and keeps choices', async () => {
    api.updateApply.mockRejectedValue(apiError(409, 'unresolved conflict on artefact_type=process_definition artefact_id=c1'))
    await chooseAndApply()
    await screen.findByTestId('update-apply-blocked-banner')
    kept()
  })

  it('E1 409 with unparseable detail shows the conflict message', async () => {
    api.updateApply.mockRejectedValue(apiError(409, 'override_version_taken'))
    await chooseAndApply()
    expect(await screen.findByTestId('update-apply-error')).toHaveTextContent(T['solutionOverrides.report.error.conflict'])
    kept()
  })

  it('E2 403 shows the forbidden message', async () => {
    api.updateApply.mockRejectedValue(apiError(403, 'insufficient permissions'))
    await chooseAndApply()
    expect(await screen.findByTestId('update-apply-error')).toHaveTextContent(T['solutionOverrides.report.error.forbidden'])
    kept()
  })

  it('E3 422 override_merge_unsupported shows its message; other 422 is generic', async () => {
    api.updateApply.mockRejectedValueOnce(apiError(422, 'override_merge_unsupported'))
    await chooseAndApply()
    expect(await screen.findByTestId('update-apply-error')).toHaveTextContent(
      T['solutionOverrides.report.error.override_merge_unsupported'],
    )
    kept()
    api.updateApply.mockRejectedValueOnce(apiError(422, 'something_else'))
    await clickApply()
    await waitFor(() =>
      expect(screen.getByTestId('update-apply-error')).toHaveTextContent(T['solutionOverrides.report.error.generic']),
    )
    kept()
  })
})

describe('G apply control gating', () => {
  const conflictReport = () => review([ent('c1', 'safe_to_update', { resolved: true, override: ov('override_conflict') })])

  it('G1 ModulesManage only + override_conflict: entries visible, no apply button', async () => {
    conflictReport()
    renderPage(modulesOnly)
    expect(await screen.findByTestId('update-review-override-outcome')).toBeInTheDocument()
    expect(screen.queryByTestId('update-apply-btn')).toBeNull()
    expect(screen.getByTestId('update-apply-restricted')).toHaveTextContent(T['solutionOverrides.report.applyNeedsManage'])
  })

  it('G2 SolutionOverridesManage holder sees the button; without an override_conflict anyone does', async () => {
    conflictReport()
    const first = renderPage(withManage)
    expect(await applyBtn()).toBeInTheDocument()
    first.unmount()
    review([ent('k', 'safe_to_update', { override: ov('kept') })])
    renderPage(modulesOnly)
    expect(await applyBtn()).toBeInTheDocument()
  })

  it('G3 a session without ModulesManage is redirected', async () => {
    conflictReport()
    renderPage(noModules)
    expect(await screen.findByTestId('redirected')).toBeInTheDocument()
  })
})

describe('D1 no override value in the output', () => {
  it('987654.321 from the overrides list never renders', async () => {
    api.listOverrides.mockResolvedValue({ overrides: [{ patch: { x: 987654.321 } }] } as never)
    review([ent('c1', 'safe_to_update', { resolved: true, override: { ...ov('kept'), patch: { x: 987654.321 } } as PackUpdateOverride })])
    api.updateApply.mockResolvedValue({
      pack_id: 'pack-a',
      target_version: '2.0.0',
      resolutions_recorded: 0,
      applied_entries: [
        { artefact_type: 'process_definition', artefact_id: 'c1', classification: 'safe_to_update', action: 'advanced_to_incoming', override_action: 'advanced' },
      ],
    })
    const { container } = renderPage()
    await clickApply()
    await screen.findByTestId('update-override-actions')
    expect(container.textContent).not.toContain('987654.321')
    expect(container.textContent).not.toContain('987654')
    expect(api.listOverrides).not.toHaveBeenCalled()
  })
})
