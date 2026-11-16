/** Pure helpers of the Official forms screen (T-1983): the form registry, per-form state, reason codes,
 *  refusal places and error mapping. No React, no network. */
import type { OfficialFormTemplateMeta, TemplateAction, TemplateLocale, TemplateRefusal } from '@/api/officialFormTemplates'

export interface OfficialTemplateForm {
  id: string
  module: 'assets' | 'stock'
}

/** The shipped forms, module group then number. Test M1 pins the ids to `priv/print_forms`. */
export const OFFICIAL_TEMPLATE_FORMS: readonly OfficialTemplateForm[] = [
  { id: 'da1', module: 'assets' },
  { id: 'da2', module: 'assets' },
  { id: 'da3', module: 'assets' },
  { id: 'da4', module: 'assets' },
  { id: 'inv8', module: 'assets' },
  { id: 'inv10', module: 'stock' },
  { id: 'inv18', module: 'stock' },
  { id: 'z1', module: 'stock' },
  { id: 'z2', module: 'stock' },
  { id: 'z3', module: 'stock' },
  { id: 'z5', module: 'stock' },
  { id: 'z6', module: 'stock' },
  { id: 'z7', module: 'stock' },
]

/** `FormTemplate.refusal_codes/0`; test M3 pins the list to the Elixir source. */
export const REFUSAL_CODES = [
  'unknown_form', 'too_large', 'infected', 'scan_unavailable', 'not_docx', 'zip_too_many_entries',
  'zip_bad_entry', 'zip_inflated_too_large', 'zip_ratio', 'forbidden_part', 'image_type', 'image_too_large',
  'macro_enabled', 'xml_unreadable', 'doctype', 'external_relationship', 'unsupported_reference',
  'field_code', 'tracked_change', 'data_binding', 'malformed_placeholder', 'placeholder_not_plain',
  'unknown_name', 'missing_legal', 'duplicate_legal', 'missing_data', 'repeat_row', 'column_order', 'total_place',
] as const

/** Reason codes per action; each matches the server rule `^[a-z][a-z0-9_]{0,63}$`. */
export const REASON_CODES: Record<TemplateAction, readonly string[]> = {
  activate: ['first_template', 'layout_change', 'correction', 'other'],
  retire: ['back_to_standard', 'draft_not_needed', 'other'],
  rollback: ['new_version_wrong', 'back_to_previous', 'other'],
}

export const TEMPLATE_LOCALES: readonly TemplateLocale[] = ['default', 'ru', 'kk']

export interface FormState {
  /** Active row per locale that has one. */
  active: OfficialFormTemplateMeta[]
  /** Newest draft, if any. */
  draft: OfficialFormTemplateMeta | null
}

export function rowsOf(rows: readonly OfficialFormTemplateMeta[], form: string): OfficialFormTemplateMeta[] {
  return rows
    .filter((r) => r.form === form)
    .sort((a, b) => TEMPLATE_LOCALES.indexOf(a.locale) - TEMPLATE_LOCALES.indexOf(b.locale) || b.version_no - a.version_no)
}

export function formState(rows: readonly OfficialFormTemplateMeta[]): FormState {
  const active = rows.filter((r) => r.status === 'active')
  const drafts = rows.filter((r) => r.status === 'draft').sort((a, b) => b.version_no - a.version_no)
  return { active, draft: drafts[0] ?? null }
}

/** The server's `:not_rollbackable` rule: only a retired row that was once active. */
export function rollbackable(row: Pick<OfficialFormTemplateMeta, 'status' | 'activated_at'>): boolean {
  return row.status === 'retired' && row.activated_at != null
}

export type PlaceKey = 'table' | 'row' | 'cell' | 'paragraph' | 'part'
const PLACE_KEYS: readonly PlaceKey[] = ['table', 'row', 'cell', 'paragraph', 'part']

/** The known keys of a refusal place, in reading order; unknown keys are ignored. */
export function placeParts(place: Record<string, unknown> | null): { key: PlaceKey; value: string }[] {
  if (place == null) return []
  const out: { key: PlaceKey; value: string }[] = []
  for (const key of PLACE_KEYS) {
    const v = place[key]
    if (typeof v === 'number' || (typeof v === 'string' && v !== '')) out.push({ key, value: String(v) })
  }
  return out
}

export function isKnownRefusalCode(code: string | null): code is (typeof REFUSAL_CODES)[number] {
  return code != null && (REFUSAL_CODES as readonly string[]).includes(code)
}

export function refusalMessageId(r: TemplateRefusal): string {
  return isKnownRefusalCode(r.code) ? `officialForms.refusal.${r.code}` : 'officialForms.refusal.unknown'
}

const CONFLICT_DETAILS: Record<string, string> = {
  'template is not a draft': 'not_a_draft',
  'template is already retired': 'not_retirable',
  'only a retired template that was once active can be rolled back to': 'not_rollbackable',
}

/** Message id of a failed transition (409 maps the server's fixed `detail`; the client keeps the body in `details`). */
export function conflictKey(err: unknown): string {
  const e = err as { status?: unknown; details?: { detail?: unknown } } | null
  if (e?.status === 409) {
    const detail = typeof e.details?.detail === 'string' ? e.details.detail : ''
    const known = CONFLICT_DETAILS[detail]
    return known ? `officialForms.error.${known}` : 'officialForms.error.changed'
  }
  if (e?.status === 403) return 'officialForms.error.forbidden'
  if (e?.status === 422) return 'officialForms.error.invalid'
  return 'officialForms.error.generic'
}

/** Message id of a failed upload that carries no refusal list. */
export function uploadErrorKey(err: unknown): string {
  const e = err as { status?: unknown } | null
  if (e?.status === 403) return 'officialForms.error.forbidden'
  if (e?.status === 422) return 'officialForms.error.invalid'
  return 'officialForms.error.generic'
}

const REASON_ID = /^[a-z][a-z0-9_]{0,63}$/
export function isReasonCode(code: string): boolean {
  return REASON_ID.test(code)
}

/** Message id of a stored reason code; null when this screen has no text for it (shown raw, mono). */
export function knownReasonId(code: string): string | null {
  if (code === 'superseded') return 'officialForms.reason.superseded'
  return (Object.values(REASON_CODES).some((l) => l.includes(code)) ? `officialForms.reason.${code}` : null)
}

/** File name from a Content-Disposition header, else the fallback. Only a plain `filename="..."` is read. */
export function fileNameOf(header: string | null, fallback: string): string {
  const m = header == null ? null : /filename="([^"\\/]{1,120})"/.exec(header)
  return m ? m[1] : fallback
}
