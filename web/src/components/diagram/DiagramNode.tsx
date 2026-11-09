/** DiagramNode — T-1520. One read-only node component for all node types. Shape by type (CSS class), status as a
 *  word and a glyph (rule 5), never colour alone. Focusable through React Flow (`nodesFocusable`). */
import { memo } from 'react'
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import { Clock, Cog, GitBranch, Layers, Plus, User } from 'lucide-react'
import type { NodeState } from '@/utils/canvas/instancePath'
import { glyphClass } from '@/components/ui/StatusPill'
import { STATE_PILL } from './diagramConfig'

export interface DiagramNodeData {
  nodeType: string
  label: string
  typeName: string
  subLine: string | null
  state?: NodeState
  stateName?: string
  direction: 'TB' | 'LR'
  /** Compact types: the shape size (px); the node box also holds the caption below the shape. */
  shape?: number
  [key: string]: unknown
}

export type DiagramFlowNode = Node<DiagramNodeData, 'diagram'>

const ICONS: Record<string, typeof User> = {
  HUMAN_TASK: User,
  SERVICE_TASK: Cog,
  TIMER: Clock,
  SUB_PROCESS: Layers,
  EXCLUSIVE_GATEWAY: GitBranch,
  PARALLEL_GATEWAY: Plus,
}

function DiagramNodeImpl({ data }: NodeProps<DiagramFlowNode>) {
  const { nodeType, label, typeName, subLine, state, stateName, direction, shape } = data
  const Icon = ICONS[nodeType]
  const compact = shape !== undefined
  const pill = state ? STATE_PILL[state] : null
  return (
    <div
      className={`lf-pd-node lf-pd-node--${nodeType.toLowerCase().replace(/_/g, '-')}${compact ? ` lf-pd-node--compact is-${direction.toLowerCase()}` : ''}${state ? ` is-${state}` : ''}`}
      // The shape size is layout geometry (the same number dagre used), not a colour or spacing value.
      style={compact ? { ['--lf-pd-shape' as string]: `${shape}px` } : undefined}
      data-testid={`diagram-node-${nodeType}`}
      data-node-type={nodeType}
      data-state={state ?? 'none'}
      title={label}
    >
      <Handle type="target" position={direction === 'LR' ? Position.Left : Position.Top} isConnectable={false} />
      <div className="lf-pd-node__shape" aria-hidden="true">
        {Icon && <Icon className="lf-icon" />}
      </div>
      {!compact && (
        <div className="lf-pd-node__body">
          <span className="lf-pd-node__label">{label}</span>
          {subLine && <span className="lf-pd-node__sub">{subLine}</span>}
          {pill && stateName && (
            <span className={`lf-pill lf-pill--${pill.tone} lf-pd-node__pill`} data-testid="diagram-node-state">
              <span className={glyphClass(pill.glyph)} aria-hidden="true" />
              {stateName}
            </span>
          )}
        </div>
      )}
      {compact && (
        <div className="lf-pd-node__caption">
          <span className="lf-pd-node__label">{nodeType === 'START' || nodeType === 'END' ? typeName : label}</span>
          {subLine && <span className="lf-pd-node__sub">{subLine}</span>}
          {pill && stateName && (
            <span className={`lf-pill lf-pill--${pill.tone} lf-pd-node__pill`} data-testid="diagram-node-state">
              <span className={glyphClass(pill.glyph)} aria-hidden="true" />
              {stateName}
            </span>
          )}
        </div>
      )}
      <Handle type="source" position={direction === 'LR' ? Position.Right : Position.Bottom} isConnectable={false} />
    </div>
  )
}

export const DiagramNode = memo(DiagramNodeImpl)
