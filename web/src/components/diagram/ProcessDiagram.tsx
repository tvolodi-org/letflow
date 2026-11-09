/** ProcessDiagram — T-1520 (D-114 item 2, slice 1). A good-looking, READ-ONLY picture of a process definition,
 *  drawn from the definition alone (the single source of truth): automatic layout (dagre), node shapes by type,
 *  zoom/pan/minimap (React Flow), keyboard-focusable nodes with a details panel, a step-list fallback for narrow
 *  screens, screen readers and huge definitions, and — when given an instance path — status colours and the path
 *  the instance took. No editing: nothing can be dragged, connected or saved. See docs/design/process-designer.md. */
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { ArrowDown, ArrowRight } from 'lucide-react'
import { Background, Controls, MiniMap, ReactFlow, ReactFlowProvider, type FitViewOptions } from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import '@/styles/process-diagram.css'
import type { DefinitionGraph } from '@/types/api'
import { isChain, layoutDefinition, type LayoutDirection } from '@/utils/canvas/readLayout'
import type { InstancePath, NodeState } from '@/utils/canvas/instancePath'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { EmptyState } from '@/components/ui/EmptyState'
import { diagramConfig } from './diagramConfig'
import { DiagramNode, type DiagramFlowNode } from './DiagramNode'
import { DiagramEdge, cutLabel, type DiagramFlowEdge } from './DiagramEdge'
import { StepsList } from './StepsList'
import { NodeDetails } from './NodeDetails'
import { summariseNode } from './nodeSummary'
import { useDiagramText } from './useDiagramText'

const nodeTypes = { diagram: DiagramNode }
const edgeTypes = { diagram: DiagramEdge }
// Module-level so React Flow does not re-fit on every render (see the infinite-loop note in ProcessCanvas.tsx).
const FIT_VIEW_OPTIONS: FitViewOptions = { padding: 0.15, maxZoom: 1 }
const PRO_OPTIONS = { hideAttribution: true }

const MINIMAP_COLOUR: Record<NodeState | 'none', string> = {
  done: 'var(--success)',
  active: 'var(--current)',
  error: 'var(--danger)',
  skipped: 'var(--line)',
  pending: 'var(--line-strong)',
  unclear: 'var(--warning)',
  none: 'var(--line-strong)',
}

/** The container width, from a ResizeObserver; wide when the browser has none (jsdom). */
function useContainerWidth(): [React.RefObject<HTMLDivElement>, number] {
  const ref = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(1200)
  useEffect(() => {
    const el = ref.current
    if (!el || typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect.width
      if (typeof w === 'number' && w > 0) setWidth(w)
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  return [ref, width]
}

export interface ProcessDiagramProps {
  graph: DefinitionGraph | null | undefined
  /** An instance's path; without it the diagram shows the definition only. */
  path?: InstancePath | null
  /** Instance error reason for the "not tied to a step" banner. */
  errorReason?: string | null
  /** Retry for an incomplete history (a failed timeline page). */
  onRetry?: () => void
  /** Animate taken edges (a running instance). */
  live?: boolean
  /** Extra content in the toolbar (for example the unsaved-preview badge). */
  toolbarExtra?: ReactNode
  onNodeSelect?: (nodeId: string | null) => void
  /** Start in the step list instead of the canvas. */
  initialMode?: 'diagram' | 'steps'
  /** A step selected on first render (its details panel open). */
  initialSelected?: string | null
}

export default function ProcessDiagram(props: ProcessDiagramProps) {
  return (
    <ReactFlowProvider>
      <ProcessDiagramInner {...props} />
    </ReactFlowProvider>
  )
}

function ProcessDiagramInner(props: ProcessDiagramProps) {
  const { graph, path, errorReason, onRetry, live, toolbarExtra, onNodeSelect } = props
  const intl = useIntl()
  const t = useDiagramText()
  const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.${id}` }, values)
  const [containerRef, width] = useContainerWidth()
  const wide = width >= diagramConfig.wideWidth
  const narrow = width < diagramConfig.narrowWidth
  const chain = useMemo(() => (graph ? isChain(graph) : false), [graph])
  const [userDirection, setUserDirection] = useState<LayoutDirection | null>(null)
  const direction: LayoutDirection = userDirection ?? (wide && chain ? 'LR' : 'TB')
  const [mode, setMode] = useState<'diagram' | 'steps'>(props.initialMode ?? 'diagram')
  const [selected, setSelected] = useState<string | null>(props.initialSelected ?? null)

  const layout = useMemo(() => layoutDefinition(graph, direction), [graph, direction])
  const count = layout.nodes.length
  const huge = count > diagramConfig.hugeGraphNodes
  const big = count > diagramConfig.bigGraphNodes
  const showSteps = narrow || huge || mode === 'steps'
  // The canvas grows with the drawing (within limits), so a tall definition is not shrunk into a fixed box.
  const canvasHeight = Math.round(
    Math.min(Math.max(layout.height + diagramConfig.canvasPadding, diagramConfig.canvasMinHeight), diagramConfig.canvasMaxHeight),
  )

  const select = useCallback(
    (id: string | null) => {
      setSelected(id)
      onNodeSelect?.(id)
    },
    [onNodeSelect],
  )

  const labelOf = useCallback(
    (id: string) => {
      const n = layout.nodes.find((x) => x.id === id)
      return n ? n.label ?? t.typeName(n.nodeType) : id
    },
    [layout.nodes, t],
  )

  const flowNodes: DiagramFlowNode[] = useMemo(
    () =>
      layout.nodes.map((n) => {
        const st = path?.nodes.get(n.id)?.state
        const label = n.label ?? t.typeName(n.nodeType)
        const typeName = t.typeName(n.nodeType)
        const stateName = st ? t.stateName(st) : undefined
        return {
          id: n.id,
          type: 'diagram',
          position: { x: n.x, y: n.y },
          width: n.width,
          height: n.height,
          draggable: false,
          connectable: false,
          selected: selected === n.id,
          ariaLabel: [label, typeName, stateName].filter(Boolean).join(', '),
          data: { nodeType: n.nodeType, label, typeName, subLine: summariseNode(n.nodeType, n.attributes, labelOf).subLine, state: st, stateName, direction },
        }
      }),
    [layout.nodes, path, t, selected, direction, labelOf],
  )
  const flowEdges: DiagramFlowEdge[] = useMemo(
    () =>
      layout.edges.map((e) => {
        const full = e.condition ?? (e.isDefault ? m('edge.default') : null)
        return {
          id: e.id,
          source: e.source,
          target: e.target,
          type: 'diagram',
          focusable: false,
          data: { label: full ? cutLabel(full) : null, fullLabel: full, state: path?.edges.get(e.id) },
        }
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [layout.edges, path, intl.locale],
  )

  const selectedNode = selected ? layout.nodes.find((n) => n.id === selected) ?? null : null

  if (!graph || !Array.isArray(graph.nodes)) {
    return <EmptyState title={m('noGraph')} data-testid="diagram-no-graph" />
  }
  if (count === 0) {
    return <EmptyState title={m('empty.title')} text={m('empty.body')} data-testid="diagram-empty" />
  }

  const notes = path?.notes ?? []
  return (
    <div className="lf-pd" ref={containerRef} data-testid="process-diagram" data-width-class={narrow ? 'narrow' : wide ? 'wide' : 'medium'}>
      {notes.includes('cancelled') && <Banner tone="info">{m('note.cancelled')}</Banner>}
      {notes.includes('errorNotAttributed') && (
        <Banner tone="danger">{m('note.errorNotAttributed', { reason: errorReason ?? '—' })}</Banner>
      )}
      {notes.includes('notReconciled') && <Banner tone="warning">{m('note.notReconciled')}</Banner>}
      {notes.includes('historyIncomplete') && (
        <Banner
          tone="warning"
          action={onRetry ? <Button variant="secondary" size="sm" onClick={onRetry}>{m('retry')}</Button> : undefined}
        >
          {m('note.historyIncomplete')}
        </Banner>
      )}
      {huge && <Banner tone="info">{m('large', { count })}</Banner>}
      {layout.droppedEdges > 0 && <Banner tone="warning">{m('droppedEdges', { count: layout.droppedEdges })}</Banner>}

      <div className="lf-pd__toolbar">
        {!narrow && !huge && (
          <div className="lf-pd__seg" role="group" aria-label={m('mode.group')}>
            <Button variant="secondary" size="sm" pressed={mode === 'diagram'} onClick={() => setMode('diagram')} data-testid="diagram-mode-diagram">
              {m('mode.diagram')}
            </Button>
            <Button variant="secondary" size="sm" pressed={mode === 'steps'} onClick={() => setMode('steps')} data-testid="diagram-mode-steps">
              {m('mode.steps')}
            </Button>
          </div>
        )}
        {!showSteps && (
          <Button
            variant="ghost"
            size="sm"
            icon={direction === 'TB' ? <ArrowRight className="lf-icon" /> : <ArrowDown className="lf-icon" />}
            onClick={() => setUserDirection(direction === 'TB' ? 'LR' : 'TB')}
            data-testid="diagram-direction"
          >
            {direction === 'TB' ? m('direction.toLR') : m('direction.toTB')}
          </Button>
        )}
        <span className="lf-pd__toolbar-spacer" />
        {toolbarExtra}
      </div>

      <div className={`lf-pd__body${wide ? '' : ' is-stacked'}`}>
        {/* Rule 2a: under the wide width the details panel takes the whole area; closing it returns to the view. */}
        {!wide && selectedNode ? null : showSteps ? (
          <StepsList nodes={layout.nodes} edges={layout.edges} path={path} selectedId={selected} onSelect={(id) => select(id)} />
        ) : (
          <div
            className={`lf-pd__canvas${live ? ' is-live' : ''}`}
            style={{ ['--lf-pd-canvas-h' as string]: `${canvasHeight}px` }}
            role="group"
            aria-label={m('label')}
            data-testid="diagram-canvas"
          >
            <svg className="lf-pd__defs" width="0" height="0" aria-hidden="true" focusable="false">
              <defs>
                {['', '-taken', '-untaken', '-unclear'].map((suffix) => (
                  <marker
                    key={suffix}
                    id={`lf-pd-arrow${suffix}`}
                    viewBox="0 0 10 10"
                    refX="9"
                    refY="5"
                    markerWidth="7"
                    markerHeight="7"
                    orient="auto-start-reverse"
                  >
                    <path d="M 0 0 L 10 5 L 0 10 z" className={`lf-pd-arrow${suffix ? ` is-${suffix.slice(1)}` : ''}`} />
                  </marker>
                ))}
              </defs>
            </svg>
            <ReactFlow
              nodes={flowNodes}
              edges={flowEdges}
              nodeTypes={nodeTypes}
              edgeTypes={edgeTypes}
              nodesDraggable={false}
              nodesConnectable={false}
              edgesFocusable={false}
              elementsSelectable
              nodesFocusable
              fitView
              fitViewOptions={FIT_VIEW_OPTIONS}
              minZoom={diagramConfig.minZoom}
              maxZoom={diagramConfig.maxZoom}
              onlyRenderVisibleElements={big}
              proOptions={PRO_OPTIONS}
              onNodeClick={(_e, n) => select(n.id)}
              onPaneClick={() => select(null)}
              onKeyDown={(e) => {
                const id = (e.target as HTMLElement).closest?.('[data-id]')?.getAttribute('data-id')
                if (e.key === 'Enter' && id) select(id)
              }}
            >
              <Background gap={24} />
              <Controls position="top-left" showInteractive={false} />
              {!big && <MiniMap position="top-right" pannable zoomable nodeColor={(n) => MINIMAP_COLOUR[(n.data as { state?: NodeState }).state ?? 'none']} />}
            </ReactFlow>
          </div>
        )}
        {selectedNode && (
          <NodeDetails
            node={selectedNode}
            nodes={layout.nodes}
            edges={layout.edges}
            state={path?.nodes.get(selectedNode.id)}
            onClose={() => select(null)}
          />
        )}
      </div>
    </div>
  )
}
