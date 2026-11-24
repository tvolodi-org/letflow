/** Harness fixtures of T-2601: the property panel of the OLD canvas editor (the React-Flow canvas and its
 *  property panel — the predecessor of the diagram editor). Each screen shows the panel with a node of one
 *  kind selected: the states whose fields the task wired. Invented data; the attribute keys are the graph
 *  model's own (`role`, `assignee_type`, `form_schema`, `script_key`, `script_version`, `duration_iso8601`). */
import type { ReactElement } from 'react'
import { useIntl } from 'react-intl'
import PropertyPanel from '@/components/canvas/PropertyPanel'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'
import type { NodeType } from '@/types/api'
import type { HarnessScreen } from '../types'

function panel(nodeType: NodeType, attributes: Record<string, unknown>): ReactElement {
  const data: CanvasNodeData = { nodeType, name: '', attributes }
  return (
    <PropertyPanel
      selectedNodeId="node-1"
      selectedNodeData={data}
      selectedEdgeId={null}
      onUpdateNode={() => {}}
      onDeleteEdge={() => {}}
      onClose={() => {}}
      isReadOnly={false}
      nodeNames={new Map()}
    />
  )
}

/** The header carries a TRANSLATED eyebrow (the definition catalog), so the ru and kk shots of this screen
 *  really differ from the en one — the old property panel itself is a legacy component with hardcoded
 *  English labels, so nothing inside it changes with the UI language. */
function HarnessHeader({ title }: { title: string }): ReactElement {
  const intl = useIntl()
  return (
    <PageHeader
      eyebrow={intl.formatMessage({ id: 'processDiagram.edit.pageEyebrow' })}
      title={title}
      lede="The property panel of the old canvas editor, with the node selected."
    />
  )
}

function frame(title: string, body: ReactElement): ReactElement {
  return (
    <ProcessDiagramIntlProvider>
      <div className="lf-main">
        <main className="lf-content">
          <HarnessHeader title={title} />
          {body}
        </main>
      </div>
    </ProcessDiagramIntlProvider>
  )
}

export const canvasPropertyPanelScreens: HarnessScreen[] = [
  {
    name: 'canvas-panel-human',
    routes: [],
    render: () =>
      frame(
        'Human task',
        panel('HUMAN_TASK', {
          role: 'HEAD_OF_UNIT',
          assignee_type: 'ROLE',
          form_schema: { type: 'object', properties: { item: { title: 'Item' } } },
        }),
      ),
  },
  {
    name: 'canvas-panel-service',
    routes: [],
    render: () => frame('Service task', panel('SERVICE_TASK', { script_key: 'tenant.register', script_version: 3 })),
  },
  {
    name: 'canvas-panel-service-bound',
    routes: [],
    render: () => frame('Service task', panel('SERVICE_TASK', { service_id: 'budget-api' })),
  },
  {
    name: 'canvas-panel-timer',
    routes: [],
    render: () => frame('Timer', panel('TIMER', { duration_iso8601: 'PT2H' })),
  },
]
