/**
 * DefinitionEditorPage — Visual Process Designer Canvas
 *
 * Integrates ReactFlow canvas, node palette, property panel, validation bar,
 * and save workflow. Replaces the old JSON textarea as the primary editor.
 */

import { useParams, useBlocker } from 'react-router-dom'
import { useState, useRef, useMemo, useCallback, useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { ReactFlowProvider } from '@xyflow/react'
import type { Node, Edge } from '@xyflow/react'

import { useDefinition, useCreateDefinition, useValidateDefinition, useActivateDefinition } from '@/hooks/useDefinitions'
import { definitionsApi } from '@/api/definitions'
import type { GraphValidationViolation } from '@/api/definitions'
import { mapSemanticViolationsToValidationErrors } from '@/utils/canvas/semanticViolationMapping'
import { P, useAccess } from '@/auth/access'
import { useTenantContext } from '@/auth/useTenantContext'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { DefinitionGraph } from '@/types/api'
import type { CanvasNodeData, CanvasEdgeData } from '@/utils/canvas/graphToFlow'
import { graphToFlow } from '@/utils/canvas/graphToFlow'
import { flowToGraph } from '@/utils/canvas/flowToGraph'
import { validateSubProcessInterface } from '@/utils/canvas/interfaceValidation'
import { useCanvasHistoryStore } from '@/stores/canvasHistoryStore'
import { Button } from '@/components/ui/Button'
import { ConfirmPromoteModal } from '@/components/ui/ConfirmPromoteModal'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { useDefinitionDraftStore } from '@/stores/definitionDraftStore'
import { DraftBanner } from '@/components/definitions/DraftBanner'
import type { ApiError } from '@/types/api'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { JsonEditor } from '@/components/ui/JsonEditor'

import ProcessCanvas from '@/components/canvas/ProcessCanvas'
import NodePalette from '@/components/canvas/NodePalette'
import PropertyPanel from '@/components/canvas/PropertyPanel'
import ValidationSummaryBar from '@/components/canvas/ValidationSummaryBar'
import type { ValidationError } from '@/components/canvas/ValidationSummaryBar'
import ReleaseCheckPanel from '@/components/canvas/ReleaseCheckPanel'
import type { ReleaseCheckState } from '@/components/canvas/ReleaseCheckPanel'


// ── Empty starter graph ───────────────────────────────────────────────────────

const EMPTY_GRAPH: DefinitionGraph = {
  nodes: [
    { id: 'start', node_type: 'START', label: null, attributes: null },
    { id: 'end', node_type: 'END', label: null, attributes: null },
  ],
  edges: [{ id: 'e1', source: 'start', target: 'end' }],
}

/**
 * SPC-02 — collect client-side SUB_PROCESS interface validation issues per
 * node. Returns a map of node id -> combined human-readable message for every
 * SUB_PROCESS node whose `interface` attribute fails the structural contract
 * (shape, entry shape, JSON Schema well-formedness, duplicate names). Nodes
 * without an `interface` are skipped (EXT-05 no-contract path is valid).
 */
function collectSubProcessInterfaceErrors(nodes: Node<CanvasNodeData>[]): Map<string, string> {
  const byNode = new Map<string, string>()
  for (const node of nodes) {
    if (node.data.nodeType !== 'SUB_PROCESS') continue
    const issues = validateSubProcessInterface(node.data.attributes?.interface)
    if (issues.length > 0) {
      byNode.set(node.id, issues.map((i) => i.message).join('; '))
    }
  }
  return byNode
}

// ── Page component ────────────────────────────────────────────────────────────

export default function DefinitionEditorPage() {
  const { id } = useParams<{ id?: string }>()
  const isNew = !id
  const { data: def, isLoading, isError, error: defError, refetch } = useDefinition(id!)
  const create = useCreateDefinition()
  const validateDefinition = useValidateDefinition()
  const activateMutation = useActivateDefinition()
  const { tenantType, productionDisplayName, tenantId } = useTenantContext()
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()

  const [name, setName] = useState('')
  const [version, setVersion] = useState('1.0.0')
  const [description, setDescription] = useState('')
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showRawJson, setShowRawJson] = useState(false)
  const [exportError, setExportError] = useState<string | null>(null)
  const [exporting, setExporting] = useState(false)
  const [showPromoteModal, setShowPromoteModal] = useState(false)
  const [promoting, setPromoting] = useState(false)
  const [promoteMessage, setPromoteMessage] = useState<string | null>(null)
  const [promoteError, setPromoteError] = useState<string | null>(null)

  const hasDesignerRole = useAccess().can(P.DefinitionsWrite)

  // ── Canvas state ────────────────────────────────────────────────────────────

  const [dirty, setDirty] = useState(false)
  const [validationErrors, setValidationErrors] = useState<ValidationError[]>([])
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [selectedNodeData, _setSelectedNodeData] = useState<CanvasNodeData | undefined>(undefined)
  const [selectedEdgeId, setSelectedEdgeId] = useState<string | null>(null)
  const [paletteAddCounter, setPaletteAddCounter] = useState(0)
  const [paletteAddNodeType, setPaletteAddNodeType] = useState<string | null>(null)

  // ── Undo/redo triggers ──────────────────────────────────────────────────────
  const [undoCounter, setUndoCounter] = useState(0)
  const [redoCouter, setRedoCounter] = useState(0)
  const undoTrigger = useMemo(() => ({ counter: undoCounter }), [undoCounter])
  const redoTrigger = useMemo(() => ({ counter: redoCouter }), [redoCouter])

  // ── Auto-layout trigger ─────────────────────────────────────────────────────
  const [autoLayoutCounter, setAutoLayoutCounter] = useState(0)
  const autoLayoutTrigger = useMemo(() => ({ counter: autoLayoutCounter }), [autoLayoutCounter])

  // ── Condition errors from server-side validation ────────────────────────────
  const [conditionErrors, setConditionErrors] = useState<Map<string, string>>(new Map())

  // ── REQ-431 §5.2: save-time snapshot of REQ-372's server-side semantic
  // violations. A SEPARATE state slot from validationErrors (the client-side
  // heuristics recomputed on every canvas-state change) -- the backend call
  // is not cheap/instant, so it is only refreshed on an explicit save, never
  // on every keystroke.
  const [serverValidationErrors, setServerValidationErrors] = useState<ValidationError[]>([])

  // ── REQ-431 §6: release-submission re-check surface, independent of
  // serverValidationErrors -- this is what makes AC5's "fresh vs stale"
  // distinction structural rather than something the author has to notice.
  const [releaseCheck, setReleaseCheck] = useState<ReleaseCheckState>({ phase: 'idle' })

  // ── RND-UI-06: 409 conflict + draft retention state ─────────────────────────
  const [saveConflict, setSaveConflict] = useState<ApiError | null>(null)
  const draftStore = useDefinitionDraftStore()
  const currentDraft = !isNew && id ? draftStore.draft : null

  // Ref to hold current canvas nodes/edges for serialization (filled by ProcessCanvas)
  const canvasStateRef = useRef<{ nodesJSON: string; edgesJSON: string } | null>(null)

  // Graph data
  const currentGraph = def?.graph ?? EMPTY_GRAPH
  const isReadOnly = !isNew && def?.status !== 'DRAFT' && def?.status !== undefined

  // Convert API graph → React Flow on definition load. Computed ONCE here and
  // reused everywhere else in this component that needs the "as-stored"
  // graph shape (ProcessCanvas's own `initialNodes`/`initialEdges` props
  // below, and the draft-mirror effect's own-graph comparison next) --
  // `graphToFlow`'s `nextPosition()` fallback for a node with no stored
  // `position` attribute is a shared, incrementing module-level counter, so
  // two INDEPENDENT calls against the same input graph do not necessarily
  // produce the same synthesized positions. A second call was exactly what
  // the draft-mirror effect used to do (see its own comment below).
  const { nodes: initialNodes, edges: initialEdges } = useMemo(
    () => graphToFlow(currentGraph),
    [currentGraph],
  )

  // Mirror the editor's current draft body into the Zustand store whenever
  // the canvas state mutates. The editor never reads XRV directly; it only
  // reads the draft (per §2.4 binding rule 1).
  //
  // Bug fix (found while getting REQ-431's own e2e spec to run reliably
  // against a real browser -- unrelated to REQ-431 itself, flagged for
  // REVIEWER): this effect used to compare a freshly `flowToGraph`-serialised
  // live-canvas graph (which always injects a `position` attribute per node)
  // against `def.graph` AS STORED BY THE SERVER (whose node `attributes` is
  // `null` for a definition created without position data, e.g. via a plain
  // API call). Those two shapes never compared equal even with zero actual
  // edits, so `dirtyKeys` was non-empty on literally every run of this
  // effect -- which (since `draftStore` is the whole Zustand state object,
  // a fresh reference on every `setDraft` call) re-triggered the effect
  // continuously: a real, reproducible "Maximum update depth exceeded"
  // warning loop for any existing definition with no explicit stored node
  // positions. Comparing against `flowToGraph(initialNodes, initialEdges)`
  // instead -- the SAME round-trip the live canvas itself started from --
  // makes both sides of the comparison apples-to-apples, so an unedited
  // graph now correctly compares equal.
  useEffect(() => {
    if (isNew || !id) return
    const state = canvasStateRef.current
    if (!state) return
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      const graph = flowToGraph(nodes, edges)
      const storedGraphRoundTrip = flowToGraph(initialNodes, initialEdges)
      const dirtyKeys: string[] = []
      if (description !== (def?.description ?? '')) dirtyKeys.push('description')
      if (graph && JSON.stringify(graph) !== JSON.stringify(storedGraphRoundTrip)) {
        dirtyKeys.push('graph')
      }
      if (dirtyKeys.length === 0) return
      draftStore.setDraft({
        definitionId: id,
        body: { name: def?.name ?? '', version: def?.version ?? '', description, graph },
        dirtyFieldKeys: dirtyKeys,
        savedAt: draftStore.draft?.savedAt ?? null,
      })
    } catch {
      /* graph parsing failure: don't write a partial draft */
    }
  }, [description, isNew, id, def?.description, def?.name, def?.version, initialNodes, initialEdges, draftStore])

  const handleSaveMerged = async (
    mergedBody: Record<string, unknown>,
    version: string,
  ): Promise<void> => {
    // PD-08: send the version stamp as a body field (backend convention TBD
    // — see design §2.3 OQ-3). For the PATCH path we pass it via the If-Match
    // header equivalent — the backend's PATCH currently consumes the
    // `version` field on the body for optimistic concurrency, falling back
    // to the header on a future release.
    void version
    if (!id) return
    try {
      await definitionsApi.update(id, {
        name: (mergedBody['name'] as string | undefined) ?? def?.name ?? '',
        version: (mergedBody['version'] as string | undefined) ?? def?.version ?? '',
        description: (mergedBody['description'] as string | undefined) ?? def?.description ?? undefined,
        graph: (mergedBody['graph'] as DefinitionGraph | undefined) ?? def?.graph,
        stage: null,
      } as Partial<Parameters<typeof definitionsApi.update>[1]> & { version?: string })
      draftStore.setDraft({
        definitionId: id,
        body: mergedBody,
        dirtyFieldKeys: [],
        savedAt: new Date().toISOString(),
      })
      setSaveConflict(null)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
      void refetch()
    } catch (e: unknown) {
      setError((e as { message?: string }).message ?? 'Merge save failed')
    }
  }

  const handleDiscardConfirmed = (): void => {
    if (id) draftStore.clearDraft(id)
    setSaveConflict(null)
    void refetch()
  }

  // Build a node name map for the property panel
  const nodeNames = useMemo(() => {
    const map = new Map<string, string>()
    for (const gn of currentGraph.nodes) {
      map.set(gn.id, gn.label || gn.node_type)
    }
    return map
  }, [currentGraph])
  // ── Promote to Production handler ───────────────────────────────────────────

  async function handlePromoteConfirm() {
    if (!def?.name || !tenantId) return
    setPromoting(true)
    setPromoteError(null)
    try {
      await definitionsApi.promote(tenantId, def.name)
      setShowPromoteModal(false)
      qc.invalidateQueries({ queryKey: tenantKeys.definitions.all() })
      setPromoteMessage('Definition promoted. A DRAFT version is now available in production.')
      setTimeout(() => setPromoteMessage(null), 4000)
    } catch (e: unknown) {
      const err = e as { code?: string; message?: string }
      const codeMap: Record<string, string> = {
        not_a_test_tenant: 'This operation requires a test tenant.',
        production_tenant_inactive: 'The paired production tenant is inactive. Contact your platform administrator.',
        forbidden: 'You do not have the required role on both tenants.',
      }
      setPromoteError(err.code ? (codeMap[err.code] ?? 'Promotion failed. Please try again.') : 'Promotion failed. Please try again.')
    } finally {
      setPromoting(false)
    }
  }
  // ── Export handler ──────────────────────────────────────────────────────────

  async function handleExport() {
    if (!def?.id || isNew) return
    setExportError(null)
    setExporting(true)
    try {
      const exportData = await definitionsApi.exportJson(def.id)
      const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `definition-${def.name}-${def.version}.json`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
    } catch (err: unknown) {
      const apiErr = err as { status?: number; message?: string }
      if (apiErr.status === 404) {
        setExportError('Definition not found')
      } else {
        setExportError(apiErr.message ?? 'Export failed')
      }
    } finally {
      setExporting(false)
    }
  }

  // ── Save handler ────────────────────────────────────────────────────────────

  async function handleSave() {
    setError(null)
    setConditionErrors(new Map())
    // REQ-431 §5.2: a fresh save always starts from a clean server-error
    // slate -- an edit since the last save may have already fixed what it
    // was reporting, and this save's own validate call below is the only
    // thing allowed to repopulate it.
    setServerValidationErrors([])

    const state = canvasStateRef.current
    if (!state) {
      setError('Canvas not ready.')
      return
    }

    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)

      // SPC-02 / PD-UI-14 — block save until every SUB_PROCESS `interface`
      // contract is clean. Re-read from the live canvas state (not the
      // possibly-stale validationErrors render value) so an in-flight edit
      // cannot slip through to the backend's HTTP 422.
      const ifaceErrors = collectSubProcessInterfaceErrors(nodes)
      if (ifaceErrors.size > 0) {
        const first = [...ifaceErrors.entries()][0]
        setError(`Fix validation errors before saving: SUB_PROCESS "${first[0]}" interface — ${first[1]}`)
        return
      }

      const graph = flowToGraph(nodes, edges)

      let savedId = id
      if (isNew) {
        const created = await create.mutateAsync({ name, version, description, graph })
        savedId = created.id
      } else {
        await definitionsApi.update(id!, { name: def!.name, version: def!.version, description: def!.description ?? undefined, graph, stage: null })
      }

      // Clear undo history on successful save
      useCanvasHistoryStore.getState().clear()
      setDirty(false)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)

      // REQ-431 §5.1: call validate on the STORED graph, after the save
      // resolved (validate_definition_graph/2 reads the persisted definition,
      // not what's still in the canvas) -- this call is what actually presents
      // REQ-372's server-side semantic violations, not just client heuristics.
      if (savedId) {
        try {
          await validateDefinition.mutateAsync(savedId)
          setServerValidationErrors([])
        } catch (validateErr: unknown) {
          const vErr = validateErr as { status?: number; details?: unknown }
          if (vErr.status === 422 && Array.isArray(vErr.details)) {
            const mapped = mapSemanticViolationsToValidationErrors(
              vErr.details as GraphValidationViolation[],
            )
            setServerValidationErrors(mapped)
            // §4.3 — reuse the existing node-highlight mechanism (SPC-02
            // precedent). Multiple violations against the same node id
            // concatenate onto that node's one-message-per-node string.
            const byNode = new Map<string, string[]>()
            for (const v of mapped) {
              if (!v.nodeId) continue
              const existing = byNode.get(v.nodeId) ?? []
              existing.push(v.message)
              byNode.set(v.nodeId, existing)
            }
            if (byNode.size > 0) {
              const updates: Record<string, string | null> = {}
              for (const [nodeId, messages] of byNode) {
                updates[nodeId] = messages.join('; ')
              }
              dispatchNodeValidation(updates)
            }
          }
          // A non-422/non-violation validate failure is not surfaced as a
          // save error — save itself already succeeded; the validate call
          // is a best-effort re-check, not part of the save's own success.
        }
      }
    } catch (e: unknown) {
      const err = e as { status?: number; details?: Record<string, unknown>; message?: string }
      if (err.status === 409) {
        // RND-UI-06: surface ConflictResolver via QueryStateBoundary.
        setSaveConflict(err as ApiError)
        return
      }
      // Parse RFC 9457 Problem Details for condition errors
      if (err.details && typeof err.details === 'object') {
        const rawDetails = err.details
        const detailArr = Array.isArray(rawDetails) ? (rawDetails as Array<{ loc?: string; message?: string }>) : []
        if (detailArr.length > 0) {
          const errors = new Map<string, string>()
          for (const d of detailArr) {
            if (d.loc && d.loc.includes('condition')) {
              errors.set(d.loc, d.message ?? 'Invalid condition')
            }
          }
          if (errors.size > 0) setConditionErrors(errors)
        }
      }
      setError(err instanceof SyntaxError ? 'Invalid graph data' : (err.message ?? 'Save failed'))
    }
  }

  // ── Validation logic ────────────────────────────────────────────────────────

  useEffect(() => {
    const state = canvasStateRef.current
    if (!state) {
      setValidationErrors([])
      return
    }
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      const errors: ValidationError[] = []

      const hasStart = nodes.some((n) => n.data.nodeType === 'START')
      const hasEnd = nodes.some((n) => n.data.nodeType === 'END')

      if (!hasStart) {
        errors.push({ message: 'Graph must contain a START node.', severity: 'warning' })
      }
      if (!hasEnd) {
        errors.push({ message: 'Graph must contain an END node.', severity: 'warning' })
      }

      // Check for unnamed nodes (except START/END)
      for (const node of nodes) {
        if (node.data.nodeType !== 'START' && node.data.nodeType !== 'END' && !node.data.name?.trim()) {
          errors.push({
            nodeId: node.id,
            message: `${node.data.nodeType.replace(/_/g, ' ')} node "${node.id}" has no name.`,
            severity: 'warning',
          })
        }
        // Check EXCLUSIVE_GATEWAY has at least 2 outgoing edges
        if (node.data.nodeType === 'EXCLUSIVE_GATEWAY') {
          const outgoing = edges.filter((e) => e.source === node.id)
          if (outgoing.length < 2) {
            errors.push({
              nodeId: node.id,
              message: `EXCLUSIVE_GATEWAY "${node.id}" should have at least 2 outgoing edges.`,
              severity: 'warning',
            })
          }
        }
      }

      // SPC-02 — client-side SUB_PROCESS interface contract validation
      // (mirrors the backend 422 rule). Issues are error-severity: they surface
      // in the validation summary bar (PD-UI-13) and block save (PD-UI-14).
      const interfaceErrors = collectSubProcessInterfaceErrors(nodes)
      for (const [nodeId, message] of interfaceErrors) {
        errors.push({
          nodeId,
          message: `SUB_PROCESS "${nodeId}" interface: ${message}`,
          severity: 'error',
        })
      }

      // Surface interface issues inline on the offending nodes (PD-UI-13) via
      // the dedicated validation trigger. Only dispatch when the computed
      // error differs from the node's current `validationError`, so the update
      // loop converges instead of re-dispatching forever.
      const validationUpdates: Record<string, string | null> = {}
      for (const node of nodes) {
        if (node.data.nodeType !== 'SUB_PROCESS') continue
        const target = interfaceErrors.get(node.id) ?? null
        const current = (node.data.validationError as string | undefined) ?? null
        if (target !== current) validationUpdates[node.id] = target
      }
      if (Object.keys(validationUpdates).length > 0) {
        dispatchNodeValidation(validationUpdates)
      }

      setValidationErrors(errors)
    } catch {
      setValidationErrors([])
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canvasStateRef.current, dirty])

  // ── Keyboard shortcuts (Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y) ───────────────────

  useEffect(() => {
    const handler = (e: globalThis.KeyboardEvent) => {
      if (isReadOnly) return
      if ((e.ctrlKey || e.metaKey) && e.key === 'z' && !e.shiftKey) {
        e.preventDefault()
        setUndoCounter((c) => c + 1)
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 'z' && e.shiftKey) {
        e.preventDefault()
        setRedoCounter((c) => c + 1)
      }
      if ((e.ctrlKey || e.metaKey) && e.key === 'y') {
        e.preventDefault()
        setRedoCounter((c) => c + 1)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [isReadOnly])

  // ── Clear history on definition change ──────────────────────────────────────

  useEffect(() => {
    useCanvasHistoryStore.getState().clear()
  }, [id])

  // ── Unsaved changes guard ───────────────────────────────────────────────────

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      dirty && currentLocation.pathname !== nextLocation.pathname,
  )

  const handleDiscardAndProceed = useCallback(() => {
    if (blocker.state === 'blocked') {
      setDirty(false)
      blocker.proceed()
    }
  }, [blocker])

  const handleCancelNavigation = useCallback(() => {
    if (blocker.state === 'blocked') {
      blocker.reset()
    }
  }, [blocker])

  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (dirty) {
        e.preventDefault()
        e.returnValue = ''
      }
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [dirty])

  // ── Palette add-node via double-click ──────────────────────────────────────

  const handleAddNodeFromPalette = useCallback((nodeType: import('@/types/api').NodeType) => {
    if (isReadOnly) return
    setPaletteAddNodeType(nodeType)
    setPaletteAddCounter((c) => c + 1)
  }, [isReadOnly])

  const paletteAddTrigger = useMemo(() => {
    if (paletteAddCounter === 0 || !paletteAddNodeType) return undefined
    return { counter: paletteAddCounter, nodeType: paletteAddNodeType }
  }, [paletteAddCounter, paletteAddNodeType])


  // ── Node update trigger (PropPanel → ProcessCanvas) ───────────────────────

  const [nodeUpdateTrigger, setNodeUpdateTrigger] = useState<{
    nodeId: string
    data: Partial<CanvasNodeData>
    counter: number
  } | null>(null)
  const nodeUpdateCounterRef = useRef(0)

  // ── Node validation-error trigger (SPC-02 SUB_PROCESS interface) ─────────
  // Separate from nodeUpdateTrigger so inline validation annotations never
  // pollute the undo snapshot stack (they are derived, not user actions).

  const [nodeValidationTrigger, setNodeValidationTrigger] = useState<{
    updates: Record<string, string | null>
    counter: number
  } | null>(null)
  const nodeValidationCounterRef = useRef(0)

  const dispatchNodeValidation = useCallback((updates: Record<string, string | null>) => {
    nodeValidationCounterRef.current += 1
    setNodeValidationTrigger({ updates, counter: nodeValidationCounterRef.current })
  }, [])

  // ── Property panel callbacks ────────────────────────────────────────────────

  const handleUpdateNode = useCallback(
    (nodeId: string, data: Partial<CanvasNodeData>) => {
      setDirty(true)
      nodeUpdateCounterRef.current += 1
      setNodeUpdateTrigger({ nodeId, data, counter: nodeUpdateCounterRef.current })
    },
    [setDirty],
  )

  const handleDeleteEdge = useCallback(
    (_edgeId: string) => { setDirty(true); void _edgeId; },
    [setDirty],
  )

  // ── REQ-431 §6.3: release-submission re-check handler ───────────────────────
  // Distinct from handleSave's post-save `validate` call -- EO-005's whole
  // point is that this is a FRESH re-check run at submission time, never
  // reusing a stale save-time result even when that result was clean.
  async function handleSubmitForRelease() {
    if (!id) return
    setReleaseCheck({ phase: 'checking' })
    try {
      await activateMutation.mutateAsync(id)
      setReleaseCheck({ phase: 'clean', checkedAt: new Date().toISOString() })
    } catch (e: unknown) {
      const err = e as { status?: number; details?: unknown; message?: string }
      if (err.status === 422 && Array.isArray(err.details)) {
        setReleaseCheck({
          phase: 'blocked',
          checkedAt: new Date().toISOString(),
          violations: mapSemanticViolationsToValidationErrors(err.details as GraphValidationViolation[]),
        })
      } else {
        setReleaseCheck({
          phase: 'error',
          checkedAt: new Date().toISOString(),
          message: err.message ?? 'Release check failed',
        })
      }
    }
  }

  // ── Build current graph JSON for the raw JSON drawer ────────────────────────

  const currentGraphJson = useMemo(() => {
    const state = canvasStateRef.current
    if (!state) return JSON.stringify(EMPTY_GRAPH, null, 2)
    try {
      const nodes: Node<CanvasNodeData>[] = JSON.parse(state.nodesJSON)
      const edges: Edge<CanvasEdgeData>[] = JSON.parse(state.edgesJSON)
      return JSON.stringify(flowToGraph(nodes, edges), null, 2)
    } catch {
      return JSON.stringify(EMPTY_GRAPH, null, 2)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canvasStateRef.current, validationErrors])

  // ── Loading state via QueryStateBoundary — no early return needed ───────────
  const rendererState: RendererState = saveConflict
    ? 'stale-version'
    : (!isNew && isLoading)
      ? 'loading'
      : (!isNew && isError)
        ? classifyError(defError)
        : 'success'

  // ── Get selected node/edge for property panel from canvas ───────────────────
  // These are managed inside ProcessCanvas, but we pass them down via props
  // and get changes back via callbacks

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        height: '100%',
        background: 'var(--surface-page)',
      }}
    >
      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(defError) : undefined
        }
        staleVersionError={saveConflict ?? undefined}
        staleVersionServerPayload={
          saveConflict ? ((saveConflict.details as Record<string, unknown>) ?? {}) : undefined
        }
        staleVersionLocalDraft={currentDraft?.body}
        staleVersionOnSaveMerged={handleSaveMerged}
        staleVersionOnDiscardConfirmed={handleDiscardConfirmed}
        columns={[{ widthPercent: 100 }]}
      >
      {/* ── Toolbar ─────────────────────────────────────────────── */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '8px 16px',
          background: 'var(--surface-card)',
          borderBottom: '1px solid var(--border-default)',
          gap: 12,
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <h2 style={{ margin: 0, fontSize: 'var(--text-lg)', fontWeight: 600, color: 'var(--text-primary)' }}>
            {isNew ? 'New Definition' : def?.name ?? 'Process Designer'}
          </h2>
          {isNew && <StatusBadge status="DRAFT" domain="definition" size="sm" />}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {hasDesignerRole && !isNew && (
            <Button
              variant="secondary"
              size="sm"
              data-testid="btn-export-definition"
              onClick={handleExport}
              disabled={exporting}
            >
              {exporting ? 'Exporting…' : 'Export'}
            </Button>
          )}
          {hasDesignerRole && !isNew && tenantType === 'test' && def?.status === 'ACTIVE' && (
            <Button
              variant="secondary"
              size="sm"
              data-testid="promote-to-production-btn"
              onClick={() => { setPromoteError(null); setShowPromoteModal(true) }}
            >
              Promote to Production
            </Button>
          )}
          {!isReadOnly && (
            <>
              <Button
                variant="secondary"
                size="sm"
                data-testid="btn-show-raw-json"
                onClick={() => setShowRawJson(!showRawJson)}
                pressed={showRawJson}
              >
                {showRawJson ? 'Hide Raw JSON' : 'Show Raw JSON'}
              </Button>
              <Button
                variant="secondary"
                size="sm"
                data-testid="btn-auto-layout"
                onClick={() => setAutoLayoutCounter((c) => c + 1)}
                title="Auto-arrange nodes using Dagre layout"
              >
                Re-layout
              </Button>
              <Button
                variant="primary"
                size="sm"
                data-testid="btn-save-definition"
                onClick={handleSave}
                loading={create.isPending}
                // REQ-431 correction: the design's own §5.2 literal wording
                // ("Save ... must also gate on serverValidationErrors") would
                // deadlock the repeat-save case the scenario's own step 3
                // requires ("fix one rule, save again, second rule's
                // violation still shown") -- serverValidationErrors is only
                // ever cleared at the TOP of handleSave itself (§5.2's own
                // "clear it unconditionally at the TOP of handleSave" rule),
                // so gating Save on it would make Save permanently
                // unclickable the instant one server violation appears, with
                // no path to ever clear it. Save stays gated on
                // validationErrors (client-side heuristics) only, unchanged
                // from pre-REQ-431 behavior; serverValidationErrors instead
                // gates "Submit for Release" below, where it is not
                // load-bearing (the real EO-002 enforcement is server-side,
                // §6.4) and cannot deadlock the same way.
                disabled={create.isPending || validationErrors.some((e) => e.severity === 'error')}
                title={
                  validationErrors.some((e) => e.severity === 'error')
                    ? 'Fix validation errors before saving.'
                    : undefined
                }
              >
                {create.isPending ? 'Saving…' : 'Save'}
              </Button>
            </>
          )}
          {/* REQ-431 §6.1: "Submit for Release" — DRAFT-only, existing
              definitions only (mirrors DefinitionListPage's own Activate
              gating). Deliberately on this same screen so the scenario's
              steps 1/3/4/5 all stay on one continuous screen. */}
          {!isNew && def?.status === 'DRAFT' && (
            <Button
              variant="primary"
              size="sm"
              data-testid="btn-submit-for-release"
              onClick={() => { void handleSubmitForRelease() }}
              loading={releaseCheck.phase === 'checking'}
              disabled={
                releaseCheck.phase === 'checking' ||
                validationErrors.some((e) => e.severity === 'error') ||
                serverValidationErrors.some((e) => e.severity === 'error')
              }
              title={
                validationErrors.some((e) => e.severity === 'error') ||
                serverValidationErrors.some((e) => e.severity === 'error')
                  ? 'Fix validation errors before submitting for release.'
                  : undefined
              }
            >
              {releaseCheck.phase === 'checking' ? 'Checking…' : 'Submit for Release'}
            </Button>
          )}
          {isReadOnly && (
            <span
              data-testid="read-only-banner"
              style={{
                fontSize: 'var(--text-sm)',
                color: 'var(--color-warning-dark)',
                background: 'var(--color-warning-light)',
                padding: '4px 12px',
                borderRadius: 4,
              }}
            >
              Read-only — {def?.status ?? 'UNKNOWN'} status
            </span>
          )}
        </div>
      </div>

      {/* ── Error/success banners ──────────────────────────────── */}
      {currentDraft && !saveConflict && (
        <DraftBanner
          draft={currentDraft}
          onApply={() => {
            // Re-apply the draft body into the editor fields. The canvas
            // body is read-only here — the user can re-edit then Save.
            if (currentDraft.body['description']) {
              setDescription(String(currentDraft.body['description']))
            }
          }}
          onDiscard={() => {
            if (id) draftStore.clearDraft(id)
          }}
        />
      )}

      {error && (
        <div
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light)',
            color: 'var(--color-error-dark)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--color-error)',
          }}
        >
          {error}
        </div>
      )}

      {exportError && (
        <div
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light)',
            color: 'var(--color-error-dark)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--color-error)',
          }}
        >
          {exportError}
        </div>
      )}

      {saved && (
        <div
          data-testid="save-success-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-success-light)',
            color: 'var(--color-success-dark)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--color-success)',
          }}
        >
          Definition saved.
        </div>
      )}

      {promoteMessage && (
        <div
          data-testid="promote-success-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-success-light)',
            color: 'var(--color-success-dark)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--color-success)',
          }}
        >
          {promoteMessage}
        </div>
      )}

      {promoteError && (
        <div
          data-testid="promote-error-toast"
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light)',
            color: 'var(--color-error-dark)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--color-error)',
          }}
        >
          {promoteError}
        </div>
      )}

      {/* ── New definition metadata (create mode) ───────────────── */}
      {isNew && (
        <div
          style={{
            padding: '12px 16px',
            background: 'var(--surface-card)',
            borderBottom: '1px solid var(--border-default)',
            display: 'flex',
            gap: 12,
            flexWrap: 'wrap',
          }}
        >
          <div style={{ flex: 2, minWidth: 200 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary)' }}>
              Name
            </label>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Definition name"
              style={inlineInputStyle}
            />
          </div>
          <div style={{ flex: 1, minWidth: 100 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary)' }}>
              Version
            </label>
            <input
              value={version}
              onChange={(e) => setVersion(e.target.value)}
              style={{ ...inlineInputStyle, maxWidth: 120 }}
            />
          </div>
          <div style={{ flex: 3, minWidth: 200 }}>
            <label style={{ display: 'block', fontSize: 'var(--text-xs)', fontWeight: 500, marginBottom: 2, color: 'var(--text-secondary)' }}>
              Description
            </label>
            <input
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Optional description"
              style={inlineInputStyle}
            />
          </div>
        </div>
      )}

      {/* ── Main layout: Palette | Canvas | Property Panel ─────── */}
      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        <ReactFlowProvider>
          <NodePalette isReadOnly={isReadOnly} onAddNode={handleAddNodeFromPalette} />

          <div style={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column' }}>
            <ProcessCanvas
              definitionId={id ?? ''}
              initialNodes={initialNodes}
              initialEdges={initialEdges}
              isReadOnly={isReadOnly}
              onDirtyChange={setDirty}
              canvasStateRef={canvasStateRef}
              onSelectedNodeChange={(id, nodeData) => { setSelectedNodeId(id); if (nodeData !== undefined) _setSelectedNodeData(nodeData) }}
              onSelectedEdgeChange={setSelectedEdgeId}
              paletteAddTrigger={paletteAddTrigger}
              nodeUpdateTrigger={nodeUpdateTrigger}
              nodeValidationTrigger={nodeValidationTrigger}
              autoLayoutTrigger={autoLayoutTrigger}
              undoTrigger={undoTrigger}
              redoTrigger={redoTrigger}
              conditionErrors={conditionErrors}
            />

            {/* Raw JSON drawer */}
            {showRawJson && (
              <div
                data-testid="raw-json-drawer"
                style={{
                  borderTop: '1px solid var(--border-default)',
                  background: 'var(--surface-card)',
                  padding: '6px 16px',
                }}
              >
                <JsonEditor
                  value={currentGraphJson}
                  onChange={() => {}}
                  label="Raw Graph JSON (debug)"
                  readOnly
                  height={160}
                />
              </div>
            )}

            <ReleaseCheckPanel state={releaseCheck} />
            <ValidationSummaryBar errors={[...validationErrors, ...serverValidationErrors]} />
          </div>

          <PropertyPanel
            selectedNodeId={selectedNodeId}
            selectedNodeData={selectedNodeData}
            selectedEdgeId={selectedEdgeId}
            nodeNames={nodeNames}
            onUpdateNode={handleUpdateNode}
            onDeleteEdge={handleDeleteEdge}
            onClose={() => {
              setSelectedNodeId(null)
              setSelectedEdgeId(null)
            }}
            isReadOnly={isReadOnly}
          />
        </ReactFlowProvider>
      </div>

      {/* ── Unsaved changes dialog ────────────────────────────── */}
      {blocker.state === 'blocked' && (
        <div
          data-testid="unsaved-changes-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            background: 'var(--surface-overlay)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
        >
          <div
            style={{
              background: 'var(--surface-card)',
              borderRadius: 8,
              padding: 24,
              minWidth: 360,
              maxWidth: 440,
              boxShadow: 'var(--shadow-lg)',
            }}
          >
            <h3
              style={{
                margin: '0 0 8px',
                fontSize: 'var(--text-lg)',
                fontWeight: 600,
                color: 'var(--text-primary)',
              }}
            >
              Unsaved Changes
            </h3>
            <p
              style={{
                margin: '0 0 20px',
                fontSize: 'var(--text-sm)',
                color: 'var(--text-secondary)',
              }}
            >
              You have unsaved changes. Do you want to discard them?
            </p>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
              <Button variant="secondary" size="sm" onClick={handleCancelNavigation}>
                Stay
              </Button>
              <Button variant="danger" size="sm" data-testid="unsaved-discard" onClick={handleDiscardAndProceed}>
                Discard
              </Button>
            </div>
          </div>
        </div>
      )}

      {showPromoteModal && def && (
        <ConfirmPromoteModal
          definitionName={def.name}
          productionDisplayName={productionDisplayName ?? '(unknown)'}
          onConfirm={() => void handlePromoteConfirm()}
          onCancel={() => setShowPromoteModal(false)}
          isLoading={promoting}
        />
      )}
      </QueryStateBoundary>
    </div>
  )
}

// ── Helper styles ─────────────────────────────────────────────────────────────

const inlineInputStyle: React.CSSProperties = {
  width: '100%',
  padding: '6px 8px',
  border: '1px solid var(--border-default)',
  borderRadius: 4,
  fontSize: 'var(--text-sm)',
  boxSizing: 'border-box',
}
