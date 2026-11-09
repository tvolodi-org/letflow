/** ProcessGraphWithTokens — the instance detail's Graph tab. Since T-1520 (D-114 item 2) it draws the read-only
 *  ProcessDiagram with the instance's live path: status colours from `current_nodes`, `error_detail.affected` and
 *  the full timeline (every page), derived by `deriveInstancePath`. Polls while the instance is ACTIVE. */
import { useMemo } from 'react'
import { useInstance, useInstanceTimelineAll } from '@/hooks/useInstances'
import { useDefinition } from '@/hooks/useDefinitions'
import { useProcessGraphWithTokens } from '@/hooks/useProcessGraphWithTokens'
import { deriveInstancePath, timelineEvidence } from '@/utils/canvas/instancePath'
import { ProcessDiagramLazy } from '@/components/diagram/ProcessDiagramLazy'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'

export interface ProcessGraphWithTokensProps {
  instanceId: string
  definitionId?: string
  onNodeClick?: (nodeId: string) => void
}

export function ProcessGraphWithTokens(props: ProcessGraphWithTokensProps): JSX.Element {
  const { instanceId, definitionId, onNodeClick } = props
  const { data: instance } = useInstance(instanceId)
  const { data: definition } = useDefinition(definitionId || instance?.definition_id || '')
  // Keeps the 2 s instance polling while ACTIVE.
  useProcessGraphWithTokens(instanceId)
  const timeline = useInstanceTimelineAll(instanceId, { status: instance?.status })

  const graph = instance?.definition_snapshot ?? definition?.graph
  const evidence = useMemo(
    () => timelineEvidence(timeline.entries, { complete: timeline.complete }),
    [timeline.entries, timeline.complete],
  )
  const path = useMemo(
    () => (instance && graph ? deriveInstancePath(graph, instance, evidence) : null),
    [instance, graph, evidence],
  )
  const reason = typeof instance?.error_detail?.reason === 'string' ? instance.error_detail.reason : null

  return (
    <ProcessDiagramIntlProvider>
      <div data-testid="instance-process-diagram">
        <ProcessDiagramLazy
          graph={graph}
          path={path}
          errorReason={reason}
          onRetry={timeline.isError || timeline.truncated ? timeline.retry : undefined}
          live={instance?.status === 'ACTIVE'}
          onNodeSelect={(id) => {
            if (id) onNodeClick?.(id)
          }}
        />
      </div>
    </ProcessDiagramIntlProvider>
  )
}
