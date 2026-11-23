/** platformCall — T-2599 (pilot gap G5a): the `platform_call` attribute of a SERVICE_TASK node — the pure rules of the
 *  function picker and of the TYPED var/const argument mapping.
 *
 *  The attribute is the one the server reads (`lib/letflow/definitions/platform_calls.ex`): a CLOSED key set —
 *  `function`, `args`, `reads`, `writes`. `args` maps an argument name to its source (`{"var": name}` or
 *  `{"const": value}`); `reads` and `writes` map a VARIABLE name to its type name.
 *
 *  The two mapping sides are DERIVED, never typed by hand:
 *    - `reads` holds every variable the step really reads (the `var` arguments) with the type of the catalogue
 *      input it comes from — the server refuses a read that is not declared (`step_mapping_read_undeclared`);
 *    - `writes` holds the catalogue OUTPUTS the step writes, with the output's own type — the server refuses a
 *      write the step's contract does not produce (`step_mapping_write_not_declared`).
 *
 *  The constant of an argument follows the TYPE the catalogue declares for it: a `string` input takes the text
 *  as it is, a `number`/`integer` input takes a number, a `boolean` input takes true/false, and an
 *  `object`/`array` input takes JSON. A text that does not fit the type is refused here, before it reaches the
 *  graph.
 *
 *  Pure and total: no query, no clock, never throws. A malformed attribute is read as "no call".
 */
import type { PlatformFunctionEntry } from '@/types/api'

/** Where an argument's value comes from. */
export type PlatformSource = 'var' | 'const'

/** One argument's source: a variable of the instance, or a constant. */
export type PlatformArgValue = { var: string } | { const: unknown }

/** The `platform_call` attribute of a node. */
export interface PlatformCall {
  function: string
  args: Record<string, PlatformArgValue>
  reads: Record<string, string>
  writes: Record<string, string>
}

/** The JSON-Schema type names a declaration may use — the closed list of `Letflow.Definitions.StepMapping`. */
export const PLATFORM_TYPE_NAMES = ['array', 'boolean', 'integer', 'number', 'object', 'string'] as const

/** The bound on a variable name (the `variable_schemas.variable_key` column: `varchar(255)`). */
export const MAX_VARIABLE_NAME_BYTES = 255

/** A variable name is plain when it is a non-empty binary of at most the bound and carries no dot: the instance
 *  variables are one flat namespace, so a dotted name would be a path, not a variable. */
export function isPlainVariableName(name: unknown): name is string {
  return typeof name === 'string' && name !== '' && !name.includes('.') && new TextEncoder().encode(name).length <= MAX_VARIABLE_NAME_BYTES
}

/** The call of a node's attributes, or null when the node carries none (or carries a malformed one). */
export function parsePlatformCall(raw: unknown): PlatformCall | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const call = raw as Record<string, unknown>
  const fn = call.function
  if (typeof fn !== 'string' || fn.trim() === '') return null
  const args = readArgs(call.args)
  const reads = readTypes(call.reads)
  const writes = readTypes(call.writes)
  if (!args || !reads || !writes) return null
  return { function: fn, args, reads, writes }
}

function readArgs(raw: unknown): Record<string, PlatformArgValue> | null {
  if (raw === undefined || raw === null) return {}
  if (typeof raw !== 'object' || Array.isArray(raw)) return null
  const out: Record<string, PlatformArgValue> = {}
  for (const [name, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null
    const src = value as Record<string, unknown>
    const keys = Object.keys(src)
    if (keys.length !== 1) return null
    if (keys[0] === 'var') {
      if (typeof src.var !== 'string') return null
      out[name] = { var: src.var }
    } else if (keys[0] === 'const') {
      out[name] = { const: src.const }
    } else {
      return null
    }
  }
  return out
}

function readTypes(raw: unknown): Record<string, string> | null {
  if (raw === undefined || raw === null) return {}
  if (typeof raw !== 'object' || Array.isArray(raw)) return null
  const out: Record<string, string> = {}
  for (const [name, type] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof type !== 'string') return null
    out[name] = type
  }
  return out
}

/** A new call for a catalogue entry: no argument is mapped yet and the step writes nothing. */
export function emptyPlatformCall(fn: string): PlatformCall {
  return { function: fn, args: {}, reads: {}, writes: {} }
}

/** The source of an argument: `var`, `const`, or null when the argument is not mapped yet. */
export function argSource(call: PlatformCall, name: string): PlatformSource | null {
  const arg = call.args[name]
  if (!arg) return null
  return 'var' in arg ? 'var' : 'const'
}

/** The text of an argument: the variable name, or the constant as text (see `constText/2`). */
export function argText(call: PlatformCall, name: string, type: string): string {
  const arg = call.args[name]
  if (!arg) return ''
  if ('var' in arg) return arg.var
  return constText(type, arg.const)
}

/** The constant of an argument as TEXT, following the declared type. */
export function constText(type: string, value: unknown): string {
  if (value === undefined || value === null) return ''
  if (type === 'object' || type === 'array') {
    try {
      return JSON.stringify(value)
    } catch {
      return ''
    }
  }
  if (type === 'boolean') return value === true ? 'true' : value === false ? 'false' : ''
  return String(value)
}

/** Why a constant's text does not fit the declared type. */
export type ConstError = 'not_a_number' | 'not_a_boolean' | 'not_json'

/** The constant of an argument from its TEXT, following the declared type. A text that does not fit is refused. */
export function parseConst(type: string, text: string): { ok: true; value: unknown } | { ok: false; error: ConstError } {
  if (type === 'number' || type === 'integer') {
    const n = Number(text.trim())
    if (text.trim() === '' || !Number.isFinite(n)) return { ok: false, error: 'not_a_number' }
    if (type === 'integer' && !Number.isInteger(n)) return { ok: false, error: 'not_a_number' }
    return { ok: true, value: n }
  }
  if (type === 'boolean') {
    const t = text.trim().toLowerCase()
    if (t === 'true') return { ok: true, value: true }
    if (t === 'false') return { ok: true, value: false }
    return { ok: false, error: 'not_a_boolean' }
  }
  if (type === 'object' || type === 'array') {
    try {
      const parsed: unknown = JSON.parse(text)
      if (type === 'array' && !Array.isArray(parsed)) return { ok: false, error: 'not_json' }
      if (type === 'object' && (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed))) {
        return { ok: false, error: 'not_json' }
      }
      return { ok: true, value: parsed }
    } catch {
      return { ok: false, error: 'not_json' }
    }
  }
  return { ok: true, value: text }
}

/** The call with one argument mapped. The source is part of the mapping: an argument whose source is chosen but
 *  whose value is not typed yet KEEPS its key (the server refuses it until it is filled), and only a source set
 *  back to "not mapped" removes the argument. */
export function withArg(call: PlatformCall, name: string, source: PlatformSource | null, value: unknown): PlatformCall {
  const args = { ...call.args }
  if (source === null) {
    delete args[name]
  } else if (source === 'var') {
    args[name] = { var: typeof value === 'string' ? value : '' }
  } else {
    args[name] = { const: value }
  }
  return { ...call, args }
}

/** The READS of a call: every variable the step really reads, with the type of the catalogue input it comes from.
 *  The first input that names a variable wins: two inputs of DIFFERENT types on one variable are a conflict the
 *  UI reports (`readConflicts/2`), not a silent choice. */
export function deriveReads(call: PlatformCall, entry: PlatformFunctionEntry): Record<string, string> {
  const reads: Record<string, string> = {}
  for (const input of entry.inputs) {
    const arg = call.args[input.name]
    if (!arg || !('var' in arg)) continue
    const name = arg.var
    if (name === '' || name in reads) continue
    reads[name] = input.type
  }
  return reads
}

/** The variables two inputs of DIFFERENT types would both read — a mapping the server cannot satisfy. */
export function readConflicts(call: PlatformCall, entry: PlatformFunctionEntry): string[] {
  const seen = new Map<string, string>()
  const conflicts = new Set<string>()
  for (const input of entry.inputs) {
    const arg = call.args[input.name]
    if (!arg || !('var' in arg)) continue
    const name = arg.var
    if (name === '') continue
    const previous = seen.get(name)
    if (previous === undefined) seen.set(name, input.type)
    else if (previous !== input.type) conflicts.add(name)
  }
  return [...conflicts].sort()
}

/** The WRITES of a call: the catalogue outputs the step writes, with the output's own type. A name that is not an
 *  output of the entry is dropped: the server refuses a write the step's contract does not produce. */
export function deriveWrites(call: PlatformCall, entry: PlatformFunctionEntry): Record<string, string> {
  const writes: Record<string, string> = {}
  for (const output of entry.outputs) {
    if (output.name in call.writes) writes[output.name] = output.type
  }
  return writes
}

/** The call with the derived mapping sides — the shape the server reads. */
export function withDerivedMapping(call: PlatformCall, entry: PlatformFunctionEntry): PlatformCall {
  return { function: call.function, args: call.args, reads: deriveReads(call, entry), writes: deriveWrites(call, entry) }
}
