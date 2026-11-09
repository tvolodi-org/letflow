/** ProcessDiagramLazy — T-1520. Loads the diagram chunk on demand, so list pages do not pay for it. */
import { lazy, Suspense } from 'react'
import { Skeleton } from '@/components/ui/Skeleton'
import type { ProcessDiagramProps } from './ProcessDiagram'

const ProcessDiagram = lazy(() => import('./ProcessDiagram'))

export function ProcessDiagramLazy(props: ProcessDiagramProps) {
  return (
    <Suspense
      fallback={
        <div data-testid="diagram-loading" aria-busy="true">
          <Skeleton />
          <Skeleton />
          <Skeleton />
        </div>
      }
    >
      <ProcessDiagram {...props} />
    </Suspense>
  )
}
