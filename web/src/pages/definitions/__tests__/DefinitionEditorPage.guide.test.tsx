// @vitest-environment jsdom
/**
 * T-2805: the Guide entry on the designer page opens the guide inside the product. The REAL editor page with the
 * shipped platform.register_tenant graph; the rendered text comes from docs/designer-guide.<lang>.md.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, render } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { useUiLocaleStore, type UiLocale } from '@/i18n/uiLocaleStore'
import { useGuideStore } from '@/stores/guideStore'
expect.extend(jestDomMatchers)

globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as unknown as typeof ResizeObserver

vi.mock('@/components/canvas/NodePalette', () => ({ default: () => <div /> }))
vi.mock('@/components/canvas/PropertyPanel', () => ({ default: () => <div /> }))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return { ...actual, useParams: vi.fn(), useBlocker: vi.fn(() => ({ state: 'unblocked' as const })) }
})
vi.mock('@/hooks/useDefinitions', () => ({
  useDefinition: vi.fn(),
  useCreateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useValidateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
  useActivateDefinition: vi.fn(() => ({ mutateAsync: vi.fn(), isPending: false })),
}))
vi.mock('@/auth/AuthContext', () => ({ useAuth: vi.fn() }))
vi.mock('@/auth/useTenantContext', () => ({ useTenantContext: vi.fn() }))
vi.mock('@/api/platformFunctions', () => ({ platformFunctionsApi: { list: vi.fn().mockResolvedValue({ items: [] }) } }))
vi.mock('@/api/notificationTemplates', () => ({ notificationTemplatesApi: { catalogue: vi.fn().mockResolvedValue([]), list: vi.fn().mockResolvedValue([]) } }))

import { useParams } from 'react-router-dom'
import { useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { useTenantContext } from '@/auth/useTenantContext'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import { DEF as FIXTURE_DEF } from '@/dev/harness/fixtures/registerTenantDesigner'

const SEED_GRAPH = JSON.parse(readFileSync(resolve(process.cwd(), '../test/fixtures/platform_processes/register_tenant_graph.json'), 'utf8'))
const DEF = { ...FIXTURE_DEF, graph: SEED_GRAPH } as unknown as typeof FIXTURE_DEF

const FILES: Record<UiLocale, string> = { en: 'designer-guide.md', ru: 'designer-guide.ru.md', kk: 'designer-guide.kk.md' }
const LABELS: Record<UiLocale, string> = { en: 'Guide', ru: 'Руководство', kk: 'Нұсқаулық' }

function firstHeading(lang: UiLocale): string {
  const md = readFileSync(resolve(process.cwd(), '../docs', FILES[lang]), 'utf8')
  const line = md.split('\n').find((l) => l.startsWith('## '))!
  return line.replace(/^##\s+/, '').trim()
}

beforeEach(() => {
  vi.mocked(useParams).mockReturnValue({ id: DEF.id })
  vi.mocked(useDefinition).mockReturnValue({ data: DEF, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useDefinition>)
  vi.mocked(useAuth).mockReturnValue({
    isAuthenticated: true, isLoading: false, loginSource: null, login: vi.fn(), logout: vi.fn(), setSession: vi.fn(), switchTenant: vi.fn(), switchingToTenantSlug: null,
    session: { token: 't', display_name: 'Op', tenant_slug: 'platform', tenant_id: 'tid-platform', tenant_type: 'platform' },
  } as unknown as ReturnType<typeof useAuth>)
  vi.mocked(useTenantContext).mockReturnValue({ tenantType: 'platform', tenantSlug: 'platform', tenantId: 'tid-platform', tenantDisplayName: 'Platform', isUnknown: false } as unknown as ReturnType<typeof useTenantContext>)
})

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  useGuideStore.getState().closeGuide()
  useUiLocaleStore.getState().setLocale('en')
})

describe('T-2805 the Guide entry of the designer page', () => {
  it.each(['en', 'ru', 'kk'] as const)('G1 %s: the entry opens the guide text from the document', async (lang) => {
    useUiLocaleStore.getState().setLocale(lang)
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={qc}>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <MemoryRouter>
            <DefinitionEditorPage />
          </MemoryRouter>
        </AccessStateProvider>
      </QueryClientProvider>,
    )
    const btn = await screen.findByTestId('btn-guide')
    expect(btn).toHaveTextContent(LABELS[lang])
    await userEvent.setup().click(btn)
    const body = await screen.findByTestId('designer-guide-body')
    expect(await screen.findByRole('heading', { name: firstHeading(lang) })).toBeInTheDocument()
    expect(body.querySelector('#sec-notification-step')).not.toBeNull()
    await userEvent.setup().click(screen.getByTestId('designer-guide-close'))
    expect(screen.queryByTestId('designer-guide-panel')).toBeNull()
  })

  it('G2 openGuide(section) renders that section anchor', async () => {
    const { DesignerGuidePanel } = await import('@/components/guide/DesignerGuidePanel')
    render(<DesignerGuidePanel />)
    useGuideStore.getState().openGuide('sec-notification-step')
    expect(await screen.findByTestId('guide-sec-notification-step')).toBeInTheDocument()
  })
})
