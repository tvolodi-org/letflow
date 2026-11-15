/** T-1983 — official-form templates API client (`Letflow.Routers.Documents`, permission OfficialFormTemplatesManage).
 *  Base /api/v1/documents/official-form-templates. Downloads are one-shot blobs, not queries. */
import { client } from './client'

const BASE = '/api/v1/documents/official-form-templates'

export type TemplateLocale = 'default' | 'ru' | 'kk'
export type TemplateStatus = 'draft' | 'active' | 'retired'

/** `render_template_meta/1` of the router; the wire name of the form id is `form`. */
export interface OfficialFormTemplateMeta {
  id: string
  form: string
  locale: TemplateLocale
  version_no: number
  status: TemplateStatus
  byte_size: number
  sha256: string
  rollback_of: string | null
  created_by: string | null
  activated_by: string | null
  activated_at: string | null
  retired_at: string | null
  reason_code: string | null
  inserted_at: string
  updated_at: string
}

/** One refusal of the template check. Only closed-list names, never company text. */
export interface TemplateRefusal {
  code: string | null
  rule: string | null
  place: Record<string, unknown> | null
  name: string | null
  category: string | null
}

export interface FetchedTemplateFile {
  blob: Blob
  contentDisposition: string | null
}

export type TemplateAction = 'activate' | 'retire' | 'rollback'

export const officialFormTemplatesApi = {
  list: () => client.get<{ templates: OfficialFormTemplateMeta[] }>(BASE),
  upload: (form: string, locale: TemplateLocale, file: File) => {
    const body = new FormData()
    body.append('form', form)
    body.append('locale', locale)
    body.append('file', file)
    return client.post<OfficialFormTemplateMeta>(BASE, body)
  },
  transition: (id: string, action: TemplateAction, reasonCode: string) =>
    client.post<OfficialFormTemplateMeta>(`${BASE}/${encodeURIComponent(id)}/${action}`, { reason_code: reasonCode }),
  download: (id: string): Promise<FetchedTemplateFile> =>
    client.getBlob(`${BASE}/${encodeURIComponent(id)}/download`),
  preview: (id: string, lang: 'ru' | 'kk'): Promise<FetchedTemplateFile> =>
    client.getBlob(`${BASE}/${encodeURIComponent(id)}/preview`, { lang }),
  starter: (form: string): Promise<FetchedTemplateFile> =>
    client.getBlob(`${BASE}/starter/${encodeURIComponent(form)}`),
}

/** The refusals of a 422 `template refused` answer (the body has no `errors` member, so the client keeps it whole in
 *  `details`), else null. Only the five known keys are read. */
export function refusalsOf(err: unknown): TemplateRefusal[] | null {
  const e = err as { status?: unknown; details?: { refusals?: unknown } } | null
  if (e?.status !== 422 || !Array.isArray(e.details?.refusals)) return null
  return (e.details.refusals as unknown[]).map((r) => {
    const o = (r ?? {}) as Record<string, unknown>
    const str = (v: unknown) => (typeof v === 'string' ? v : null)
    return {
      code: str(o.code),
      rule: str(o.rule),
      place: o.place != null && typeof o.place === 'object' ? (o.place as Record<string, unknown>) : null,
      name: str(o.name),
      category: str(o.category),
    }
  })
}
