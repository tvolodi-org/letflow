/** useValidateDraft — T-1563. Live validation of the edit draft with the SERVER's validator (POST /definitions/:id/validate
 *  with the draft graph; nothing is stored). Debounced, one request in flight, and a response for an older draft is
 *  dropped. `useMutation` (no query key). A 422 carries the violations; a network failure leaves Save enabled. */
import { useCallback, useEffect, useRef, useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { definitionsApi, type GraphValidationViolation } from '@/api/definitions'
import type { DefinitionGraph } from '@/types/api'

export const VALIDATE_DEBOUNCE_MS = 700

/** Violation codes that are ADVISORY: the semantic checks (SemanticValidation) are reported by validate only and are not
 *  part of create/update. Every other code (structure, attribute, edge, flow) makes create/update answer 422, so it BLOCKS
 *  a save; classifying by this closed advisory set means a code the client has never seen blocks (fail closed). A test (S7)
 *  checks the set against the `codes` of the fixture cases test/fixtures/process_designer/validation_cases.json, whose
 *  `blocking` flag the backend test B1b checks against Definitions.create. */
export const ADVISORY_CODES: ReadonlySet<string> = new Set(['undeclared_variable_reference', 'incompatible_comparison_operand_types'])

export type DraftCheck =
  | { phase: 'idle' }
  | { phase: 'checking' }
  | { phase: 'valid' }
  | { phase: 'invalid'; violations: GraphValidationViolation[] }
  | { phase: 'failed' }

export const isBlocking = (v: GraphValidationViolation) => !ADVISORY_CODES.has(v.code)

export function useValidateDraft(definitionId: string | undefined, graph: DefinitionGraph, enabled: boolean, delayMs = VALIDATE_DEBOUNCE_MS) {
  const [check, setCheck] = useState<DraftCheck>({ phase: 'idle' })
  const latest = useRef(graph)
  latest.current = graph
  const inFlight = useRef(false)
  const pending = useRef(false)
  const mutation = useMutation({ mutationFn: (g: DefinitionGraph) => definitionsApi.validate(definitionId!, g) })
  const mutateAsync = mutation.mutateAsync

  const run = useCallback(async () => {
    if (!definitionId) return
    if (inFlight.current) {
      pending.current = true
      return
    }
    inFlight.current = true
    const sent = latest.current
    setCheck({ phase: 'checking' })
    let result: DraftCheck
    try {
      await mutateAsync(sent)
      result = { phase: 'valid' }
    } catch (err) {
      const e = err as { status?: number; details?: unknown }
      result = e.status === 422 && Array.isArray(e.details) ? { phase: 'invalid', violations: e.details as GraphValidationViolation[] } : { phase: 'failed' }
    }
    inFlight.current = false
    // A newer draft exists: this answer is about an older graph and is dropped; check the new one.
    if (latest.current !== sent || pending.current) {
      pending.current = false
      void run()
      return
    }
    setCheck(result)
  }, [definitionId, mutateAsync])

  useEffect(() => {
    if (!enabled || !definitionId) return
    const timer = setTimeout(() => void run(), delayMs)
    return () => clearTimeout(timer)
  }, [graph, enabled, definitionId, delayMs, run])

  return { check, recheck: run }
}
