/** useDiagramText — T-1520. Translated node type and state names of the process diagram. */
import { useIntl } from 'react-intl'
import type { NodeState } from '@/utils/canvas/instancePath'
import { NODE_TYPES } from './diagramConfig'

export function useDiagramText() {
  const intl = useIntl()
  return {
    typeName: (nodeType: string) =>
      intl.formatMessage({
        id: (NODE_TYPES as readonly string[]).includes(nodeType) ? `processDiagram.type.${nodeType}` : 'processDiagram.type.other',
      }),
    diffName: (kind: 'added' | 'removed' | 'changed') => intl.formatMessage({ id: `processDiagram.diff.${kind}` }),
    stateName: (state: NodeState) => intl.formatMessage({ id: `processDiagram.state.${state}` }),
  }
}
