/** NodeEditPanel — T-1563. The properties of the selected step (or connection) in edit mode: label, the flat attributes of
 *  its type, the script binding as ONE unit, and its connections with Edit / Delete connection buttons (the keyboard path
 *  to an edge). Structured attributes (form, module writes, interface, endpoint) are not edited here and are kept intact.
 *  Every change is a graphEdit function applied through `onApply`; this file builds no graph itself. */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { X } from 'lucide-react'
import type { DefinitionGraph, GraphEdge, GraphNode } from '@/types/api'
import {
  attributesEditable,
  connect,
  connectionRefusal,
  deleteEdges,
  deleteNodes,
  hasServiceBinding,
  readAttrs,
  replaceServiceWithScript,
  scriptBindingHint,
  setEdge,
  setNodeAttr,
  setNodeLabel,
  setScriptBinding,
  type EditResult,
} from '@/utils/canvas/graphEdit'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { Checkbox } from '@/components/ui/Checkbox'
import { useDiagramText } from './useDiagramText'

export type ApplyEdit = (result: EditResult, announce?: string, coalesceKey?: string) => void

/** Scheme and host of an endpoint only (a path or query may carry a token). */
function summaryEndpoint(raw: string): string {
  try {
    return raw ? new URL(raw).host : '—'
  } catch {
    return '—'
  }
}

const ASSIGNEE_TYPES = ['ROLE', 'USER', 'INITIATOR']

export function useEditText() {
  const intl = useIntl()
  return (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.edit.${id}` }, values)
}

export function nodeName(n: GraphNode, typeName: (t: string) => string): string {
  return n.label ?? typeName(n.node_type)
}

interface PanelProps {
  graph: DefinitionGraph
  onApply: ApplyEdit
  onClose: () => void
  onSelectEdge: (id: string) => void
  /** Violation texts anchored to the selected item. */
  problems: string[]
}

export function NodeEditPanel({ graph, nodeId, onApply, onClose, onSelectEdge, problems }: PanelProps & { nodeId: string }) {
  const e = useEditText()
  const t = useDiagramText()
  const node = graph.nodes.find((n) => n.id === nodeId)
  const [target, setTarget] = useState('')
  useEffect(() => setTarget(''), [nodeId])
  if (!node) return null
  const attrs = readAttrs(node)
  const editable = attributesEditable(node)
  const text = (k: string) => (typeof attrs[k] === 'string' ? (attrs[k] as string) : '')
  const setAttr = (key: string, value: string) => onApply(setNodeAttr(graph, node.id, key, value), undefined, `attr:${node.id}:${key}`)
  const name = (id: string) => {
    const n = graph.nodes.find((x) => x.id === id)
    return n ? nodeName(n, t.typeName) : id
  }
  const outs = graph.edges.filter((x) => x.source === node.id)
  const ins = graph.edges.filter((x) => x.target === node.id)
  const targets = graph.nodes.filter((n) => connectionRefusal(graph, node.id, n.id) === null)

  const scriptKey = text('script_key')
  const scriptVersion = attrs.script_version
  const hint = scriptBindingHint(scriptKey, scriptVersion)
  const bound = node.node_type === 'SERVICE_TASK' && hasServiceBinding(node)

  const edgeRow = (edge: GraphEdge, arrow: string) => (
    <li key={edge.id} className="lf-pd-edit__conn" data-testid="edit-connection-row">
      <span className="lf-pd-edit__conn-text">
        {arrow}
        {edge.condition ? <span className="lf-pd__mono"> [{edge.condition}]</span> : null}
        {edge.is_default ? ` (${e('edgeDefault')})` : ''}
      </span>
      <Button variant="ghost" size="sm" onClick={() => onSelectEdge(edge.id)} data-testid="edit-connection-edit">
        {e('connectionEdit')}
      </Button>
      <Button
        variant="ghost"
        size="sm"
        onClick={() => onApply(deleteEdges(graph, [edge.id]), e('announce.connectionDeleted'))}
        data-testid="edit-connection-delete"
      >
        {e('connectionDelete')}
      </Button>
    </li>
  )

  return (
    <aside className="lf-pd__details lf-pd-edit__panel" aria-label={e('panel.node')} data-testid="edit-node-panel">
      <header className="lf-pd__details-head">
        <h3 className="lf-pd__details-title">{nodeName(node, t.typeName)}</h3>
        <Button variant="ghost" size="sm" iconOnly label={e('panel.close')} icon={<X className="lf-icon" />} onClick={onClose} data-testid="edit-panel-close" />
      </header>
      <p className="lf-pd__mono lf-pd-edit__id">{node.id} · {t.typeName(node.node_type)}</p>
      {problems.length > 0 && (
        <ul className="lf-pd-edit__problems" data-testid="edit-node-problems">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
      <Field label={e('field.label')}>
        <input
          value={node.label ?? ''}
          onChange={(ev) => onApply(setNodeLabel(graph, node.id, ev.target.value), undefined, `label:${node.id}`)}
          data-testid="edit-field-label"
        />
      </Field>
      {!editable && <p className="lf-hint" data-testid="edit-attrs-locked">{e('attrsLocked')}</p>}
      {editable && node.node_type === 'HUMAN_TASK' && (
        <>
          <Field label={e('field.role')}>
            <input value={text('role')} onChange={(ev) => setAttr('role', ev.target.value)} data-testid="edit-field-role" />
          </Field>
          <Select
            label={e('field.assigneeType')}
            value={text('assignee_type')}
            placeholder={e('field.none')}
            options={ASSIGNEE_TYPES.map((v) => ({ value: v, label: v }))}
            onChange={(v) => setAttr('assignee_type', v)}
          />
          <Field label={e('field.assigneeRef')}>
            <input value={text('assignee_ref')} onChange={(ev) => setAttr('assignee_ref', ev.target.value)} data-testid="edit-field-assignee-ref" />
          </Field>
        </>
      )}
      {editable && node.node_type === 'SERVICE_TASK' && (
        <>
          {bound && (
            <div data-testid="edit-service-bound">
              <p className="lf-hint">
                {e('service.bound')}: <span className="lf-pd__mono">{text('service_id') || summaryEndpoint(text('endpoint'))}</span>
              </p>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => onApply(replaceServiceWithScript(graph, node.id, 'new_script'), e('announce.scriptReplaced'))}
                data-testid="edit-use-script"
              >
                {e('service.useScript')}
              </Button>
            </div>
          )}
          {!bound && (
            <>
              <Field
                label={e('field.scriptKey')}
                error={hint === 'bad_key' ? e('hint.badKey') : undefined}
                hint={e('hint.scriptKey')}
              >
                <input
                  value={scriptKey}
                  onChange={(ev) => onApply(setScriptBinding(graph, node.id, { key: ev.target.value }), undefined, `script:${node.id}`)}
                  data-testid="edit-field-script-key"
                />
              </Field>
              <Field label={e('field.scriptVersion')} error={hint === 'bad_version' ? e('hint.badVersion') : undefined}>
                <input
                  type="number"
                  min={1}
                  step={1}
                  disabled={scriptKey === ''}
                  value={typeof scriptVersion === 'number' ? scriptVersion : ''}
                  onChange={(ev) =>
                    onApply(setScriptBinding(graph, node.id, { key: scriptKey, version: ev.target.value === '' ? NaN : Number(ev.target.value) }), undefined, `scriptv:${node.id}`)
                  }
                  data-testid="edit-field-script-version"
                />
              </Field>
            </>
          )}
        </>
      )}
      {editable && node.node_type === 'TIMER' && (
        <Field label={e('field.duration')} hint="PT15M">
          <input value={text('duration_iso8601')} onChange={(ev) => setAttr('duration_iso8601', ev.target.value)} data-testid="edit-field-duration" />
        </Field>
      )}
      {editable && node.node_type === 'SUB_PROCESS' && (
        <Field label={e('field.subDefinition')}>
          <input value={text('definition_name')} onChange={(ev) => setAttr('definition_name', ev.target.value)} data-testid="edit-field-sub-definition" />
        </Field>
      )}
      {['HUMAN_TASK', 'SERVICE_TASK', 'SUB_PROCESS'].includes(node.node_type) && <p className="lf-hint">{e('structuredInEditor')}</p>}

      <section aria-label={e('connections')} data-testid="edit-connections">
        <h4>{e('connections')}</h4>
        {ins.length + outs.length === 0 && <p className="lf-hint">{e('noConnections')}</p>}
        <ul className="lf-pd-edit__conns">
          {ins.map((x) => edgeRow(x, `${name(x.source)} → ${name(node.id)}`))}
          {outs.map((x) => edgeRow(x, `${name(node.id)} → ${name(x.target)}`))}
        </ul>
        {node.node_type !== 'END' && (
          <div className="lf-pd-edit__connect">
            <Select
              label={e('connectFrom')}
              value={target}
              placeholder={e('connectPick')}
              options={targets.map((n) => ({ value: n.id, label: name(n.id) }))}
              onChange={setTarget}
            />
            <Button
              variant="secondary"
              size="sm"
              disabled={target === ''}
              onClick={() => {
                onApply(connect(graph, node.id, target), e('announce.connected', { from: name(node.id), to: name(target) }))
                setTarget('')
              }}
              data-testid="edit-connect-go"
            >
              {e('connectGo')}
            </Button>
          </div>
        )}
      </section>

      {node.node_type !== 'START' && (
        <Button variant="danger" size="sm" onClick={() => onApply(deleteNodes(graph, [node.id]), e('announce.deleted', { name: name(node.id) }))} data-testid="edit-delete-node">
          {e('deleteStep')}
        </Button>
      )}
    </aside>
  )
}

export function EdgeEditPanel({ graph, edgeId, onApply, onClose, problems }: Omit<PanelProps, 'onSelectEdge'> & { edgeId: string }) {
  const e = useEditText()
  const t = useDiagramText()
  const edge = graph.edges.find((x) => x.id === edgeId)
  if (!edge) return null
  const name = (id: string) => {
    const n = graph.nodes.find((x) => x.id === id)
    return n ? nodeName(n, t.typeName) : id
  }
  return (
    <aside className="lf-pd__details lf-pd-edit__panel" aria-label={e('panel.edge')} data-testid="edit-edge-panel">
      <header className="lf-pd__details-head">
        <h3 className="lf-pd__details-title">{name(edge.source)} → {name(edge.target)}</h3>
        <Button variant="ghost" size="sm" iconOnly label={e('panel.close')} icon={<X className="lf-icon" />} onClick={onClose} data-testid="edit-panel-close" />
      </header>
      {problems.length > 0 && (
        <ul className="lf-pd-edit__problems" data-testid="edit-edge-problems">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
      <Field label={e('field.condition')} hint={e('hint.condition')} mono>
        <input
          value={edge.condition ?? ''}
          onChange={(ev) => onApply(setEdge(graph, edge.id, { condition: ev.target.value }), undefined, `cond:${edge.id}`)}
          data-testid="edit-field-condition"
        />
      </Field>
      <Checkbox
        label={e('field.isDefault')}
        checked={edge.is_default === true}
        onChange={(v) => onApply(setEdge(graph, edge.id, { is_default: v }))}
        data-testid="edit-field-default"
      />
      <Button variant="danger" size="sm" onClick={() => onApply(deleteEdges(graph, [edge.id]), e('announce.connectionDeleted'))} data-testid="edit-delete-edge">
        {e('connectionDelete')}
      </Button>
    </aside>
  )
}
