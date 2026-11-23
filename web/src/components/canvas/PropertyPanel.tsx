import { useState, useCallback, useEffect, useMemo } from 'react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'
import { validateSubProcessInterface } from '@/utils/canvas/interfaceValidation'

interface PropertyPanelProps {
  selectedNodeId: string | null
  selectedNodeData?: CanvasNodeData
  selectedEdgeId: string | null
  onUpdateNode: (nodeId: string, data: Partial<CanvasNodeData>) => void
  onDeleteEdge: (edgeId: string) => void
  onClose: () => void
  isReadOnly: boolean
  /** Map of node id -> node name for displaying source/target labels */
  nodeNames: Map<string, string>
}

export default function PropertyPanel({
  selectedNodeId,
  selectedNodeData,
  selectedEdgeId,
  onUpdateNode,
  onDeleteEdge,
  onClose,
  isReadOnly,
  nodeNames,
}: PropertyPanelProps) {
  const [localName, setLocalName] = useState('')

  // Sync localName when selected node changes
  useEffect(() => {
    setLocalName(selectedNodeData?.name ?? '')
  }, [selectedNodeId, selectedNodeData?.name])

  const handleKeyDown = useCallback(
    (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    },
    [onClose],
  )

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handleKeyDown])

  if (!selectedNodeId && !selectedEdgeId) return null

  const panelStyle: React.CSSProperties = {
    width: 400,
    minWidth: 400,
    background: 'var(--surface-card)',
    borderLeft: '1px solid var(--border-default)',
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    height: '100%',
  }

  return (
    <div data-testid="property-panel" style={panelStyle}>
      {/* Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '12px 16px',
          borderBottom: '1px solid var(--border-default)',
        }}
      >
        <span style={{ fontSize: 'var(--text-sm, 0.875rem)', fontWeight: 600, color: 'var(--text-primary)' }}>
          Properties
        </span>
        <button
          onClick={onClose}
          style={{
            border: 'none',
            background: 'none',
            cursor: 'pointer',
            padding: 4,
            fontSize: 18,
            lineHeight: 1,
            color: 'var(--text-secondary)',
          }}
          aria-label="Close panel"
        >
          ✕
        </button>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: 'auto', padding: 16 }}>
        {selectedEdgeId && (
          <EdgePropertyContent
            edgeId={selectedEdgeId}
            nodeNames={nodeNames}
            onDelete={onDeleteEdge}
            isReadOnly={isReadOnly}
          />
        )}
        {selectedNodeId && (
          <NodePropertyContent
            nodeId={selectedNodeId}
            nodeData={selectedNodeData}
            localName={localName}
            onNameChange={setLocalName}
            onUpdate={onUpdateNode}
            isReadOnly={isReadOnly}
          />
        )}
      </div>
    </div>
  )
}

// ── Node property content ─────────────────────────────────────────────────────

interface NodePropertyContentProps {
  nodeId: string
  nodeData?: CanvasNodeData
  localName: string
  onNameChange: (name: string) => void
  onUpdate: (nodeId: string, data: Partial<CanvasNodeData>) => void
  isReadOnly: boolean
}

function NodePropertyContent({
  nodeId,
  nodeData,
  localName,
  onNameChange,
  onUpdate,
  isReadOnly,
}: NodePropertyContentProps) {
  const nodeType = nodeData?.nodeType

  // ── The node's own attributes ─────────────────────────────────────────────
  // Every field of this panel writes ONE key of the node's attribute map — the
  // key the graph model itself uses (the same keys the diagram editor writes:
  // `role`, `assignee_type`, `form_schema`, `script_key`, `script_version`,
  // `duration_iso8601`). The whole map is kept here, so two fields of the same
  // node cannot overwrite each other, and the seed is the click-time snapshot
  // of the node (the page hands a fresh snapshot on every click), so a typed
  // value survives the re-render that follows the update.
  const [attrs, setAttrs] = useState<Record<string, unknown>>({})

  useEffect(() => {
    setAttrs({ ...((nodeData?.attributes ?? {}) as Record<string, unknown>) })
  }, [nodeId, nodeData])

  /** Writes the given attributes (an `undefined` value removes the key) and hands the whole map back. */
  const updateAttrs = useCallback(
    (patch: Record<string, unknown>) => {
      const next = { ...attrs }
      for (const [key, value] of Object.entries(patch)) {
        if (value === undefined) delete next[key]
        else next[key] = value
      }
      setAttrs(next)
      onUpdate(nodeId, { attributes: next })
    },
    [attrs, nodeId, onUpdate],
  )

  const updateAttr = useCallback(
    (key: string, value: unknown) => updateAttrs({ [key]: value }),
    [updateAttrs],
  )

  /** The value of one attribute as a string (an absent or non-string value reads as empty). */
  const text = useCallback((key: string) => (typeof attrs[key] === 'string' ? (attrs[key] as string) : ''), [attrs])

  // ── SUB_PROCESS interface editor state (SPC-01/SPC-02) ────────────────────
  // The textarea is the source of truth while the user is typing. It is synced
  // from the node attributes only when the selection changes (nodeData is a
  // snapshot taken at click time), so typing never resets the caret/text. A
  // valid parse round-trips through attributes.interface as an object; invalid
  // JSON text is stored as a raw string so the editor-page validator can flag
  // it as `interface` not being a JSON object (SPC-02 NOT_OBJECT rule) and
  // block save until clean. An empty textarea removes the interface entirely,
  // preserving the EXT-05 no-contract path.
  const [interfaceText, setInterfaceText] = useState('')

  useEffect(() => {
    const iface = (nodeData?.attributes ?? {})['interface']
    if (iface === undefined || iface === null) {
      setInterfaceText('')
    } else if (typeof iface === 'string') {
      // Raw text persisted from a previous invalid parse — show it as-is.
      setInterfaceText(iface)
    } else {
      try {
        setInterfaceText(JSON.stringify(iface, null, 2))
      } catch {
        setInterfaceText(String(iface))
      }
    }
    // nodeData is a stale snapshot between re-clicks; syncing on the selection
    // alone keeps this from overwriting in-progress edits.
  }, [nodeId, nodeData])

  const handleInterfaceChange = useCallback(
    (raw: string) => {
      setInterfaceText(raw)
      const trimmed = raw.trim()
      if (trimmed === '') {
        updateAttr('interface', undefined)
        return
      }
      let parsed: unknown
      try {
        parsed = JSON.parse(raw)
      } catch {
        // Store the raw text so the validator can surface the malformed state.
        updateAttr('interface', raw)
        return
      }
      updateAttr('interface', parsed)
    },
    [updateAttr],
  )

  const interfaceStatus = useMemo(() => {
    const trimmed = interfaceText.trim()
    if (trimmed === '') {
      return { kind: 'empty' as const, message: 'No interface declared — EXT-05 behaviour (full map copy/merge).' }
    }
    let parsed: unknown
    try {
      parsed = JSON.parse(interfaceText)
    } catch {
      return { kind: 'error' as const, message: 'Interface is not valid JSON.' }
    }
    const issues = validateSubProcessInterface(parsed)
    if (issues.length > 0) {
      return { kind: 'error' as const, message: issues[0].message }
    }
    return { kind: 'ok' as const, message: 'Interface is a well-formed JSON Schema contract.' }
  }, [interfaceText])

  // ── HUMAN_TASK form schema editor state ──────────────────────────────────
  // The inline form schema of a HUMAN_TASK node is a JSON Schema document
  // (`form_schema` — CHK-20 and `Letflow.Engine.TaskActivation.resolve_form_schema/1`).
  // Unlike the sub-process interface, a malformed value is NOT written: the
  // shape is checked here and the text stays in the textarea with an error, so
  // a definition never carries a form schema the engine would refuse at task
  // activation time.
  const [formSchemaText, setFormSchemaText] = useState('')

  useEffect(() => {
    const fs = (nodeData?.attributes ?? {})['form_schema']
    if (fs === undefined || fs === null) {
      setFormSchemaText('')
    } else if (typeof fs === 'string') {
      setFormSchemaText(fs)
    } else {
      try {
        setFormSchemaText(JSON.stringify(fs, null, 2))
      } catch {
        setFormSchemaText(String(fs))
      }
    }
  }, [nodeId, nodeData])

  const formSchemaStatus = useMemo(() => {
    const trimmed = formSchemaText.trim()
    if (trimmed === '') {
      return { kind: 'empty' as const, message: 'No form schema — the task is created without a form.' }
    }
    let parsed: unknown
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      return { kind: 'error' as const, message: 'Form schema is not valid JSON — it is not saved.' }
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return { kind: 'error' as const, message: 'Form schema must be a JSON object — it is not saved.' }
    }
    return { kind: 'ok' as const, message: 'Form schema is a JSON Schema document.' }
  }, [formSchemaText])

  const handleFormSchemaChange = useCallback(
    (raw: string) => {
      setFormSchemaText(raw)
      const trimmed = raw.trim()
      if (trimmed === '') {
        updateAttr('form_schema', undefined)
        return
      }
      let parsed: unknown
      try {
        parsed = JSON.parse(trimmed)
      } catch {
        return
      }
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return
      updateAttr('form_schema', parsed)
    },
    [updateAttr],
  )

  // ── The values the type-specific fields are bound to ──────────────────────
  // `assignee_type` is the engine's own vocabulary (`ROLE`, `USER`, `GROUP` —
  // `Letflow.Engine.TaskActivation.resolve_assignee/1`); an absent value reads
  // as empty, which is the engine's "derived from the role" case.
  const assigneeType = typeof attrs['assignee_type'] === 'string' ? (attrs['assignee_type'] as string) : ''
  // A service node bound to an HTTP or catalogue service shows its binding (it
  // is not edited here — the diagram editor is where a binding is replaced).
  const boundService = text('service_id') || text('endpoint')
  const scriptVersion = typeof attrs['script_version'] === 'number' ? String(attrs['script_version']) : ''

  // The script key and its version are ONE unit (`Graph.check_service_task_script_reference`
  // needs both), so an empty key removes both and a new key starts at version 1.
  const handleScriptKeyChange = useCallback(
    (key: string) => {
      if (key === '') {
        updateAttrs({ script_key: undefined, script_version: undefined })
        return
      }
      const version = typeof attrs['script_version'] === 'number' ? (attrs['script_version'] as number) : 1
      updateAttrs({ script_key: key, script_version: version })
    },
    [attrs, updateAttrs],
  )

  const handleScriptVersionChange = useCallback(
    (raw: string) => {
      if (raw.trim() === '') {
        updateAttrs({ script_version: undefined })
        return
      }
      const version = Number(raw)
      if (!Number.isInteger(version) || version < 1) return
      updateAttrs({ script_version: version })
    },
    [updateAttrs],
  )

  function renderTypeSpecificFields() {
    switch (nodeType) {
      case 'HUMAN_TASK':
        return (
          <>
            <Field label="Assignee Type">
              <select
                data-testid="prop-assignee-type"
                value={assigneeType}
                onChange={(e) => updateAttr('assignee_type', e.target.value === '' ? undefined : e.target.value)}
                disabled={isReadOnly}
                style={inputStyle(isReadOnly)}
              >
                <option value="">Not set</option>
                <option value="ROLE">Role</option>
                <option value="USER">User</option>
                <option value="GROUP">Group</option>
              </select>
            </Field>
            <Field label="Assignee Ref">
              <input
                data-testid="prop-assignee-ref"
                value={text('role')}
                onChange={(e) => updateAttr('role', e.target.value === '' ? undefined : e.target.value)}
                disabled={isReadOnly}
                placeholder="Assignee reference"
                style={inputStyle(isReadOnly)}
              />
            </Field>
            <Field label="Form Schema">
              <textarea
                data-testid="prop-form-schema"
                value={formSchemaText}
                onChange={(e) => handleFormSchemaChange(e.target.value)}
                disabled={isReadOnly}
                placeholder="JSON Schema"
                rows={4}
                aria-describedby="prop-form-schema-status"
                style={inputStyle(isReadOnly)}
              />
            </Field>
            <div
              id="prop-form-schema-status"
              data-testid="prop-form-schema-status"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                fontSize: 'var(--text-xs, 0.75rem)',
                color:
                  formSchemaStatus.kind === 'error'
                    ? 'var(--color-error-dark)'
                    : formSchemaStatus.kind === 'ok'
                      ? 'var(--color-success-dark)'
                      : 'var(--text-secondary)',
              }}
            >
              <span aria-hidden="true">
                {formSchemaStatus.kind === 'error' ? '✗' : formSchemaStatus.kind === 'ok' ? '✓' : '·'}
              </span>
              <span>{formSchemaStatus.message}</span>
            </div>
          </>
        )
      case 'SERVICE_TASK':
        return (
          <>
            {boundService !== '' && (
              <Field label="Bound Service">
                <div
                  data-testid="prop-service-bound"
                  style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-primary)' }}
                >
                  {boundService}
                </div>
              </Field>
            )}
            <Field label="Script Key">
              <input
                data-testid="prop-service-script-key"
                value={text('script_key')}
                onChange={(e) => handleScriptKeyChange(e.target.value)}
                disabled={isReadOnly}
                placeholder="e.g. tenant.register"
                style={inputStyle(isReadOnly)}
              />
            </Field>
            <Field label="Script Version">
              <input
                data-testid="prop-service-script-version"
                type="number"
                min={1}
                step={1}
                value={scriptVersion === '' ? '' : String(scriptVersion)}
                onChange={(e) => handleScriptVersionChange(e.target.value)}
                disabled={isReadOnly || text('script_key') === ''}
                style={inputStyle(isReadOnly)}
              />
            </Field>
            {text('script_key') === '' && (
              <p
                data-testid="prop-service-script-version-hint"
                style={{ fontSize: 'var(--text-xs, 0.75rem)', color: 'var(--text-secondary)' }}
              >
                Set the script key first — the version belongs to it.
              </p>
            )}
          </>
        )
      case 'TIMER':
        return (
          <Field label="Timer Duration">
            <input
              data-testid="prop-timer-duration"
              value={text('duration_iso8601')}
              onChange={(e) => updateAttr('duration_iso8601', e.target.value === '' ? undefined : e.target.value)}
              disabled={isReadOnly}
              placeholder="e.g. PT1H"
              style={inputStyle(isReadOnly)}
            />
          </Field>
        )
      case 'SUB_PROCESS':
        return (
          <>
            <Field label="Interface (inputs/outputs contract)">
              <textarea
                data-testid="prop-sub-process-interface"
                value={interfaceText}
                onChange={(e) => handleInterfaceChange(e.target.value)}
                disabled={isReadOnly}
                placeholder={'{\n  "inputs": [\n    { "name": "customer_id", "json_schema": { "type": "string" }, "required": true }\n  ],\n  "outputs": []\n}'}
                rows={8}
                spellCheck={false}
                aria-describedby="prop-sub-process-interface-status"
                style={{
                  ...inputStyle(isReadOnly),
                  fontFamily: 'var(--font-mono, monospace)',
                  fontSize: 'var(--text-xs, 0.75rem)',
                  whiteSpace: 'pre',
                  resize: 'vertical',
                }}
              />
            </Field>
            <div
              id="prop-sub-process-interface-status"
              data-testid="prop-sub-process-interface-status"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                fontSize: 'var(--text-xs, 0.75rem)',
                color:
                  interfaceStatus.kind === 'error'
                    ? 'var(--color-error-dark)'
                    : interfaceStatus.kind === 'ok'
                      ? 'var(--color-success-dark)'
                      : 'var(--text-secondary)',
              }}
            >
              <span aria-hidden="true">
                {interfaceStatus.kind === 'error' ? '✗' : interfaceStatus.kind === 'ok' ? '✓' : '·'}
              </span>
              <span>{interfaceStatus.message}</span>
            </div>
          </>
        )
      default:
        // START, END, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY — no type-specific fields
        return null
    }
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* Node ID indicator */}
      <div>
        <span
          style={{
            fontSize: 'var(--text-xs, 0.75rem)',
            color: 'var(--text-secondary)',
            textTransform: 'uppercase',
            letterSpacing: '0.5px',
          }}
        >
          Node: {nodeId} ({nodeType ?? 'unknown'})
        </span>
      </div>

      <Field label="Name">
        <input
          data-testid="prop-name-input"
          value={localName}
          onChange={(e) => {
            onNameChange(e.target.value)
            onUpdate(nodeId, { name: e.target.value })
          }}
          disabled={isReadOnly}
          placeholder="Node name"
          style={inputStyle(isReadOnly)}
        />
      </Field>

      {renderTypeSpecificFields()}

      <p style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-secondary)' }}>
        Select a node on the canvas to edit its properties. Changes are saved locally until you click Save.
      </p>
    </div>
  )
}

// ── Edge property content ─────────────────────────────────────────────────────

interface EdgePropertyContentProps {
  edgeId: string
  nodeNames: Map<string, string>
  onDelete: (edgeId: string) => void
  isReadOnly: boolean
}

function EdgePropertyContent({
  edgeId,
  nodeNames,
  onDelete,
  isReadOnly,
}: EdgePropertyContentProps) {
  // Edge data is in ProcessCanvas; we can only show IDs and names here
  const parts = edgeId.replace('rf-edge-', '').split('-')
  const sourceId = parts[0] ?? ''
  const targetId = parts.slice(1).join('-')
  const sourceName = nodeNames.get(sourceId) ?? sourceId
  const targetName = nodeNames.get(targetId) ?? targetId

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <Field label="Connection">
        <div style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-primary)' }}>
          {sourceName} → {targetName}
        </div>
      </Field>

      <p style={{ fontSize: 'var(--text-sm, 0.875rem)', color: 'var(--text-secondary)' }}>
        Select an edge on the canvas and use the Delete/Backspace key to remove it.
      </p>

      {!isReadOnly && (
        <div style={{ marginTop: 8 }}>
          <button
            data-testid="edge-delete-btn"
            onClick={() => {
              if (window.confirm('Delete this edge?')) onDelete(edgeId)
            }}
            style={{
              padding: '6px 16px',
              border: 'none',
              borderRadius: 4,
              background: 'var(--interactive-danger)',
              color: 'var(--text-inverse)',
              cursor: 'pointer',
              fontSize: 'var(--text-sm, 0.875rem)',
              fontWeight: 500,
            }}
          >
            Delete Edge
          </button>
        </div>
      )}
    </div>
  )
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label
        style={{
          display: 'block',
          fontSize: 'var(--text-sm, 0.875rem)',
          fontWeight: 500,
          marginBottom: 4,
          color: 'var(--text-primary)',
        }}
      >
        {label}
      </label>
      {children}
    </div>
  )
}

function inputStyle(isReadOnly: boolean): React.CSSProperties {
  return {
    width: '100%',
    padding: '6px 8px',
    border: '1px solid var(--border-default)',
    borderRadius: 4,
    fontSize: 'var(--text-sm, 0.875rem)',
    boxSizing: 'border-box',
    background: isReadOnly ? 'var(--color-neutral-50)' : 'var(--surface-card)',
    cursor: isReadOnly ? 'not-allowed' : undefined,
    color: isReadOnly ? 'var(--text-secondary)' : undefined,
  }
}
