/** InstanceReplay — T-1635 (REQ-799). The Replay view of the instance Graph tab: step through the recorded path of one
 *  instance (NODE_ENTERED events, REQ-793) on the read-only diagram, in order, with the time of each step. Nothing is
 *  inferred: the path after step k comes from `replayPath` (utils/canvas/instanceReplay). While the instance is ACTIVE
 *  the view follows the last step unless the user has chosen another one. An instance with no recorded steps shows a
 *  banner and the Live view; one whose first recorded step is not START shows a "not recorded before" banner. */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useInstance, useInstanceNodeEntries } from '@/hooks/useInstances'
import { useDefinition } from '@/hooks/useDefinitions'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { formatDateTime } from '@/i18n/format'
import { durationParts, replayCoverage, replayPath, replaySteps, type ReplayStep } from '@/utils/canvas/instanceReplay'
import { ProcessDiagramLazy } from '@/components/diagram/ProcessDiagramLazy'
import { ProcessDiagramIntlProvider } from '@/components/diagram/ProcessDiagramIntlProvider'
import { useDiagramText } from '@/components/diagram/useDiagramText'
import { ProcessGraphWithTokens } from './ProcessGraphWithTokens'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Skeleton } from '@/components/ui/Skeleton'
import '@/styles/process-diagram.css'

export interface InstanceReplayProps {
  instanceId: string
  /** Time zone of the shown times; the browser's when absent (tests pin UTC). */
  timeZone?: string
  /** The step shown first (0-based); absent = follow the last step. Used by the screen harness. */
  initialStep?: number
}

export function InstanceReplay(props: InstanceReplayProps): JSX.Element {
  return (
    <ProcessDiagramIntlProvider>
      <ReplayBody {...props} />
    </ProcessDiagramIntlProvider>
  )
}

/** The Live | Replay switch of the Graph tab (Live is the default; the page keeps the choice). */
export function GraphModeSwitch(props: { mode: 'live' | 'replay'; onChange: (mode: 'live' | 'replay') => void }): JSX.Element {
  return (
    <ProcessDiagramIntlProvider>
      <GraphModeButtons {...props} />
    </ProcessDiagramIntlProvider>
  )
}

function GraphModeButtons({ mode, onChange }: { mode: 'live' | 'replay'; onChange: (mode: 'live' | 'replay') => void }) {
  const intl = useIntl()
  const m = (id: string) => intl.formatMessage({ id: `processDiagram.replay.${id}` })
  return (
    <div className="lf-replay__mode" role="group" aria-label={m('modeGroup')} data-testid="graph-mode-switch">
      <Button variant="ghost" size="sm" pressed={mode === 'live'} onClick={() => onChange('live')} data-testid="graph-mode-live">
        {m('modeLive')}
      </Button>
      <Button variant="ghost" size="sm" pressed={mode === 'replay'} onClick={() => onChange('replay')} data-testid="graph-mode-replay">
        {m('modeReplay')}
      </Button>
    </div>
  )
}

function ReplayBody({ instanceId, timeZone, initialStep }: InstanceReplayProps): JSX.Element {
  const intl = useIntl()
  const t = useDiagramText()
  const locale = useUiLocale()
  const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.replay.${id}` }, values)
  const { data: instance } = useInstance(instanceId)
  const { data: definition } = useDefinition(instance?.definition_id ?? '')
  const recorded = useInstanceNodeEntries(instanceId, { status: instance?.status })
  const graph = instance?.definition_snapshot ?? definition?.graph

  const steps = useMemo(() => replaySteps(recorded.entries, graph), [recorded.entries, graph])
  const coverage = replayCoverage(steps)
  // null = follow the last step (default; a running instance keeps moving); a number = the step the user chose.
  const [chosen, setChosen] = useState<number | null>(initialStep ?? null)
  const n = steps.length
  const k = n === 0 ? -1 : chosen === null ? n - 1 : Math.min(Math.max(chosen, 0), n - 1)
  const path = useMemo(() => replayPath(steps, k, graph), [steps, k, graph])

  const choose = (i: number) => setChosen(i >= n - 1 ? null : Math.max(i, 0))
  const time = (d: Date) => formatDateTime(d, { second: 'numeric', ...(timeZone ? { timeZone } : {}) }, locale)
  const nameOf = (s: ReplayStep) =>
    s.known ? s.label ?? t.typeName(s.nodeType) : m('unknownStep', { id: s.nodeId || '—' })
  const fromName = (s: ReplayStep) => {
    if (!s.fromNodeId) return null
    if (s.fromLabel) return s.fromLabel
    const graphNode = graph?.nodes?.find((x) => x.id === s.fromNodeId)
    return t.typeName(graphNode?.node_type ?? '')
  }
  const since = (ms: number | null) => {
    if (ms === null) return null
    const p = durationParts(ms)
    const duration = !p
      ? m('underSecond')
      : p.h > 0
        ? m('durationH', { h: p.h, m: p.m })
        : p.m > 0
          ? m('durationM', { m: p.m, s: p.s })
          : m('durationS', { s: p.s })
    return m('since', { duration })
  }

  if (recorded.isLoading) {
    return (
      <div className="lf-replay" data-testid="instance-replay" aria-busy="true">
        <Skeleton />
        <Skeleton />
        <Skeleton />
      </div>
    )
  }
  if (recorded.isError && n === 0) {
    return (
      <div className="lf-replay" data-testid="instance-replay">
        <Banner
          tone="danger"
          action={
            <Button variant="secondary" size="sm" onClick={recorded.retry}>
              {intl.formatMessage({ id: 'processDiagram.retry' })}
            </Button>
          }
        >
          {m('loadError')}
        </Banner>
      </div>
    )
  }
  if (coverage === 'none') {
    return (
      <div className="lf-replay" data-testid="instance-replay" data-coverage="none">
        <Banner tone="info">{m('none')}</Banner>
        <ProcessGraphWithTokens instanceId={instanceId} />
      </div>
    )
  }

  const current = steps[k]!
  const status = m('status', { k: k + 1, n, label: nameOf(current), time: time(current.at) })
  return (
    <div className="lf-replay" data-testid="instance-replay" data-coverage={coverage}>
      {coverage === 'partial' && <Banner tone="warning">{m('partial', { time: time(steps[0]!.at) })}</Banner>}
      {(recorded.truncated || recorded.isError) && (
        <Banner
          tone="warning"
          action={
            <Button variant="secondary" size="sm" onClick={recorded.retry}>
              {intl.formatMessage({ id: 'processDiagram.retry' })}
            </Button>
          }
        >
          {m('incomplete')}
        </Banner>
      )}
      <div className="lf-replay__bar" role="group" aria-label={m('controls')}>
        <Button variant="secondary" size="sm" disabled={k <= 0} onClick={() => choose(0)} data-testid="replay-first">
          {m('first')}
        </Button>
        <Button variant="secondary" size="sm" disabled={k <= 0} onClick={() => choose(k - 1)} data-testid="replay-previous">
          {m('previous')}
        </Button>
        <input
          type="range"
          className="lf-replay__range"
          min={1}
          max={n}
          step={1}
          value={k + 1}
          aria-label={m('position', { k: k + 1, n })}
          aria-valuetext={m('position', { k: k + 1, n })}
          onChange={(e) => choose(Number(e.target.value) - 1)}
          data-testid="replay-range"
        />
        <span className="lf-replay__pos" data-testid="replay-position">
          {m('position', { k: k + 1, n })}
        </span>
        <Button variant="secondary" size="sm" disabled={k >= n - 1} onClick={() => choose(k + 1)} data-testid="replay-next">
          {m('next')}
        </Button>
        <Button variant="secondary" size="sm" disabled={k >= n - 1} onClick={() => choose(n - 1)} data-testid="replay-last">
          {m('last')}
        </Button>
      </div>
      <p className="lf-replay__status" aria-live="polite" data-testid="replay-status">
        {status}
      </p>
      <div className="lf-replay__body">
        <div data-testid="replay-diagram">
          <ProcessDiagramLazy graph={graph} path={path} live={false} />
        </div>
        <ol className="lf-replay__list" aria-label={m('listLabel')} data-testid="replay-steps">
          {steps.map((s) => {
            const from = fromName(s)
            const gap = since(s.sincePreviousMs)
            return (
              <li
                key={`${s.seq}-${s.index}`}
                className="lf-replay__item"
                aria-current={s.index === k ? 'step' : undefined}
                data-testid={`replay-step-${s.index + 1}`}
              >
                <button type="button" className="lf-replay__step" onClick={() => choose(s.index)}>
                  <span className="lf-replay__num">{s.index + 1}</span>
                  <span className="lf-replay__main">
                    <span className="lf-replay__label">{nameOf(s)}</span>
                    <span className="lf-replay__meta">
                      {[t.typeName(s.nodeType), from ? m('from', { name: from }) : null].filter(Boolean).join(' · ')}
                    </span>
                    <span className="lf-replay__when">
                      <span className="lf-replay__time">{time(s.at)}</span>
                      {gap && <span className="lf-replay__meta">{gap}</span>}
                    </span>
                  </span>
                </button>
              </li>
            )
          })}
        </ol>
      </div>
    </div>
  )
}
