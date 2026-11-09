/** NodeDetails — T-1520. The selected step: type, label, id, the known attribute keys only (plain text), outgoing
 *  conditions and its state. Closes on Escape and with its close button (rule 2a). */
import { useEffect } from 'react'
import { useIntl } from 'react-intl'
import { X } from 'lucide-react'
import type { LaidOutEdge, LaidOutNode } from '@/utils/canvas/readLayout'
import type { NodePathState } from '@/utils/canvas/instancePath'
import { Button } from '@/components/ui/Button'
import { StatusPill } from '@/components/ui/StatusPill'
import type { GraphDiff } from '@/utils/canvas/graphDiff'
import { DIFF_PILL, STATE_PILL } from './diagramConfig'
import { summariseNode } from './nodeSummary'
import { useDiagramText } from './useDiagramText'

export interface NodeDetailsProps {
  node: LaidOutNode
  nodes: LaidOutNode[]
  edges: LaidOutEdge[]
  state?: NodePathState
  /** T-1588: a version diff. */
  diff?: GraphDiff | null
  onClose: () => void
}

export function NodeDetails({ node, nodes, edges, state, diff, onClose }: NodeDetailsProps) {
  const intl = useIntl()
  const t = useDiagramText()
  const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.${id}` }, values)
  const labelOf = (id: string) => {
    const n = nodes.find((x) => x.id === id)
    return n ? n.label ?? t.typeName(n.nodeType) : id
  }
  const s = summariseNode(node.nodeType, node.attributes, labelOf)
  const outs = edges.filter((e) => e.source === node.id)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const rows: Array<[string, React.ReactNode]> = [
    [m('details.type'), t.typeName(node.nodeType)],
    [m('details.id'), <span className="lf-pd__mono">{node.id}</span>],
  ]
  if (state) {
    rows.push([
      m('details.state'),
      <StatusPill tone={STATE_PILL[state.state].tone} glyph={STATE_PILL[state.state].glyph}>
        {t.stateName(state.state)}
      </StatusPill>,
    ])
  }
  const nd = diff?.nodes.get(node.id)
  if (nd && nd.kind !== 'unchanged') {
    const k = nd.kind
    const fieldName = (f: string) => (['label', 'node_type'].includes(f) ? m(`diff.field.${f}`) : f)
    rows.push([
      m('details.state'),
      <span data-testid="details-diff">
        <StatusPill tone={DIFF_PILL[k].tone} glyph={DIFF_PILL[k].glyph}>
          {t.diffName(k)}
        </StatusPill>
        {k === 'changed' && nd.fields.length > 0 && (
          <>
            {' '}
            {m('diff.changedFields', { fields: nd.fields.map(fieldName).join(', ') })}
          </>
        )}
      </span>,
    ])
  }
  if (s.role) rows.push([m('details.role'), s.role])
  if (s.assignee) rows.push([m('details.assignee'), s.assignee])
  if (s.formFields && s.formFieldCount !== undefined) {
    rows.push([
      m('details.form', { count: s.formFieldCount }),
      <ul className="lf-pd__plain-list" data-testid="details-form-fields">
        {s.formFields.map((f) => (
          <li key={f.key}>
            {f.title} <span className="lf-pd__mono">{f.key}</span>
          </li>
        ))}
        {s.formFieldCount > s.formFields.length && <li>{m('details.more', { count: s.formFieldCount - s.formFields.length })}</li>}
      </ul>,
    ])
  }
  if (s.validationScript) rows.push([m('details.validation'), <span className="lf-pd__mono">{s.validationScript}</span>])
  if (s.distinctFrom && s.distinctFrom.length > 0) rows.push([m('details.distinct'), s.distinctFrom.join(', ')])
  if (s.writes && s.writes.length > 0) rows.push([m('details.writes'), <span className="lf-pd__mono">{s.writes.join(', ')}</span>])
  if (s.service) rows.push([m('details.service'), <span className="lf-pd__mono">{s.service}</span>])
  if (s.endpointHost !== undefined) {
    rows.push([m('details.endpoint'), s.endpointHost === null ? m('details.endpointSet') : <span className="lf-pd__mono">{s.endpointHost}</span>])
  }
  if (s.script) rows.push([m('details.script'), <span className="lf-pd__mono">{s.script}</span>])
  if (s.scriptVersion) rows.push([m('details.scriptVersion'), <span className="lf-pd__mono">{s.scriptVersion}</span>])
  if (s.timeoutMs) rows.push([m('details.timeout'), <span className="lf-pd__mono">{s.timeoutMs}</span>])
  if (s.duration) rows.push([m('details.duration'), <span className="lf-pd__mono">{s.duration}</span>])
  if (s.subDefinition) rows.push([m('details.subDefinition'), <span className="lf-pd__mono">{s.subDefinition}</span>])
  if (outs.length > 0) {
    rows.push([
      m('details.next'),
      <ul className="lf-pd__plain-list">
        {outs.map((e) => (
          <li key={e.id}>
            → {labelOf(e.target)}
            {e.condition && (
              <>
                {' '}
                <span className="lf-pd__mono">{m('details.ifCondition', { condition: e.condition })}</span>
              </>
            )}
            {e.isDefault && ` (${m('edge.default')})`}
          </li>
        ))}
      </ul>,
    ])
  }
  if (s.otherCount > 0) rows.push(['', m('details.otherAttributes', { count: s.otherCount })])

  return (
    <aside className="lf-pd__details" aria-label={m('details.title')} data-testid="diagram-node-details">
      <div className="lf-pd__details-head">
        <h3 className="lf-pd__details-title">{node.label ?? t.typeName(node.nodeType)}</h3>
        <Button variant="ghost" size="sm" iconOnly icon={<X className="lf-icon" />} label={m('details.close')} onClick={onClose} />
      </div>
      <dl className="lf-pd__dl">
        {rows.map(([k, v], i) => (
          <div key={i} className="lf-pd__dl-row">
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
    </aside>
  )
}
