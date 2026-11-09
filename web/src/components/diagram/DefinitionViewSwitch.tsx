/** DefinitionViewSwitch — T-1520. The "Diagram | Editor" switch of the definition page and the badge that marks a
 *  diagram drawn from unsaved editor changes. Rendered inside ProcessDiagramIntlProvider (page-local catalogue). */
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { StatusPill } from '@/components/ui/StatusPill'

export type DefinitionView = 'diagram' | 'editor'

export interface DefinitionViewSwitchProps {
  view: DefinitionView
  onChange: (view: DefinitionView) => void
  /** The diagram shows the editor's unsaved graph. */
  unsaved: boolean
}

export function DefinitionViewSwitch({ view, onChange, unsaved }: DefinitionViewSwitchProps) {
  const intl = useIntl()
  const m = (id: string) => intl.formatMessage({ id: `processDiagram.view.${id}` })
  return (
    <>
      <div className="lf-pd__seg" role="group" aria-label={m('group')} data-testid="definition-view-switch">
        <Button variant="secondary" size="sm" pressed={view === 'diagram'} onClick={() => onChange('diagram')} data-testid="definition-view-diagram">
          {m('diagram')}
        </Button>
        <Button variant="secondary" size="sm" pressed={view === 'editor'} onClick={() => onChange('editor')} data-testid="definition-view-editor">
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
