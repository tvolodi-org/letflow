/** Harness fixture of the shared load states (T-1185): FetchError and SkeletonLayout through QueryStateBoundary.
 *  `query-states`: state=loading shows the skeleton rows, state=error the danger banner with Retry. Dev only. */
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { HarnessScreen } from '../types'

export const queryStatesScreens: HarnessScreen[] = [
  {
    name: 'query-states',
    routes: [],
    render: ({ state }) => (
      <div className="lf-form">
        <PageHeader eyebrow="Fixture" title="Query states" lede="Loading and load error of the shared boundary." />
        <QueryStateBoundary
          state={state === 'loading' ? 'loading' : state === 'error' ? 'fetch-failure' : 'success'}
          onRetry={() => undefined}
          columns={[{ widthPercent: 30 }, { widthPercent: 50 }, { widthPercent: 20 }]}
        >
          <p>Loaded content.</p>
        </QueryStateBoundary>
      </div>
    ),
  },
]
