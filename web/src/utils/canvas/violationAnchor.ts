/**
 * violationAnchor — T-1563. Violations from the server carry only `{code, message}`; this maps each to the node or edge
 * it is about so the diagram can mark it. The existing REQ-431 mapper is tried first; otherwise the message grammar of
 * lib/letflow/definitions/graph.ex is matched (`Node '<id>' ...`, `Edge '<id>' ...`, `Duplicate node ID '<id>'`,
 * `Cycle detected: edge from node '<u>' to node '<v>'`). An id is accepted ONLY if it exists in the current draft graph,
 * so a message can never mark an unrelated or injected id. The full message is always kept.
 */
import type { GraphValidationViolation } from '@/api/definitions'
import type { ValidationError } from '@/components/canvas/ValidationSummaryBar'
import type { DefinitionGraph } from '@/types/api'
import { mapSemanticViolationToValidationError } from './semanticViolationMapping'

const NODE_RES = [/^Node '([^']+)'/, /^Duplicate node ID '([^']+)'/, /^Cycle detected: edge from node '([^']+)'/]
const EDGE_RE = /^Edge '([^']+)'/

export function anchorViolation(v: GraphValidationViolation, graph: DefinitionGraph): ValidationError {
  const nodes = new Set(graph.nodes.map((n) => n.id))
  const edges = new Set(graph.edges.map((e) => e.id))

  const semantic = mapSemanticViolationToValidationError(v)
  if (semantic.nodeId || semantic.edgeId) {
    return {
      ...semantic,
      nodeId: semantic.nodeId && nodes.has(semantic.nodeId) ? semantic.nodeId : undefined,
      edgeId: semantic.edgeId && edges.has(semantic.edgeId) ? semantic.edgeId : undefined,
    }
  }
  const edge = EDGE_RE.exec(v.message)
  if (edge && edges.has(edge[1] as string)) return { edgeId: edge[1], message: v.message, severity: 'error' }
  for (const re of NODE_RES) {
    const m = re.exec(v.message)
    if (m && nodes.has(m[1] as string)) return { nodeId: m[1], message: v.message, severity: 'error' }
  }
  return { message: v.message, severity: 'error' }
}

export const anchorViolations = (vs: GraphValidationViolation[], graph: DefinitionGraph): ValidationError[] =>
  vs.map((v) => anchorViolation(v, graph))
