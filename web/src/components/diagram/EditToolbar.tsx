/** EditToolbar — T-1563. The controls of edit mode: add a step, undo / redo, delete the selection, the validation badge,
 *  Save draft and Discard. Every control has an accessible name; Save is disabled with its reason shown. */
import { Redo2, Trash2, Undo2 } from 'lucide-react'
import { Button } from '@/components/ui/Button'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import type { NodeType } from '@/types/api'
import { NODE_TYPES } from './diagramConfig'
import { useDiagramText } from './useDiagramText'
import { useEditText } from './NodeEditPanel'

export interface EditToolbarProps {
  addType: NodeType
  onAddType: (t: NodeType) => void
  onAdd: () => void
  onUndo: () => void
  onRedo: () => void
  canUndo: boolean
  canRedo: boolean
  onDeleteSelection: () => void
  hasSelection: boolean
  checking: boolean
  /** Counts of blocking / advisory violations in the last check; null while no check has answered. */
  counts: { blocking: number; advisory: number } | null
  checkFailed: boolean
  onSave: () => void
  onDiscard: () => void
  saving: boolean
  /** Why Save is off (shown as text), or null when Save is allowed. */
  saveBlockedReason: string | null
  saveLabel: string
  dirty: boolean
}

export function EditToolbar(p: EditToolbarProps) {
  const e = useEditText()
  const t = useDiagramText()
  return (
    <div className="lf-pd-edit__toolbar" role="toolbar" aria-label={e('toolbar')} data-testid="edit-toolbar">
      <Select
        label={e('addType')}
        value={p.addType}
        options={NODE_TYPES.filter((x) => x !== 'START').map((x) => ({ value: x, label: t.typeName(x) }))}
        onChange={(v) => p.onAddType(v as NodeType)}
        width="s"
      />
      <Button variant="secondary" size="sm" onClick={p.onAdd} data-testid="edit-add">
        {e('add')}
      </Button>
      <Button variant="ghost" size="sm" iconOnly label={e('undo')} icon={<Undo2 className="lf-icon" />} disabled={!p.canUndo} onClick={p.onUndo} data-testid="edit-undo" />
      <Button variant="ghost" size="sm" iconOnly label={e('redo')} icon={<Redo2 className="lf-icon" />} disabled={!p.canRedo} onClick={p.onRedo} data-testid="edit-redo" />
      <Button variant="ghost" size="sm" iconOnly label={e('deleteSelection')} icon={<Trash2 className="lf-icon" />} disabled={!p.hasSelection} onClick={p.onDeleteSelection} data-testid="edit-delete-selection" />
      <span className="lf-pd__toolbar-spacer" />
      <span className="lf-pd-edit__status" data-testid="edit-check-status" role="status">
        {p.checking ? (
          e('checking')
        ) : p.checkFailed ? (
          e('checkFailed')
        ) : p.counts === null ? null : p.counts.blocking + p.counts.advisory === 0 ? (
          <StatusPill tone="success" glyph="dot">{e('valid')}</StatusPill>
        ) : (
          <StatusPill tone={p.counts.blocking > 0 ? 'danger' : 'warning'} glyph={p.counts.blocking > 0 ? 'triangle' : 'half'}>
            {e('problems', { count: p.counts.blocking + p.counts.advisory })}
          </StatusPill>
        )}
      </span>
      <Button variant="primary" size="sm" loading={p.saving} disabled={p.saveBlockedReason !== null || p.saving || !p.dirty} onClick={p.onSave} data-testid="edit-save">
        {p.saveLabel}
      </Button>
      <Button variant="secondary" size="sm" disabled={!p.dirty || p.saving} onClick={p.onDiscard} data-testid="edit-discard">
        {e('discard')}
      </Button>
      {p.saveBlockedReason && (
        <span className="lf-hint lf-pd-edit__reason" data-testid="edit-save-reason">
          {p.saveBlockedReason}
        </span>
      )}
    </div>
  )
}
