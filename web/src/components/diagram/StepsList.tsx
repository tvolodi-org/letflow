/** StepsList — T-1520. The accessible and narrow-screen view of a process: every step in reading order (depth-first
 *  from START, unreachable steps appended) with its type, state and outgoing connections. Same data as the diagram. */
import { useIntl } from 'react-intl'
import type { LaidOutEdge, LaidOutNode } from '@/utils/canvas/readLayout'
import type { InstancePath } from '@/utils/canvas/instancePath'
import { StatusPill } from '@/components/ui/StatusPill'
import { STATE_PILL } from './diagramConfig'
import { useDiagramText } from './useDiagramText'

export function readingOrder(nodes: LaidOutNode[], edges: LaidOutEdge[]): LaidOutNode[] {
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const outs = new Map<string, string[]>()
  for (const e of edges) outs.set(e.source, [...(outs.get(e.source) ?? []), e.target])
  const seen = new Set<string>()
  const order: LaidOutNode[] = []
  const visit = (start: string) => {
    const stack = [start]
    while (stack.length > 0) {
      const id = stack.pop()!
      if (seen.has(id)) continue
      seen.add(id)
      const n = byId.get(id)
      if (n) order.push(n)
      const next = outs.get(id) ?? []
      for (let i = next.length - 1; i >= 0; i--) if (!seen.has(next[i])) stack.push(next[i])
    }
  }
  for (const n of nodes) if (n.nodeType === 'START') visit(n.id)
  for (const n of nodes) if (!seen.has(n.id)) visit(n.id)
  return order
}

export interface StepsListProps {
  nodes: LaidOutNode[]
  edges: LaidOutEdge[]
  path?: InstancePath | null
  selectedId?: string | null
  onSelect?: (id: string) => void
}

export function StepsList({ nodes, edges, path, selectedId, onSelect }: StepsListProps) {
  const intl = useIntl()
  const t = useDiagramText()
  const labelOf = new Map(nodes.map((n) => [n.id, n.label ?? t.typeName(n.nodeType)]))
  return (
    <ol className="lf-pd-steps" aria-label={intl.formatMessage({ id: 'processDiagram.stepsLabel' })} data-testid="diagram-steps">
      {readingOrder(nodes, edges).map((n, i) => {
        const st = path?.nodes.get(n.id)?.state
        const outs = edges.filter((e) => e.source === n.id)
        return (
          <li key={n.id} className={`lf-pd-steps__item${st ? ` is-${st}` : ''}`} data-testid="diagram-step" data-node-id={n.id}>
            <span className="lf-pd-steps__num">{i + 1}</span>
            <div className="lf-pd-steps__main">
              <button
                type="button"
                className="lf-pd-steps__button"
                aria-pressed={selectedId === n.id}
                onClick={() => onSelect?.(n.id)}
              >
                {labelOf.get(n.id)}
              </button>
              <span className="lf-pd-steps__meta">{t.typeName(n.nodeType)}</span>
              {outs.length > 0 && (
                <ul className="lf-pd-steps__next">
                  {outs.map((e) => (
                    <li key={e.id}>
                      → {labelOf.get(e.target) ?? e.target}
                      {e.condition && (
                        <>
                          {' '}
                          (<span className="lf-pd__mono">{intl.formatMessage({ id: 'processDiagram.details.ifCondition' }, { condition: e.condition })}</span>)
                        </>
                      )}
                      {e.isDefault && ` (${intl.formatMessage({ id: 'processDiagram.edge.default' })})`}
                    </li>
                  ))}
                </ul>
              )}
            </div>
            {st && (
              <StatusPill tone={STATE_PILL[st].tone} glyph={STATE_PILL[st].glyph}>
                {t.stateName(st)}
              </StatusPill>
            )}
          </li>
        )
      })}
    </ol>
  )
}
