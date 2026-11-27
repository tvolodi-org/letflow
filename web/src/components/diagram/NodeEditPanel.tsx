/** NodeEditPanel — T-1563. The properties of the selected step (or connection) in edit mode: label, the flat attributes of
 *  its type, the script binding as ONE unit, and its connections with Edit / Delete connection buttons (the keyboard path
 *  to an edge). Structured attributes (form, module writes, interface, endpoint) are not edited here and are kept intact.
 *  T-2599 (pilot gap G5a) adds the third route kind of a step: a PLATFORM CALL — the function picker and the typed
 *  var/const argument mapping. Every change is a graphEdit function applied through `onApply`; this file builds no graph
 *  itself. */
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
  removeNotifyStep,
  removePlatformCall,
  replaceServiceWithScript,
  droppedTargets,
  scriptBindingHint,
  setEdge,
  setNodeAttr,
  setNodeLabel,
  setNotifyStep,
  setPlatformCall,
  setScriptBinding,
  setSubProcessChild,
  type EditResult,
} from '@/utils/canvas/graphEdit'
import { emptyPlatformCall, parsePlatformCall, withDerivedMapping } from '@/utils/canvas/platformCall'
import { emptyNotifyStep, parseNotifyStep } from '@/utils/canvas/notifyStep'
import { usePlatformFunctions } from '@/hooks/usePlatformFunctions'
import { useNotificationTemplateCatalogue } from '@/hooks/useNotificationTemplateCatalogue'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { Checkbox } from '@/components/ui/Checkbox'
import { stepCaption } from './nodeSummary'
import { PlatformCallEditor, type PlatformCatalogueState } from './PlatformCallEditor'
import { SubProcessEditor } from './SubProcessEditor'
import { NotifyStepEditor, type NotifyCatalogueState } from './NotifyStepEditor'
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

/** Types the runtime can claim and complete (Tasks.apply_claim/apply_completion_authz); INITIATOR is not one. */
export const ASSIGNEE_TYPES = ['ROLE', 'USER']

export function useEditText() {
  const intl = useIntl()
  return (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.edit.${id}` }, values)
}

export function nodeName(n: GraphNode, typeName: (t: string) => string): string {
  return n.label ?? stepCaption(n.node_type, readAttrs(n)) ?? typeName(n.node_type)
}

interface PanelProps {
  graph: DefinitionGraph
  onApply: ApplyEdit
  onClose: () => void
  onSelectEdge: (id: string) => void
  /** Violation texts anchored to the selected item. */
  problems: string[]
  /** The tenant the catalogue read is scoped to (the page resolves it from the session). */
  tenantId?: string | null
  /** T-2847: the `owner_module` stamp of the definition being edited; decides which children the picker offers. */
  parentOwnerModule?: string | null
}

export function NodeEditPanel({ graph, nodeId, onApply, onClose, onSelectEdge, problems, tenantId = null, parentOwnerModule = null }: PanelProps & { nodeId: string }) {
  const e = useEditText()
  const t = useDiagramText()
  const node = graph.nodes.find((n) => n.id === nodeId)
  const [target, setTarget] = useState('')
  useEffect(() => setTarget(''), [nodeId])
  // T-2599: the COMPILED platform function catalogue the picker offers. The read is lazy — it happens when a
  // SERVICE step's panel is open, not when the page opens.
  const catalogueQuery = usePlatformFunctions(tenantId, node?.node_type === 'SERVICE_TASK')
  const catalogue: PlatformCatalogueState = {
    entries: catalogueQuery.data?.items ?? [],
    loading: catalogueQuery.isPending,
    error: catalogueQuery.error ?? null,
    onRetry: () => void catalogueQuery.refetch(),
  }
  // T-2600: the COMPILED notification template catalogue the template picker reads. The read is lazy, like the
  // platform one: it happens when a SERVICE step's panel is open, not when the page opens.
  const templateQuery = useNotificationTemplateCatalogue(tenantId, node?.node_type === 'SERVICE_TASK')
  const templates: NotifyCatalogueState = {
    entries: templateQuery.data?.items ?? [],
    loading: templateQuery.isPending,
    error: templateQuery.error ?? null,
    onRetry: () => void templateQuery.refetch(),
  }
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
  // T-2599: the step's platform call, with its mapping sides derived against the catalogue entry.
  const rawCall = parsePlatformCall(attrs.platform_call)
  const platformEntry = rawCall ? catalogue.entries.find((x) => x.name === rawCall.function) ?? null : null
  const platformCall = rawCall && platformEntry ? withDerivedMapping(rawCall, platformEntry) : rawCall
  // T-2600: the step's notification (the channel, the template, the recipient and the values).
  const notifyStep = parseNotifyStep(attrs.notify)

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
          <Field label={e('field.assigneeRef')}>
            <input value={text('role')} onChange={(ev) => setAttr('role', ev.target.value)} data-testid="edit-field-role" />
          </Field>
          <Select
            label={e('field.assigneeType')}
            value={text('assignee_type')}
            placeholder={e('field.none')}
            options={ASSIGNEE_TYPES.map((v) => ({ value: v, label: v }))}
            onChange={(v) => setAttr('assignee_type', v)}
          />
        </>
      )}
      {editable && node.node_type === 'SERVICE_TASK' && (
        <>
          {notifyStep ? (
            // T-2600: the step sends a notification — the channel, the template, the recipient and the values.
            <div data-testid="edit-notify-step">
              <NotifyStepEditor
                key={node.id}
                step={notifyStep}
                catalogue={templates}
                onChange={(next) => onApply(setNotifyStep(graph, node.id, next), undefined, `notify:${node.id}`)}
              />
              <Button
                variant="secondary"
                size="sm"
                onClick={() => onApply(removeNotifyStep(graph, node.id), e('announce.notifyStepRemoved'))}
                data-testid="edit-use-script-from-notify"
              >
                {e('notify.useScript')}
              </Button>
            </div>
          ) : (
            <>
          {platformCall ? (
            // T-2599: the step calls a platform function — the picker and the typed argument mapping.
            <div data-testid="edit-platform-call">
              <PlatformCallEditor
                key={node.id}
                call={platformCall}
                catalogue={catalogue}
                onChange={(next) => onApply(setPlatformCall(graph, node.id, next), undefined, `platform:${node.id}`)}
              />
              <Button
                variant="secondary"
                size="sm"
                onClick={() => onApply(removePlatformCall(graph, node.id), e('announce.platformCallRemoved'))}
                data-testid="edit-use-script-from-platform"
              >
                {e('platform.useScript')}
              </Button>
            </div>
          ) : (
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
              {catalogue.entries.length > 0 && (
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => {
                    const first = catalogue.entries[0]
                    onApply(
                      setPlatformCall(graph, node.id, emptyPlatformCall(first.name)),
                      e('announce.platformSelected', { name: first.name }),
                      `platform:${node.id}`,
                    )
                  }}
                  data-testid="edit-use-platform-function"
                >
                  {e('platform.useFunction')}
                </Button>
              )}
              {templates.entries.length > 0 && (
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => {
                    const first = templates.entries[0]
                    onApply(
                      setNotifyStep(graph, node.id, { ...emptyNotifyStep(), templateKey: first.template_key }),
                      e('announce.notifySelected', { name: first.template_key }),
                      `notify:${node.id}`,
                    )
                  }}
                  data-testid="edit-use-notification"
                >
                  {e('notify.useNotification')}
                </Button>
              )}
            </>
          )}
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
        <SubProcessEditor
          tenantId={tenantId}
          parentOwnerModule={parentOwnerModule}
          definitionName={text('definition_name')}
          iface={readAttrs(node).interface}
          onChange={(name, iface) => onApply(setSubProcessChild(graph, node.id, name, iface), undefined, `sub:${node.id}`)}
        />
      )}
      {['HUMAN_TASK', 'SERVICE_TASK'].includes(node.node_type) && <p className="lf-hint">{e('structuredInEditor')}</p>}
      {node.node_type === 'SUB_PROCESS' && <p className="lf-hint">{e('structuredInEditorSub')}</p>}

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
                const res = connect(graph, node.id, target)
                const old = droppedTargets(graph, res, node.id)
                onApply(
                  res,
                  old.length > 0
                    ? e('announce.connectedReplaced', { from: name(node.id), to: name(target), old: old.map(name).join(', ') })
                    : e('announce.connected', { from: name(node.id), to: name(target) }),
                )
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
