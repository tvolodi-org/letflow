/** nodeSummary — T-1520. What the diagram shows of a node's attributes: only the known keys of the format inventory
 *  (docs/design/process-designer.md), as plain text. Unknown keys are counted, never shown; an endpoint URL is
 *  reduced to scheme and host (a path or query may embed a token); expressions (`args`, `x-ui`) are never shown. */
import { FORMAT_KEYS, diagramConfig } from './diagramConfig'

export interface NodeSummary {
  /** The short line under the node label. */
  subLine: string | null
  role?: string
  assignee?: string
  formFields?: { key: string; title: string }[]
  formFieldCount?: number
  validationScript?: string
  distinctFrom?: string[]
  writes?: string[]
  service?: string
  /** Scheme + host only, or `null` for a set but malformed endpoint. */
  endpointHost?: string | null
  script?: string
  scriptVersion?: string
  timeoutMs?: string
  duration?: string
  subDefinition?: string
  /** T-2742: the platform function a `platform_call` step runs (`tenant.validate`). */
  platformFunction?: string
  /** T-2742: the template key and the recipient variable of a `notify` step (a constant address is never shown). */
  notifyTemplate?: string
  notifyRecipientVar?: string
  otherCount: number
}

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

/** T-2742: the caption of a step that has no label of its own: the short name of the platform function it runs
 *  (`tenant.validate` -> `validate`), or `notify` for a notification step. Null for any other step. */
export function stepCaption(nodeType: string, attrs: unknown): string | null {
  if (nodeType !== 'SERVICE_TASK' || !isObj(attrs)) return null
  const call = attrs.platform_call
  if (isObj(call) && typeof call.function === 'string' && call.function.trim() !== '') {
    const fn = call.function
    return fn.slice(fn.lastIndexOf('.') + 1) || fn
  }
  if (isObj(attrs.notify)) return 'notify'
  return null
}

const str = (v: unknown): string | undefined =>
  typeof v === 'string' && v.trim() !== '' ? v : typeof v === 'number' ? String(v) : undefined

export function endpointHost(raw: string): string | null {
  try {
    const u = new URL(raw)
    if (!u.protocol || !u.host) return null
    return `${u.protocol}//${u.host}`
  } catch {
    return null
  }
}

function parseSchema(v: unknown): Record<string, unknown> | null {
  if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>
  if (typeof v === 'string') {
    try {
      const p: unknown = JSON.parse(v)
      return p && typeof p === 'object' && !Array.isArray(p) ? (p as Record<string, unknown>) : null
    } catch {
      return null
    }
  }
  return null
}

export function summariseNode(
  nodeType: string,
  attrs: Record<string, unknown>,
  labelOf: (id: string) => string = (id) => id,
): NodeSummary {
  const known = new Set([...(FORMAT_KEYS[nodeType] ?? []), ...FORMAT_KEYS.ANY])
  const out: NodeSummary = { subLine: null, otherCount: Object.keys(attrs).filter((k) => !known.has(k)).length }
  const has = (k: string) => known.has(k) && attrs[k] !== undefined && attrs[k] !== null

  if (has('role')) out.role = str(attrs.role)
  if (has('assignee_ref')) out.assignee = str(attrs.assignee_ref)
  if (has('form_schema')) {
    const schema = parseSchema(attrs.form_schema)
    const props = schema?.properties
    if (props && typeof props === 'object' && !Array.isArray(props)) {
      const entries = Object.entries(props as Record<string, unknown>)
      out.formFieldCount = entries.length
      out.formFields = entries.slice(0, diagramConfig.formFieldCap).map(([key, def]) => ({
        key,
        title: str((def as { title?: unknown } | null)?.title) ?? key,
      }))
    }
  }
  if (has('validation_script_key')) out.validationScript = str(attrs.validation_script_key)
  if (has('distinct_from')) {
    const raw = attrs.distinct_from
    const ids = Array.isArray(raw) ? raw.filter((x): x is string => typeof x === 'string') : typeof raw === 'string' ? [raw] : []
    out.distinctFrom = ids.map(labelOf)
  }
  if (has('module_writes') && Array.isArray(attrs.module_writes)) {
    out.writes = (attrs.module_writes as unknown[])
      .map((w) => str((w as { handler?: unknown } | null)?.handler))
      .filter((h): h is string => h !== undefined)
  }
  if (has('service_id')) out.service = str(attrs.service_id)
  if (has('endpoint') && str(attrs.endpoint)) out.endpointHost = endpointHost(str(attrs.endpoint)!)
  if (has('script_key')) out.script = str(attrs.script_key)
  if (has('script_version')) out.scriptVersion = str(attrs.script_version)
  if (has('timeout_ms')) out.timeoutMs = str(attrs.timeout_ms)
  if (has('duration_iso8601')) out.duration = str(attrs.duration_iso8601)
  if (has('definition_name')) out.subDefinition = str(attrs.definition_name)

  if (nodeType === 'SERVICE_TASK') {
    const call = attrs.platform_call
    if (isObj(call) && typeof call.function === 'string') out.platformFunction = call.function
    const notify = attrs.notify
    if (isObj(notify)) {
      out.notifyTemplate = str(notify.template_key)
      const rec = notify.recipient
      if (isObj(rec)) out.notifyRecipientVar = str(rec.var)
    }
  }

  out.subLine = out.platformFunction ?? out.role ?? out.assignee ?? out.script ?? out.duration ?? out.subDefinition ?? out.service ?? null
  return out
}
