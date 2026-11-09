/** DefinitionViewSwitch — T-1520. The "Diagram | Editor" switch of the definition page and the badge that marks a
 *  diagram drawn from unsaved editor changes. Rendered inside ProcessDiagramIntlProvider (page-local catalogue). */
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { StatusPill } from '@/components/ui/StatusPill'
import { Banner } from '@/components/ui/Banner'

export type DefinitionView = 'diagram' | 'edit' | 'editor'

export interface DefinitionViewSwitchProps {
  view: DefinitionView
  onChange: (view: DefinitionView) => void
  /** The diagram shows the editor's unsaved graph. */
  unsaved: boolean
  /** T-1563: show "Edit diagram" (the caller may design definitions). */
  canEditDiagram?: boolean
  /** T-1563: the diagram draft has unsaved changes; the Editor stays off until it is saved or discarded. */
  editorLocked?: boolean
}

export function DefinitionViewSwitch({ view, onChange, unsaved, canEditDiagram, editorLocked }: DefinitionViewSwitchProps) {
  const intl = useIntl()
  const m = (id: string) => intl.formatMessage({ id: `processDiagram.view.${id}` })
  return (
    <>
      <div className="lf-pd__seg" role="group" aria-label={m('group')} data-testid="definition-view-switch">
        <Button variant="secondary" size="sm" pressed={view === 'diagram'} onClick={() => onChange('diagram')} data-testid="definition-view-diagram">
          {m('diagram')}
        </Button>
        {canEditDiagram && (
          <Button variant="secondary" size="sm" pressed={view === 'edit'} onClick={() => onChange('edit')} data-testid="definition-view-edit">
            {m('edit')}
          </Button>
        )}
        <Button
          variant="secondary"
          size="sm"
          pressed={view === 'editor'}
          disabled={editorLocked}
          title={editorLocked ? m('editorLocked') : undefined}
          onClick={() => onChange('editor')}
          data-testid="definition-view-editor"
        >
          {m('editor')}
        </Button>
      </div>
      {view === 'diagram' && unsaved && (
        <StatusPill tone="warning" glyph="half" data-testid="definition-unsaved-badge">
          {m('unsavedBadge')}
        </StatusPill>
      )}
    </>
  )
}

/** "Edit diagram" was refused because the Editor has unsaved changes (two divergent unsaved states are never allowed). */
export function EditRefusedBanner() {
  const intl = useIntl()
  return (
    <div data-testid="definition-edit-refused">
      <Banner tone="warning">{intl.formatMessage({ id: 'processDiagram.edit.lock.editorDirty' })}</Banner>
    </div>
  )
}
