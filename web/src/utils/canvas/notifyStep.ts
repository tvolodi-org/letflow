/** notifyStep — T-2600 (pilot gap G5b): the `notify` attribute of a SERVICE_TASK node — the pure rules of the
 *  notification step's form: the CHANNEL, the TEMPLATE, the RECIPIENT and the VALUES.
 *
 *  The attribute is the one the server reads (`lib/letflow/definitions/notify_calls.ex`): a CLOSED key set —
 *  `channel`, `template_key`, `recipient`, `file_name`, `values`. The channels are EXCLUSIVE: the mail channel
 *  carries a recipient and no file name, the file channel carries a file name and no recipient.
 *
 *  The rules the form enforces are the server's own, so a declaration that the form accepts is one the server
 *  accepts:
 *    - the template key must be a REGISTERED one (the catalogue names the registered keys);
 *    - the RECIPIENT is a VARIABLE of the process, never a fixed address: a constant address would sit in the
 *      stored definition of the tenant, and the address of a person is personal data the platform does not store
 *      (INV-4). The server refuses a constant recipient with `notify_recipient_invalid`;
 *    - the FILE NAME is a plain name: no separator, no `..`, no drive letter, no home directory, no control
 *      character (the server refuses it with `notify_file_name_invalid`);
 *    - every VALUE names a placeholder of the template's allow-list, and its source is a variable of the process
 *      or a fixed value.
 *
 *  Pure and total: no query, no clock, never throws. A malformed attribute is read as "no notification step".
 */
import { isPlainVariableName, isReservedVariableName } from './platformCall'

/** Where the notification goes: out of the platform (mail) or into the tenant's own file area. */
export type NotifyChannel = 'email' | 'file'

/** The channels of the step — the closed list of the server (`@channels`). */
export const NOTIFY_CHANNELS: NotifyChannel[] = ['email', 'file']

/** One value's source: a variable of the process, or a fixed value. */
export type NotifyValueSource = { var: string } | { const: string }

/** The notification step of a node. */
export interface NotifyStep {
  channel: NotifyChannel
  templateKey: string
  /** The variable the mail goes to (the mail channel only). */
  recipientVar: string
  /** The name the file is stored under (the file channel only). */
  fileName: string
  /** The declared values, by placeholder name. */
  values: Record<string, NotifyValueSource>
}

/** The bound on a file name (the server's `@max_file_name_bytes`). */
export const MAX_FILE_NAME_BYTES = 255

/** The bound on a fixed value (the server's `@max_const_bytes`). */
export const MAX_CONST_BYTES = 4096

/** The bound on a template key (the server's `@max_template_key_bytes`). */
export const MAX_TEMPLATE_KEY_BYTES = 64

/** A variable name the server accepts: plain (not empty, no dot, within the bound) and outside the reserved
 *  namespace (`_sys`). */
export function isUsableVariableName(name: unknown): name is string {
  return isPlainVariableName(name) && !isReservedVariableName(name)
}

/** The step of a node's attributes, or null when the node carries none (or carries a malformed one). */
export function parseNotifyStep(raw: unknown): NotifyStep | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const attr = raw as Record<string, unknown>
  const channel = attr.channel === undefined || attr.channel === null ? 'email' : attr.channel
  if (channel !== 'email' && channel !== 'file') return null
  if (typeof attr.template_key !== 'string' || attr.template_key === '') return null
  const values = readValues(attr.values)
  if (!values) return null
  return {
    channel,
    templateKey: attr.template_key,
    recipientVar: readVar(attr.recipient),
    fileName: typeof attr.file_name === 'string' ? attr.file_name : '',
    values,
  }
}

function readVar(raw: unknown): string {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return ''
  const src = raw as Record<string, unknown>
  if (Object.keys(src).length !== 1 || typeof src.var !== 'string') return ''
  return src.var
}

function readValues(raw: unknown): Record<string, NotifyValueSource> | null {
  if (raw === undefined || raw === null) return {}
  if (typeof raw !== 'object' || Array.isArray(raw)) return null
  const out: Record<string, NotifyValueSource> = {}
  for (const [name, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null
    const src = value as Record<string, unknown>
    const keys = Object.keys(src)
    if (keys.length !== 1) return null
    if (keys[0] === 'var' && typeof src.var === 'string') out[name] = { var: src.var }
    else if (keys[0] === 'const' && typeof src.const === 'string') out[name] = { const: src.const }
    else return null
  }
  return out
}

/** A new step: the mail channel, no template, no recipient, no values. */
export function emptyNotifyStep(channel: NotifyChannel = 'email'): NotifyStep {
  return { channel, templateKey: '', recipientVar: '', fileName: '', values: {} }
}

/** The `notify` attribute the server reads: only the keys the CHANNEL carries, and only the values that are
 *  declared. The mail channel carries no file name and the file channel carries no recipient — the server refuses
 *  both. */
export function notifyAttribute(step: NotifyStep): Record<string, unknown> {
  const attr: Record<string, unknown> = { template_key: step.templateKey }
  if (step.channel === 'file') {
    attr.channel = 'file'
    if (step.fileName !== '') attr.file_name = step.fileName
  } else {
    if (step.recipientVar !== '') attr.recipient = { var: step.recipientVar }
  }
  const values: Record<string, unknown> = {}
  for (const [name, source] of Object.entries(step.values)) {
    if ('var' in source) values[name] = { var: source.var }
    else values[name] = { const: source.const }
  }
  attr.values = values
  return attr
}

/** The step with a different channel. Switching drops what the other channel carried: the recipient (mail) or the
 *  file name (file) — the server refuses a step that carries both. */
export function withChannel(step: NotifyStep, channel: NotifyChannel): NotifyStep {
  if (channel === step.channel) return step
  if (channel === 'file') return { ...step, channel, recipientVar: '' }
  return { ...step, channel, fileName: '' }
}

/** The step with one value mapped. A value whose source is chosen but whose value is empty KEEPS its key: the
 *  server refuses it until it is filled, and the form shows the error. */
export function withValue(step: NotifyStep, name: string, source: NotifyValueSource | null): NotifyStep {
  const values = { ...step.values }
  if (source === null) delete values[name]
  else values[name] = source
  return { ...step, values }
}

/** The source of a value, or null when the value is not declared. */
export function valueSource(step: NotifyStep, name: string): NotifyValueSource | null {
  return step.values[name] ?? null
}

/** Why a file name is refused — the server's own rule (`notify_file_name_invalid`). A name that breaks it is
 *  refused the same way, whatever the mistake was. */
export function fileNameProblem(name: string): 'empty' | 'too_long' | 'not_text' | 'path' | null {
  if (name === '') return 'empty'
  if (new TextEncoder().encode(name).length > MAX_FILE_NAME_BYTES) return 'too_long'
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001F\u007F]/.test(name)) return 'not_text'
  if (name.includes('/') || name.includes('\\') || name.includes('..') || name.includes(':') || name.startsWith('~')) {
    return 'path'
  }
  return null
}

/** Why a declaration is refused, in the order the server checks it. The codes are the server's own, so the form
 *  and the server cannot disagree about what a step says. */
export type NotifyProblem =
  | 'template_missing'
  | 'template_unknown'
  | 'recipient_missing'
  | 'recipient_invalid'
  | 'file_name_missing'
  | 'file_name_invalid'
  | 'value_unknown'
  | 'value_invalid'

/** The problems of a step, in the order the server checks them. `placeholders` is the allow-list of the chosen
 *  template (the catalogue publishes it); a step whose template is not in the catalogue is reported as unknown. */
export function notifyProblems(
  step: NotifyStep,
  placeholders: string[] | null,
  registeredKeys: string[] | null,
): NotifyProblem[] {
  const problems: NotifyProblem[] = []
  if (step.templateKey === '') {
    problems.push('template_missing')
    return problems
  }
  if (registeredKeys && !registeredKeys.includes(step.templateKey)) problems.push('template_unknown')

  if (step.channel === 'email') {
    if (step.recipientVar === '') problems.push('recipient_missing')
    else if (!isUsableVariableName(step.recipientVar)) problems.push('recipient_invalid')
  } else if (step.fileName === '') {
    problems.push('file_name_missing')
  } else if (fileNameProblem(step.fileName) !== null) {
    problems.push('file_name_invalid')
  }

  if (placeholders) {
    for (const [name, source] of Object.entries(step.values)) {
      if (!placeholders.includes(name)) {
        problems.push('value_unknown')
        continue
      }
      if ('var' in source && !isUsableVariableName(source.var)) problems.push('value_invalid')
      if ('const' in source && new TextEncoder().encode(source.const).length > MAX_CONST_BYTES) problems.push('value_invalid')
    }
  }
  return problems
}
