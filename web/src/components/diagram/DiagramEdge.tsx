/** DiagramEdge — T-1520. Smooth-step edge; label = condition (cut, full text in the title) or "default". Taken edges
 *  are heavier, untaken edges of an instance view are muted, unclear edges are dashed. Colours from tokens (CSS). */
import { memo } from 'react'
import { BaseEdge, EdgeLabelRenderer, getSmoothStepPath, type Edge, type EdgeProps } from '@xyflow/react'
import type { EdgeState } from '@/utils/canvas/instancePath'
import { diagramConfig } from './diagramConfig'

export interface DiagramEdgeData {
  label: string | null
  fullLabel: string | null
  state?: EdgeState
  [key: string]: unknown
}

export type DiagramFlowEdge = Edge<DiagramEdgeData, 'diagram'>

export function cutLabel(text: string): string {
  return text.length > diagramConfig.edgeLabelMax ? `${text.slice(0, diagramConfig.edgeLabelMax - 1)}…` : text
}

function DiagramEdgeImpl(props: EdgeProps<DiagramFlowEdge>) {
  const { id, sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, data } = props
  const [path, labelX, labelY] = getSmoothStepPath({ sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, borderRadius: 8 })
  const state = data?.state
  return (
    <>
      <BaseEdge
        id={id}
        path={path}
        className={`lf-pd-edge${state ? ` is-${state}` : ''}`}
        markerEnd={`url(#lf-pd-arrow${state ? `-${state}` : ''})`}
      />
      {data?.label && (
        <EdgeLabelRenderer>
          <div
            className={`lf-pd-edge__label nodrag nopan${state ? ` is-${state}` : ''}`}
            data-testid="diagram-edge-label"
            title={data.fullLabel ?? data.label}
            // React Flow positions edge labels by transform; a computed position, not a colour or spacing value.
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)` }}
          >
            {data.label}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  )
}

export const DiagramEdge = memo(DiagramEdgeImpl)
