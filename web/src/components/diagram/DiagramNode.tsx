/** DiagramNode — T-1520. One read-only node component for all node types. Shape by type (CSS class), status as a
 *  word and a glyph (rule 5), never colour alone. Focusable through React Flow (`nodesFocusable`). */
import { memo } from 'react'
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import { Clock, Cog, GitBranch, Layers, Plus, User } from 'lucide-react'
import type { NodeState } from '@/utils/canvas/instancePath'
import { glyphClass } from '@/components/ui/StatusPill'
import { DIFF_PILL, STATE_PILL } from './diagramConfig'

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
  /** T-1563: set only by DiagramEditor; makes the two handles connectable. */
  editable?: boolean
  /** T-1563: violations anchored to this node (a glyph plus a word, rule 5). */
  invalid?: { count: number; word: string; messages: string[] }
  /** T-1588: set only in a version diff: the kind and its word (a pill with a glyph, never colour alone). */
  diff?: { kind: 'added' | 'removed' | 'changed'; word: string }
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
  const { nodeType, label, typeName, subLine, state, stateName, direction, shape, editable, invalid, diff } = data
  const Icon = ICONS[nodeType]
  const compact = shape !== undefined
  const pill = state ? STATE_PILL[state] : null
  const diffPill = diff ? (
    <span className={`lf-pill lf-pill--${DIFF_PILL[diff.kind].tone} lf-pd-node__pill`} data-testid="diagram-node-diff" data-diff={diff.kind}>
      <span className={glyphClass(DIFF_PILL[diff.kind].glyph)} aria-hidden="true" data-testid="diagram-diff-glyph" />
      {diff.word}
    </span>
  ) : null
  return (
    <div
      className={`lf-pd-node lf-pd-node--${nodeType.toLowerCase().replace(/_/g, '-')}${compact ? ` lf-pd-node--compact is-${direction.toLowerCase()}` : ''}${state ? ` is-${state}` : ''}${invalid ? ' is-invalid' : ''}${diff ? ` is-diff-${diff.kind}` : ''}`}
      // The shape size is layout geometry (the same number dagre used), not a colour or spacing value.
      style={compact ? { ['--lf-pd-shape' as string]: `${shape}px` } : undefined}
      data-testid={`diagram-node-${nodeType}`}
      data-node-type={nodeType}
      data-state={state ?? 'none'}
      title={invalid ? `${label}: ${invalid.messages.join('; ')}` : label}
    >
      <Handle type="target" position={direction === 'LR' ? Position.Left : Position.Top} isConnectable={editable === true} />
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
          {diffPill}
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
          {diffPill}
        </div>
      )}
      <Handle type="source" position={direction === 'LR' ? Position.Right : Position.Bottom} isConnectable={editable === true} />
      {invalid && (
        <span className="lf-pill lf-pill--danger lf-pd-node__invalid" data-testid="diagram-node-invalid">
          <span className={glyphClass('triangle')} aria-hidden="true" />
          {invalid.word}
        </span>
      )}
    </div>
  )
}

export const DiagramNode = memo(DiagramNodeImpl)
