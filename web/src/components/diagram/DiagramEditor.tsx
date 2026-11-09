/** DiagramEditor — T-1563 (D-114 item 2, slice 2). Edit mode of the process diagram. The edit model IS the
 *  DefinitionGraph (`useDiagramDraft` + `graphEdit`): nothing here keeps a second canvas model. React Flow runs
 *  controlled from the draft; a drag, a connection or a delete becomes a graphEdit call. Keyboard: Tab to a step and
 *  Enter opens its panel, Alt+Arrow nudges (Shift = far), Delete removes the selection, Ctrl/Cmd+Z and +Shift+Z (or
 *  Ctrl+Y) undo and redo, Escape closes the panel; the panel's "Connect from this step" needs no pointer. Every action
 *  is announced in an aria-live region. Under the narrow width the canvas is replaced by an editable step list. */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { Background, Controls, ReactFlow, ReactFlowProvider, type AriaLabelConfig, type Connection, type NodeChange } from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import '@/styles/process-diagram.css'
import type { GraphValidationViolation } from '@/api/definitions'
import type { DefinitionGraph, NodeType } from '@/types/api'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import type { DiagramDraft } from '@/hooks/useDiagramDraft'
import { isBlocking, type DraftCheck } from '@/hooks/useValidateDraft'
import { addNode, connect, connectionRefusal, deleteEdges, deleteNodes, moveNode, positionOf, readAttrs, MAX_NODES, type EditRefusal, type EditResult } from '@/utils/canvas/graphEdit'
import { dragCoalescer } from '@/utils/canvas/editHistory'
import { anchorViolations } from '@/utils/canvas/violationAnchor'
import { nodeDims } from '@/utils/canvas/readLayout'
import { diagramConfig } from './diagramConfig'
import { summariseNode } from './nodeSummary'
import { DiagramNode, type DiagramFlowNode } from './DiagramNode'
import { DiagramEdge, cutLabel, type DiagramFlowEdge } from './DiagramEdge'
import { EditToolbar, type EditToolbarProps } from './EditToolbar'
import { EdgeEditPanel, NodeEditPanel, nodeName, useEditText, type ApplyEdit } from './NodeEditPanel'
import { useContainerWidth } from './ProcessDiagram'
import { readingOrder } from './StepsList'
import { useDiagramText } from './useDiagramText'

const nodeTypes = { diagram: DiagramNode }
const edgeTypes = { diagram: DiagramEdge }
const PRO_OPTIONS = { hideAttribution: true }
const FIT_VIEW_OPTIONS = { padding: 0.12, maxZoom: 1 }
const NUDGE = 16
const NUDGE_FAR = 64

export interface DiagramEditorProps {
  draft: DiagramDraft
  violations: GraphValidationViolation[]
  check: DraftCheck
  toolbar: Pick<EditToolbarProps, 'onSave' | 'onDiscard' | 'saving' | 'saveBlockedReason' | 'saveLabel'>
  /** A step or connection selected on first render (its panel open); used by the screen harness. */
  initialSelected?: Sel
}

export type Sel = { kind: 'node' | 'edge'; id: string } | null

const isTyping = (t: EventTarget | null) => t instanceof HTMLElement && (['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName) || t.isContentEditable)

export default function DiagramEditor(props: DiagramEditorProps) {
  return (
    <ReactFlowProvider>
      <DiagramEditorInner {...props} />
    </ReactFlowProvider>
  )
}

function DiagramEditorInner({ draft, violations, check, toolbar, initialSelected }: DiagramEditorProps) {
  const intl = useIntl()
  const e = useEditText()
  const t = useDiagramText()
  const graph = draft.graph
  const [containerRef, width] = useContainerWidth()
  const narrow = width < diagramConfig.narrowWidth
  const tooBig = graph.nodes.length > diagramConfig.hugeGraphNodes
  const [sel, setSel] = useState<Sel>(initialSelected ?? null)
  const [addType, setAddType] = useState<NodeType>('HUMAN_TASK')
  const [live, setLive] = useState('')

  // A selection that no longer exists (deleted, undone) closes the panel.
  useEffect(() => {
    if (sel && !(sel.kind === 'node' ? graph.nodes.some((n) => n.id === sel.id) : graph.edges.some((x) => x.id === sel.id))) setSel(null)
  }, [graph, sel])

  const announce = useCallback((msg: string) => setLive(msg), [])
  const refusalText = useCallback((r: EditRefusal) => e(`refusal.${r}`), [e])

  /** Applies a graphEdit result; a refusal is announced and shown, never silent. */
  const apply: ApplyEdit = useCallback(
    (result: EditResult, msg?: string, coalesceKey?: string) => {
      const refusal = draft.apply(result, coalesceKey)
      if (refusal) announce(refusalText(refusal))
      else if (msg) announce(msg)
      return undefined
    },
    [draft, announce, refusalText],
  )

  const anchored = useMemo(() => anchorViolations(violations, graph), [violations, graph])
  const blockingCount = violations.filter(isBlocking).length
  const problemsFor = useCallback(
    (kind: 'node' | 'edge', id: string) => anchored.filter((a) => (kind === 'node' ? a.nodeId === id : a.edgeId === id)).map((a) => a.message),
    [anchored],
  )
  const word = (count: number) => e('problems', { count })

  const nameOf = useCallback(
    (id: string) => {
      const n = graph.nodes.find((x) => x.id === id)
      return n ? nodeName(n, t.typeName) : id
    },
    [graph.nodes, t],
  )

  const flowNodes: DiagramFlowNode[] = useMemo(
    () =>
      graph.nodes.map((n) => {
        const dims = nodeDims(n.node_type, 'LR')
        const pos = positionOf(n) ?? { x: 0, y: 0 }
        const msgs = problemsFor('node', n.id)
        const label = nodeName(n, t.typeName)
        return {
          id: n.id,
          type: 'diagram',
          position: pos,
          width: dims.width,
          height: dims.height,
          draggable: true,
          connectable: true,
          selected: sel?.kind === 'node' && sel.id === n.id,
          ariaLabel: [label, t.typeName(n.node_type)].join(', '),
          data: {
            nodeType: n.node_type,
            label,
            typeName: t.typeName(n.node_type),
            subLine: summariseNode(n.node_type, readAttrs(n), nameOf).subLine,
            direction: 'LR' as const,
            shape: dims.shape,
            editable: true,
            invalid: msgs.length ? { count: msgs.length, word: word(msgs.length), messages: msgs } : undefined,
          },
        }
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [graph.nodes, sel, t, problemsFor, nameOf, intl.locale],
  )
  const flowEdges: DiagramFlowEdge[] = useMemo(
    () =>
      graph.edges.map((x) => {
        const full = x.condition ?? (x.is_default ? e('edgeDefault') : null)
        const msgs = problemsFor('edge', x.id)
        return {
          id: x.id,
          source: x.source,
          target: x.target,
          type: 'diagram',
          focusable: true,
          selected: sel?.kind === 'edge' && sel.id === x.id,
          ariaLabel: e('edgeAria', { from: nameOf(x.source), to: nameOf(x.target) }),
          data: {
            label: full ? cutLabel(full) : null,
            fullLabel: full,
            invalid: msgs.length ? { count: msgs.length, word: word(msgs.length), messages: msgs } : undefined,
          },
        }
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [graph.edges, sel, nameOf, problemsFor, intl.locale],
  )

  // One drag gesture = one undo step (see dragCoalescer); keyboard nudges report no drag and are one step each.
  const dragKey = useRef(dragCoalescer())
  const onNodesChange = useCallback(
    (changes: NodeChange[]) => {
      for (const c of changes) {
        if (c.type !== 'position') continue
        const key = dragKey.current(c.id, c.dragging)
        if (c.position) draft.apply(moveNode(graph, c.id, c.position), key)
      }
    },
    [draft, graph],
  )
  const ariaLabelConfig = useMemo<Partial<AriaLabelConfig>>(
    () => {
      const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.${id}` }, values)
      return {
        'node.a11yDescription.default': m('edit.a11y.node'),
        'node.a11yDescription.keyboardDisabled': m('edit.a11y.node'),
        'node.a11yDescription.ariaLiveMessage': ({ x, y }) => m('edit.a11y.moved', { x: Math.round(x), y: Math.round(y) }),
        'edge.a11yDescription.default': m('edit.a11y.edge'),
        'controls.ariaLabel': m('a11y.controls'),
        'controls.zoomIn.ariaLabel': m('a11y.zoomIn'),
        'controls.zoomOut.ariaLabel': m('a11y.zoomOut'),
        'controls.fitView.ariaLabel': m('a11y.fitView'),
        'controls.interactive.ariaLabel': m('a11y.interactive'),
        'minimap.ariaLabel': m('a11y.minimap'),
        'handle.ariaLabel': m('a11y.handle'),
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [intl.locale],
  )
  const onConnect = useCallback(
    (c: Connection) => {
      if (!c.source || !c.target) return
      apply(connect(graph, c.source, c.target), e('announce.connected', { from: nameOf(c.source), to: nameOf(c.target) }))
    },
    [apply, graph, e, nameOf],
  )
  const isValidConnection = useCallback(
    (c: { source?: string | null; target?: string | null }) => {
      if (!c.source || !c.target) return false
      const r = connectionRefusal(graph, c.source, c.target)
      if (r) announce(refusalText(r))
      return r === null
    },
    [graph, announce, refusalText],
  )

  const addStep = () => {
    // Left to right like the layout: a new step goes to the right of the drawing, level with the start.
    const xs = graph.nodes.map((n) => positionOf(n)?.x ?? 0)
    const start = graph.nodes.find((n) => n.node_type === 'START')
    const at = { x: (xs.length ? Math.max(...xs) : 0) + 280, y: (start && positionOf(start)?.y) || 0 }
    const r = addNode(graph, addType, at)
    apply(r, r.ok ? e('announce.added', { type: t.typeName(addType) }) : undefined)
    if (r.ok && r.id) setSel({ kind: 'node', id: r.id })
  }

  const deleteSelection = () => {
    if (!sel) return
    if (sel.kind === 'node') apply(deleteNodes(graph, [sel.id]), e('announce.deleted', { name: nameOf(sel.id) }))
    else apply(deleteEdges(graph, [sel.id]), e('announce.connectionDeleted'))
  }

  const onKeyDown = (ev: React.KeyboardEvent) => {
    if (isTyping(ev.target)) return
    const mod = ev.ctrlKey || ev.metaKey
    const k = ev.key.toLowerCase()
    if (mod && k === 'z') {
      ev.preventDefault()
      if (ev.shiftKey) draft.redo()
      else draft.undo()
      announce(e(ev.shiftKey ? 'announce.redo' : 'announce.undo'))
    } else if (mod && k === 'y') {
      ev.preventDefault()
      draft.redo()
      announce(e('announce.redo'))
    } else if ((ev.key === 'Delete' || ev.key === 'Backspace') && sel) {
      ev.preventDefault()
      deleteSelection()
    } else if (ev.key === 'Escape' && sel) {
      setSel(null)
    } else if (ev.altKey && sel?.kind === 'node' && ev.key.startsWith('Arrow')) {
      ev.preventDefault()
      const n = graph.nodes.find((x) => x.id === sel.id)
      const p = n ? positionOf(n) ?? { x: 0, y: 0 } : null
      if (!p) return
      const d = ev.shiftKey ? NUDGE_FAR : NUDGE
      const dx = ev.key === 'ArrowLeft' ? -d : ev.key === 'ArrowRight' ? d : 0
      const dy = ev.key === 'ArrowUp' ? -d : ev.key === 'ArrowDown' ? d : 0
      draft.apply(moveNode(graph, sel.id, { x: p.x + dx, y: p.y + dy }), `nudge:${sel.id}`)
      announce(e('announce.moved', { name: nameOf(sel.id) }))
    }
  }

  const counts = check.phase === 'invalid' ? { blocking: blockingCount, advisory: violations.length - blockingCount } : check.phase === 'valid' ? { blocking: 0, advisory: 0 } : null
  const selectViolation = (a: { nodeId?: string; edgeId?: string }) => {
    if (a.nodeId) setSel({ kind: 'node', id: a.nodeId })
    else if (a.edgeId) setSel({ kind: 'edge', id: a.edgeId })
  }

  const panel =
    sel?.kind === 'node' ? (
      <NodeEditPanel
        graph={graph}
        nodeId={sel.id}
        onApply={apply}
        onClose={() => setSel(null)}
        onSelectEdge={(id) => setSel({ kind: 'edge', id })}
        problems={problemsFor('node', sel.id)}
      />
    ) : sel?.kind === 'edge' ? (
      <EdgeEditPanel graph={graph} edgeId={sel.id} onApply={apply} onClose={() => setSel(null)} problems={problemsFor('edge', sel.id)} />
    ) : null

  return (
    <div className="lf-pd lf-pd-edit" ref={containerRef} onKeyDown={onKeyDown} data-testid="diagram-editor" data-width-class={narrow ? 'narrow' : 'wide'}>
      {tooBig && <Banner tone="warning">{e('tooBig', { max: MAX_NODES })}</Banner>}
      <EditToolbar
        {...toolbar}
        addType={addType}
        onAddType={setAddType}
        onAdd={addStep}
        onUndo={() => {
          draft.undo()
          announce(e('announce.undo'))
        }}
        onRedo={() => {
          draft.redo()
          announce(e('announce.redo'))
        }}
        canUndo={draft.canUndo}
        canRedo={draft.canRedo}
        onDeleteSelection={deleteSelection}
        hasSelection={sel !== null}
        checking={check.phase === 'checking'}
        counts={counts}
        checkFailed={check.phase === 'failed'}
        dirty={draft.dirty}
      />
      <div className="sr-only" aria-live="polite" role="status" data-testid="edit-live">
        {live}
      </div>
      {anchored.length > 0 && (
        <ul className="lf-pd-edit__violations" aria-label={e('violations')} data-testid="edit-violations">
          {anchored.map((a, i) => (
            <li key={`${i}-${a.message}`}>
              <Button variant="ghost" size="sm" className="lf-pd-edit__violation" onClick={() => selectViolation(a)} data-testid="edit-violation">
                <span aria-hidden="true">⚠ </span>
                {a.message}
              </Button>
            </li>
          ))}
        </ul>
      )}
      <div className={`lf-pd__body${width >= diagramConfig.wideWidth ? '' : ' is-stacked'}`}>
        {/* Rule 2a: under the wide width the open panel takes the whole area; closing it returns to the view. */}
        {width < diagramConfig.wideWidth && panel ? null : narrow || tooBig ? (
          <EditSteps graph={graph} selectedId={sel?.kind === 'node' ? sel.id : null} onSelect={(id) => setSel({ kind: 'node', id })} onApply={apply} onSelectEdge={(id) => setSel({ kind: 'edge', id })} problemsFor={problemsFor} />
        ) : (
          <div
            className="lf-pd__canvas is-editing is-edit-height"
            role="group"
            aria-label={e('canvas')}
            data-testid="diagram-canvas"
          >
            <ReactFlow
              nodes={flowNodes}
              edges={flowEdges}
              nodeTypes={nodeTypes}
              edgeTypes={edgeTypes}
              nodesDraggable
              nodesConnectable
              edgesFocusable
              elementsSelectable
              nodesFocusable
              deleteKeyCode={null}
              fitView
              fitViewOptions={FIT_VIEW_OPTIONS}
              minZoom={diagramConfig.minZoom}
              maxZoom={diagramConfig.maxZoom}
              proOptions={PRO_OPTIONS}
              ariaLabelConfig={ariaLabelConfig}
              onNodesChange={onNodesChange}
              onConnect={onConnect}
              isValidConnection={isValidConnection}
              onNodeClick={(_ev, n) => setSel({ kind: 'node', id: n.id })}
              onEdgeClick={(_ev, x) => setSel({ kind: 'edge', id: x.id })}
              onPaneClick={() => setSel(null)}
              onKeyDown={(ev) => {
                const el = (ev.target as HTMLElement).closest?.('[data-id]')
                const id = el?.getAttribute('data-id')
                if (ev.key === 'Enter' && id) {
                  if (el?.classList.contains('react-flow__edge')) setSel({ kind: 'edge', id })
                  else setSel({ kind: 'node', id })
                }
              }}
            >
              <Background gap={24} />
              <Controls position="top-left" showInteractive={false} />
            </ReactFlow>
          </div>
        )}
        {panel}
      </div>
    </div>
  )
}

/** The narrow / large-definition editor: every step in reading order with its outgoing connections, each with Edit and
 *  Delete connection, so editing needs no pointer and no canvas. */
function EditSteps({
  graph,
  selectedId,
  onSelect,
  onSelectEdge,
  onApply,
  problemsFor,
}: {
  graph: DefinitionGraph
  selectedId: string | null
  onSelect: (id: string) => void
  onSelectEdge: (id: string) => void
  onApply: ApplyEdit
  problemsFor: (kind: 'node' | 'edge', id: string) => string[]
}) {
  const e = useEditText()
  const t = useDiagramText()
  const nodes = graph.nodes.map((n) => ({ id: n.id, nodeType: n.node_type, label: n.label, attributes: {}, x: 0, y: 0, width: 0, height: 0 }))
  const edges = graph.edges.map((x) => ({ id: x.id, source: x.source, target: x.target, condition: x.condition, isDefault: x.is_default === true, points: [] }))
  const name = (id: string) => {
    const n = graph.nodes.find((x) => x.id === id)
    return n ? nodeName(n, t.typeName) : id
  }
  return (
    <ol className="lf-pd-steps lf-pd-edit__steps" aria-label={e('canvas')} data-testid="edit-steps">
      {readingOrder(nodes, edges).map((n, i) => {
        const outs = graph.edges.filter((x) => x.source === n.id)
        const msgs = problemsFor('node', n.id)
        return (
          <li key={n.id} className="lf-pd-steps__item" data-testid="edit-step" data-node-id={n.id}>
            <span className="lf-pd-steps__num">{i + 1}</span>
            <div className="lf-pd-steps__main">
              <button type="button" className="lf-pd-steps__button" aria-pressed={selectedId === n.id} onClick={() => onSelect(n.id)}>
                {name(n.id)}
              </button>
              <span className="lf-pd-steps__meta">{t.typeName(n.nodeType)}</span>
              {msgs.length > 0 && (
                <span className="lf-pill lf-pill--danger" data-testid="edit-step-invalid">
                  ⚠ {e('problems', { count: msgs.length })}
                </span>
              )}
              <ul className="lf-pd-steps__next">
                {outs.map((x) => (
                  <li key={x.id} className="lf-pd-edit__conn" data-testid="edit-step-connection">
                    <span className="lf-pd-edit__conn-text">
                      → {name(x.target)}
                      {x.condition ? <span className="lf-pd__mono"> [{x.condition}]</span> : null}
                      {x.is_default ? ` (${e('edgeDefault')})` : ''}
                    </span>
                    <Button variant="ghost" size="sm" onClick={() => onSelectEdge(x.id)} data-testid="edit-step-connection-edit">
                      {e('connectionEdit')}
                    </Button>
                    <Button variant="ghost" size="sm" onClick={() => onApply(deleteEdges(graph, [x.id]), e('announce.connectionDeleted'))} data-testid="edit-step-connection-delete">
                      {e('connectionDelete')}
                    </Button>
                  </li>
                ))}
              </ul>
            </div>
          </li>
        )
      })}
    </ol>
  )
}

