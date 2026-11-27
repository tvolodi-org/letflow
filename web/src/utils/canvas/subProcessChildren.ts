/** subProcessChildren — T-2847 (PILOT-SUB-4). Which ACTIVE definitions a SUB_PROCESS may call, and the mapping
 *  (`interface` attribute) built from the child's declared variables.
 *
 *  The rule is the server's (`Letflow.Engine.SubProcess.refuse_module_only_child`): a definition with
 *  `module_writes` reads its write targets from the start variables, so it is started by its module only. As a
 *  child it needs a parent stamped with the SAME module (`owner_module`); a tenant-made parent gets the answer for
 *  an unknown definition. The picker applies the rule BEFORE save, so the author is told why a process is missing
 *  instead of reading "definition not found" at start. */
import type { DeclaredVariable, DefinitionGraph, ProcessDefinition, SubProcessInterfaceEntry } from '@/types/api'

/** True when any step of the graph carries write targets for a module. */
export function hasModuleWrites(graph: DefinitionGraph | undefined | null): boolean {
  return (graph?.nodes ?? []).some((n) => {
    const w = (n.attributes as Record<string, unknown> | null | undefined)?.module_writes
    return Array.isArray(w) ? w.length > 0 : w !== undefined && w !== null
  })
}

/** Module-only: the definition writes into a module, so only a parent of that module may start it. */
export function isModuleOnly(def: Pick<ProcessDefinition, 'graph'>): boolean {
  return hasModuleWrites(def.graph)
}

export interface ChildChoices {
  /** The definitions this parent may call, by name. */
  callable: ProcessDefinition[]
  /** How many ACTIVE definitions were left out because only their own module may call them. */
  moduleOnly: number
}

export function splitChildren(defs: ProcessDefinition[], parentOwnerModule: string | null | undefined): ChildChoices {
  const callable: ProcessDefinition[] = []
  let moduleOnly = 0
  for (const d of defs) {
    if (d.status !== 'ACTIVE') continue
    if (!isModuleOnly(d) || (!!d.owner_module && d.owner_module === parentOwnerModule)) callable.push(d)
    else moduleOnly += 1
  }
  callable.sort((a, b) => a.name.localeCompare(b.name))
  return { callable, moduleOnly }
}

/** The names the node's `interface` currently passes in and takes back. */
export function mappedNames(iface: unknown): { inputs: Set<string>; outputs: Set<string> } {
  const read = (v: unknown) =>
    new Set(
      Array.isArray(v)
        ? v.flatMap((x) => (x && typeof x === 'object' && typeof (x as { name?: unknown }).name === 'string' ? [(x as { name: string }).name] : []))
        : [],
    )
  const o = iface && typeof iface === 'object' ? (iface as Record<string, unknown>) : {}
  return { inputs: read(o.inputs), outputs: read(o.outputs) }
}

/** One interface entry for a child variable: its declared schema, or an open schema when it declares none. */
export function entryFor(v: DeclaredVariable): SubProcessInterfaceEntry {
  return { name: v.variable_key, json_schema: v.json_schema ?? {}, required: false }
}

/** The `interface` value for the chosen names, in the child's declaration order. */
export function buildInterface(vars: DeclaredVariable[], inputs: Set<string>, outputs: Set<string>) {
  return {
    inputs: vars.filter((v) => inputs.has(v.variable_key)).map(entryFor),
    outputs: vars.filter((v) => outputs.has(v.variable_key)).map(entryFor),
  }
}
