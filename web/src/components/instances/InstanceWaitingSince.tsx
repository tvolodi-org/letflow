/** InstanceWaitingSince — T-1705 (REQ-812). The "Waiting since" block of the instance page: the recorded steps of a
 *  running instance that still wait, since when and for how long. Read from the NODE_ENTERED events the Replay reads
 *  (`useInstanceNodeEntries`, same query key, paging, page cap and polling); nothing is inferred and no request of its
 *  own is made. Shown only for an ACTIVE instance. The elapsed text moves on a 60 s timer that makes no request. */
import { useEffect, useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useInstanceNodeEntries } from '@/hooks/useInstances'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { formatDateTime } from '@/i18n/format'
import { elapsedParts, replayCoverage, replaySteps, waitingSince } from '@/utils/canvas/instanceReplay'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { useDiagramText } from '@/components/diagram/useDiagramText'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Skeleton } from '@/components/ui/Skeleton'
import type { DefinitionGraph } from '@/types/api'
import '@/styles/process-diagram.css'

export interface InstanceWaitingSinceProps {
  instanceId: string
  status: string | undefined
  graph: DefinitionGraph | null | undefined
  /** Time zone of the shown times; the browser's when absent (tests pin UTC). */
  timeZone?: string
}

export function InstanceWaitingSince(props: InstanceWaitingSinceProps): JSX.Element | null {
  if (props.status !== 'ACTIVE') return null
  return (
    <ProcessDiagramIntlProvider>
      <WaitingBody {...props} />
    </ProcessDiagramIntlProvider>
  )
}

function WaitingBody({ instanceId, status, graph, timeZone }: InstanceWaitingSinceProps): JSX.Element {
  const intl = useIntl()
  const t = useDiagramText()
  const locale = useUiLocale()
  const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.waiting.${id}` }, values)
  const recorded = useInstanceNodeEntries(instanceId, { status })
  const steps = useMemo(() => replaySteps(recorded.entries, graph), [recorded.entries, graph])
  const coverage = replayCoverage(steps)
  const rows = useMemo(() => waitingSince(steps, graph), [steps, graph])

  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(id)
  }, [])

  const time = (d: Date) => formatDateTime(d, { second: 'numeric', ...(timeZone ? { timeZone } : {}) }, locale)
  const elapsed = (d: Date) => {
    const { h, m: min } = elapsedParts(now - d.getTime())
    return h > 0 ? m('elapsedHM', { h, m: min }) : min > 0 ? m('elapsedM', { m: min }) : m('elapsedUnderMin')
  }
  const retry = (
    <Button variant="secondary" size="sm" onClick={recorded.retry}>
      {intl.formatMessage({ id: 'processDiagram.retry' })}
    </Button>
  )

  let body: JSX.Element
  if (recorded.isError) {
    // Rows stay hidden: a missing page could drop the last entry of a node and list a wrong "since".
    body = (
      <Banner tone="danger" action={retry}>
        {m('loadError')}
      </Banner>
    )
  } else if (recorded.truncated) {
    body = <Banner tone="warning">{m('truncated')}</Banner>
  } else if (recorded.isLoading || !recorded.complete) {
    body = (
      <div aria-busy="true">
        <Skeleton />
      </div>
    )
  } else if (coverage === 'none') {
    body = <Banner tone="info">{m('none')}</Banner>
  } else {
    body = (
      <>
        {coverage === 'partial' && <Banner tone="warning">{m('partial', { time: time(steps[0]!.at) })}</Banner>}
        {rows.length === 0 ? (
          <p className="lf-waiting__empty">{m('empty')}</p>
        ) : (
          <ul className="lf-waiting__list">
            {rows.map((r) => {
              const valid = !Number.isNaN(r.at.getTime())
              return (
                <li key={r.nodeId} className="lf-waiting__row" data-testid={`waiting-row-${r.nodeId}`}>
                  <span className="lf-waiting__label">
                    {r.known ? r.label ?? t.typeName(r.nodeType) : intl.formatMessage({ id: 'processDiagram.replay.unknownStep' }, { id: r.nodeId || '—' })}
                  </span>
                  {valid ? (
                    <>
                      <time className="lf-waiting__time" dateTime={r.at.toISOString()}>
                        {m('since', { time: time(r.at) })}
                      </time>
                      <span className="lf-waiting__elapsed">{m('waitingFor', { elapsed: elapsed(r.at) })}</span>
                    </>
                  ) : (
                    <span className="lf-waiting__time">—</span>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </>
    )
  }

  return (
    <section className="lf-waiting" aria-labelledby={`lf-waiting-${instanceId}`} data-testid="waiting-since">
      <h4 id={`lf-waiting-${instanceId}`} className="lf-waiting__title">
        {m('title')}
      </h4>
      {body}
    </section>
  )
}
