/** Harness fixtures for the Official forms admin screen (T-1983, form-template editor S5).
 *  One screen name per state (the screenshot tool names files without the state). The pre-selected form, the upload,
 *  the dialog and the on-mount submits are HARNESS-ONLY props of the page (the tool cannot click). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { P, RequirePermission } from '@/auth/access'
import { ToastContainer } from '@/components/ui/Toast'
import type { AccessState } from '@/auth/access/types'
import OfficialFormTemplatesPage, {
  type OfficialFormTemplatesPageProps,
} from '@/pages/admin/official-forms/OfficialFormTemplatesPage'
import type { OfficialFormTemplateMeta, TemplateRefusal } from '@/api/officialFormTemplates'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const AUTH: AuthContextValue = {
  session: {
    token: 'harness.' + btoa(JSON.stringify({ sub: 'harness-id' })) + '.sig',
    tenant_id: 'harness-tenant',
    display_name: 'Harness Admin',
    loginSource: 'oidc',
    tenant_slug: 'harness',
    tenant_display_name: 'Harness Co',
    tenant_type: 'production',
  } as UserSession,
  isAuthenticated: true,
  isLoading: false,
  login: () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
} as unknown as AuthContextValue

const ACCESS: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['OfficialFormTemplatesManage', 'MyAccessRead'] },
}
const ACCESS_DENIED: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['MyAccessRead'] } }

const ID = (n: number) => `00000000-0000-4000-8000-0000000000${String(n).padStart(2, '0')}`
const base = {
  byte_size: 18_400,
  sha256: 'a'.repeat(64),
  created_by: null,
  activated_by: null,
  updated_at: '2026-11-10T09:00:00Z',
}
const z1 = (n: number, over: Partial<OfficialFormTemplateMeta>): OfficialFormTemplateMeta => ({
  ...base,
  id: ID(n),
  form: 'z1',
  locale: 'ru',
  version_no: n,
  status: 'retired',
  rollback_of: null,
  activated_at: null,
  retired_at: null,
  reason_code: null,
  inserted_at: '2026-11-01T09:00:00Z',
  ...over,
})
const ROWS: OfficialFormTemplateMeta[] = [
  z1(4, { status: 'draft', inserted_at: '2026-11-12T09:00:00Z' }),
  z1(3, { status: 'active', activated_at: '2026-11-10T09:00:00Z', reason_code: 'layout_change', inserted_at: '2026-11-09T09:00:00Z' }),
  z1(2, { activated_at: '2026-11-05T09:00:00Z', retired_at: '2026-11-10T09:00:00Z', reason_code: 'superseded', inserted_at: '2026-11-04T09:00:00Z' }),
  z1(1, { activated_at: '2026-11-02T09:00:00Z', retired_at: '2026-11-05T09:00:00Z', reason_code: 'go_live', inserted_at: '2026-11-01T09:00:00Z' }),
  z1(1, { id: ID(11), locale: 'default', status: 'draft', rollback_of: ID(1), inserted_at: '2026-11-11T09:00:00Z' }),
  { ...z1(1, { locale: 'kk', status: 'draft', inserted_at: '2026-11-11T10:00:00Z' }), id: ID(12), form: 'da3' },
]

const REFUSALS: TemplateRefusal[] = [
  { code: 'missing_legal', rule: 'D3.1', place: { table: 1, row: 2, cell: 5 }, name: 'annex_line', category: 'legal' },
  { code: 'column_order', rule: 'D3.4', place: { table: 2, row: 3, cell: 1 }, name: null, category: null },
  { code: 'macro_enabled', rule: 'D2', place: { part: 'word/vbaProject.bin' }, name: null, category: null },
  { code: 'future_rule', rule: 'D9', place: null, name: null, category: null },
]

interface Spec {
  rows?: OfficialFormTemplateMeta[]
  get?: { status: number; body?: unknown } | 'pending'
  post?: { status: number; body: unknown }
  props?: OfficialFormTemplatesPageProps
  denied?: boolean
}

function routesOf(spec: Spec): FixtureRoute[] {
  const base = '/api/v1/documents/official-form-templates'
  // A 201 answer adds its row to the list the next GET returns (the screen refetches after an upload).
  const added: OfficialFormTemplateMeta[] = []
  return [
    {
      match: (path, method) => path === base && method === 'GET',
      pending: spec.get === 'pending',
      reply: () =>
        spec.get && spec.get !== 'pending'
          ? { status: spec.get.status, body: spec.get.body ?? { status: spec.get.status, message: 'error' } }
          : { status: 200, body: { templates: [...added, ...(spec.rows ?? ROWS)] } },
    },
    {
      match: (path, method) => path.startsWith(base) && method === 'POST',
      reply: () => {
        const reply = spec.post ?? { status: 201, body: { ...z1(5, { status: 'draft', inserted_at: '2026-11-15T09:00:00Z' }) } }
        if (reply.status === 201) added.push(reply.body as OfficialFormTemplateMeta)
        return reply
      },
    },
  ]
}

function mkScreen(name: string, spec: Spec = {}): HarnessScreen {
  return {
    name,
    routes: routesOf(spec),
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={spec.denied ? ACCESS_DENIED : ACCESS}>
          <div className="lf-main">
            <main className="lf-content">
              <RequirePermission permission={P.OfficialFormTemplatesManage}>
                <OfficialFormTemplatesPage locale={lang} {...spec.props} />
              </RequirePermission>
            </main>
            <ToastContainer />
          </div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

const FILE = () => new File([new Uint8Array([80, 75, 3, 4])], 'my-z1.docx')
const refused = (body: unknown) => ({ status: 422, body })
const REFUSED = { status: 422, detail: 'template refused', refusals: REFUSALS }

export const officialFormTemplatesScreens: HarnessScreen[] = [
  mkScreen('official-forms-first-use', { rows: [], props: { initialSelectedKey: 'da1' } }),
  mkScreen('official-forms-history', { props: { initialSelectedKey: 'z1' } }),
  mkScreen('official-forms-upload', { props: { initialSelectedKey: 'z1', initialUploadOpen: true, initialFile: FILE() } }),
  mkScreen('official-forms-refused', {
    post: refused(REFUSED),
    props: { initialSelectedKey: 'z1', initialUploadOpen: true, initialFile: FILE(), submitUploadOnMount: true },
  }),
  mkScreen('official-forms-accepted', {
    props: { initialSelectedKey: 'z1', initialUploadOpen: true, initialFile: FILE(), submitUploadOnMount: true },
  }),
  mkScreen('official-forms-activate', {
    props: { initialSelectedKey: 'z1', initialDialog: { action: 'activate', id: ID(4) }, initialReason: 'layout_change' },
  }),
  mkScreen('official-forms-activate-refused', {
    post: refused(REFUSED),
    props: { initialSelectedKey: 'z1', initialDialog: { action: 'activate', id: ID(4) }, initialReason: 'correction', submitDialogOnMount: true },
  }),
  mkScreen('official-forms-retire', {
    props: { initialSelectedKey: 'z1', initialDialog: { action: 'retire', id: ID(3) }, initialReason: 'back_to_standard' },
  }),
  mkScreen('official-forms-rollback', {
    props: { initialSelectedKey: 'z1', initialDialog: { action: 'rollback', id: ID(2) }, initialReason: 'new_version_wrong' },
  }),
  mkScreen('official-forms-conflict', {
    post: { status: 409, body: { status: 409, detail: 'only a retired template that was once active can be rolled back to' } },
    props: { initialSelectedKey: 'z1', initialDialog: { action: 'rollback', id: ID(2) }, initialReason: 'new_version_wrong', submitDialogOnMount: true },
  }),
  mkScreen('official-forms-loading', { get: 'pending' }),
  mkScreen('official-forms-error', { get: { status: 500 } }),
  mkScreen('official-forms-denied', { denied: true }),
]
