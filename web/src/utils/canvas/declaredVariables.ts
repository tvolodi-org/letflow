/** declaredVariables — T-2811 (designer D1). The VARIABLES a process declares (the server's `variable_schemas`): a name
 *  and a JSON-Schema type, shown on the Edit-diagram screen and offered by every "a variable of the process" picker.
 *  Pure helpers; the screen owns the list. */
import type { DefinitionGraph, DeclaredVariable } from '@/types/api'
import { isUsableVariableName } from './notifyStep'

export const VARIABLE_TYPES = ['string', 'number', 'boolean'] as const
export type VariableType = (typeof VARIABLE_TYPES)[number]

/** The type name of a declared variable ('' when the schema names none). */
export function variableType(v: DeclaredVariable): string {
  const t = v.json_schema && typeof v.json_schema === 'object' ? (v.json_schema as Record<string, unknown>).type : undefined
  return typeof t === 'string' ? t : ''
}

export type AddVariableRefusal = 'name_invalid' | 'name_taken'

/** Adds a variable; a name the server refuses, or one that is already declared, is refused with a reason. */
export function addVariable(
  list: DeclaredVariable[],
  name: string,
  type: VariableType,
): { ok: true; list: DeclaredVariable[] } | { ok: false; reason: AddVariableRefusal } {
  const key = name.trim()
  if (!isUsableVariableName(key)) return { ok: false, reason: 'name_invalid' }
  if (list.some((v) => v.variable_key === key)) return { ok: false, reason: 'name_taken' }
  return { ok: true, list: [...list, { variable_key: key, json_schema: { type } }] }
}

/** Where a variable comes from: written by an earlier step (a platform call's writes), or given at the start. */
export function variableSource(graph: DefinitionGraph, key: string): 'step' | 'start' {
  for (const node of graph.nodes) {
    const call = (node.attributes as Record<string, unknown> | undefined)?.platform_call
    const writes = call && typeof call === 'object' ? (call as Record<string, unknown>).writes : undefined
    if (writes && typeof writes === 'object' && key in (writes as Record<string, unknown>)) return 'step'
  }
  return 'start'
}

/** Equal lists (order-insensitive by key) — the dirty check of the variable list. */
export function sameVariables(a: DeclaredVariable[], b: DeclaredVariable[]): boolean {
  const norm = (l: DeclaredVariable[]) => JSON.stringify([...l].sort((x, y) => x.variable_key.localeCompare(y.variable_key)).map((v) => [v.variable_key, v.json_schema]))
  return norm(a) === norm(b)
}
