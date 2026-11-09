/** DiagramEdge — T-1520. A smooth curve along the dagre route (so a long edge bends around the nodes between its
 *  ends), from the source handle to the target handle; smooth-step when there is no route. Label = condition (cut,
 *  full text in the title) or "default", placed where dagre reserved space for it, clear of node captions. Taken
 *  edges are heavier, untaken edges of an instance view are muted, unclear edges are dashed. Colours from tokens. */
import { memo } from 'react'
import { BaseEdge, EdgeLabelRenderer, getSmoothStepPath, type Edge, type EdgeProps } from '@xyflow/react'
import type { EdgeState } from '@/utils/canvas/instancePath'
import type { Point } from '@/utils/canvas/readLayout'
import { diagramConfig } from './diagramConfig'

export interface DiagramEdgeData {
  label: string | null
  fullLabel: string | null
  state?: EdgeState
  /** dagre route; its first and last points are replaced by the handle positions. */
  points?: Point[]
  exitBelowCaption?: boolean
  labelX?: number
  labelY?: number
  /** T-1563: violations anchored to this edge. */
  invalid?: { count: number; word: string; messages: string[] }
  [key: string]: unknown
}

export type DiagramFlowEdge = Edge<DiagramEdgeData, 'diagram'>

export function cutLabel(text: string): string {
  return text.length > diagramConfig.edgeLabelMax ? `${text.slice(0, diagramConfig.edgeLabelMax - 1)}…` : text
}

const f = (n: number) => Math.round(n * 10) / 10

/** A B-spline (the d3 "basis" curve) through the points: starts at the first and ends at the last point. */
export function basisPath(pts: Point[]): string {
  if (pts.length < 2) return ''
  if (pts.length === 2) return `M${f(pts[0].x)},${f(pts[0].y)}L${f(pts[1].x)},${f(pts[1].y)}`
  let d = `M${f(pts[0].x)},${f(pts[0].y)}`
  let [x0, y0, x1, y1] = [pts[0].x, pts[0].y, pts[1].x, pts[1].y]
  d += `L${f((5 * x0 + x1) / 6)},${f((5 * y0 + y1) / 6)}`
  const seg = (x: number, y: number) => {
    d += `C${f((2 * x0 + x1) / 3)},${f((2 * y0 + y1) / 3)} ${f((x0 + 2 * x1) / 3)},${f((y0 + 2 * y1) / 3)} ${f((x0 + 4 * x1 + x) / 6)},${f((y0 + 4 * y1 + y) / 6)}`
    x0 = x1
    y0 = y1
    x1 = x
    y1 = y
  }
  for (let i = 2; i < pts.length; i++) seg(pts[i].x, pts[i].y)
  seg(x1, y1)
  d += `L${f(x1)},${f(y1)}`
  return d
}

function DiagramEdgeImpl(props: EdgeProps<DiagramFlowEdge>) {
  const { id, sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, data } = props
  const route = data?.points
  let path: string
  let labelX: number
  let labelY: number
  if (route && route.length >= 2) {
    const interior = data?.exitBelowCaption ? route.slice(0, -1) : route.slice(1, -1)
    path = basisPath([{ x: sourceX, y: sourceY }, ...interior, { x: targetX, y: targetY }])
    const mid = route[Math.floor(route.length / 2)]
    labelX = data?.labelX ?? mid.x
    labelY = data?.labelY ?? mid.y
  } else {
    const step = getSmoothStepPath({ sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, borderRadius: 8 })
    path = step[0]
    labelX = step[1]
    labelY = step[2]
  }
  const state = data?.state
  return (
    <>
      <BaseEdge
        id={id}
        path={path}
        className={`lf-pd-edge${state ? ` is-${state}` : ''}${data?.invalid ? ' is-invalid' : ''}`}
        markerEnd={`url(#lf-pd-arrow${state ? `-${state}` : ''})`}
      />
      {(data?.label || data?.invalid) && (
        <EdgeLabelRenderer>
          <div
            className={`lf-pd-edge__label nodrag nopan${state ? ` is-${state}` : ''}`}
            data-testid="diagram-edge-label"
            title={[data.fullLabel ?? data.label, ...(data.invalid?.messages ?? [])].filter(Boolean).join(': ')}
            // React Flow positions edge labels by transform; a computed position, not a colour or spacing value.
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)` }}
          >
            {data.label}
            {data.invalid && (
              <span className="lf-pd-edge__invalid" data-testid="diagram-edge-invalid">
                {' '}
                ⚠ {data.invalid.word}
              </span>
            )}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  )
}

export const DiagramEdge = memo(DiagramEdgeImpl)
