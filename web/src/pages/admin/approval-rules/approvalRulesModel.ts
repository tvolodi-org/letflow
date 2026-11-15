/** Pure helpers of the Approval rules screen (T-1989): ids, readable names, error mapping. */
import type { ApprovalRule } from '@/api/approvalRules'
import { definitionLabel } from '@/pages/dashboard/definitionLabels'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { approvalRulesMessages } from './approvalRulesMessages'

/** Row id. JSON, not a path: a definition name may contain `/`; it never goes into a URL. */
export function ruleKey(r: Pick<ApprovalRule, 'definition_name' | 'node_id'>): string {
  return JSON.stringify([r.definition_name, r.node_id])
}

function catalog(id: string, locale: UiLocale): string | null {
  const m = approvalRulesMessages[locale]
  return Object.hasOwn(m, id) ? m[id] : null
}

/** Process display name: this screen's catalog, then the shared definition labels, then the key itself
 *  (a tenant's own definition name is already a human name). */
export function processName(definitionName: string, locale: UiLocale): string {
  return catalog(`approvalRules.process.${definitionName}`, locale) ?? definitionLabel(definitionName, locale)
}

/** Step display name: the node's own label, then the catalog name of a known id, then the id. */
export function stepName(r: Pick<ApprovalRule, 'node_id' | 'node_label'>, locale: UiLocale): string {
  if (r.node_label != null && r.node_label !== '') return r.node_label
  return catalog(`approvalRules.step.${r.node_id}`, locale) ?? r.node_id
}

/** Message id of a failed save. The server's code is `details.detail` (RFC 9457 body kept by the client). */
export function saveErrorKey(err: unknown): string {
  const e = err as { status?: unknown; details?: { detail?: unknown } } | null
  const detail = typeof e?.details?.detail === 'string' ? e.details.detail : null
  if (detail === 'invalid_reason' || detail === 'not_a_four_eyes_step' || detail === 'concurrent_change') {
    return `approvalRules.error.${detail}`
  }
  if (e?.status === 409) return 'approvalRules.error.concurrent_change'
  if (e?.status === 403) return 'approvalRules.error.forbidden'
  return 'approvalRules.error.generic'
}
