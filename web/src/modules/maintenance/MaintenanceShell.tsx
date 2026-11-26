/** MaintenanceShell — GH 4802 / REQ-898. The frame of the maintenance screens: the page header (eyebrow, title,
 *  lede, at most one primary action) and the query-state boundary (loading skeleton, load error with retry, no
 *  permission). Layout, fields, table, pills and dialogs come from the shared components; nothing here sets a
 *  colour or a spacing. */
import type { ReactNode } from 'react'
import { PageHeader } from '@/components/ui/PageHeader'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import type { RendererState } from '@/utils/classifyError'

export function MaintenanceShell(props: {
  eyebrow: string
  title: string
  lede: string
  actions?: ReactNode
  state: RendererState
  onRetry: () => void
  children: ReactNode
}) {
  const boundaryState = props.state === 'fetch-failure' || props.state === 'loading' ? 'success' : props.state
  return (
    <>
      <PageHeader eyebrow={props.eyebrow} title={props.title} lede={props.lede} actions={props.actions} />
      <QueryStateBoundary state={boundaryState} onRetry={props.onRetry}>
        {props.children}
      </QueryStateBoundary>
    </>
  )
}
