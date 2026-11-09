/** DefinitionVersionsPane — T-1588 (process designer slice 3A). The "Versions" view of the definition page: the list
 *  of versions (number, status, who, when) and a READ-ONLY comparison of two of them drawn on one diagram. Steps and
 *  connections that were added, removed or changed carry a word and a glyph (never colour alone). No restore here:
 *  nothing in this file writes. Render inside ProcessDiagramIntlProvider. */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useDefinitionVersions } from '@/hooks/useDefinitions'
import type { ProcessDefinition } from '@/types/api'
import { classifyError } from '@/utils/classifyError'
import { diffGraphs, diffIsEmpty } from '@/utils/canvas/graphDiff'
import { formatDateTime } from '@/i18n/format'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { EmptyState } from '@/components/ui/EmptyState'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Select } from '@/components/ui/Select'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { StatusPill } from '@/components/ui/StatusPill'
import { DIFF_PILL } from './diagramConfig'
import { ProcessDiagramLazy } from './ProcessDiagramLazy'
import { useDiagramText } from './useDiagramText'

export interface DefinitionVersionsPaneProps {
  def: ProcessDefinition
  /** Start with these selections (harness and tests); the user changes them with the selects. */
  initialBaseId?: string
}

const KINDS = ['added', 'removed', 'changed'] as const

export function DefinitionVersionsPane({ def, initialBaseId }: DefinitionVersionsPaneProps) {
  const intl = useIntl()
  const t = useDiagramText()
  const m = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.${id}` }, values)
  const q = useDefinitionVersions(def.name)
  const [baseChoice, setBaseChoice] = useState<string | null>(initialBaseId ?? null)
  const [compareChoice, setCompareChoice] = useState<string | null>(null)

  // The viewed version is always in the list, even when the page cap cut the server list short of it.
  const versions = useMemo(() => {
    const items = q.data?.items ?? []
    return items.some((v) => v.id === def.id) ? items : [def, ...items]
  }, [q.data, def])
  const truncated = !!q.data?.next_cursor

  const compareId = compareChoice ?? def.id
  const defaultBase = versions[versions.findIndex((v) => v.id === compareId) + 1]?.id
  const baseId = baseChoice ?? defaultBase ?? null
  const base = versions.find((v) => v.id === baseId) ?? null
  const compare = versions.find((v) => v.id === compareId) ?? null
  const comparable = !!base && !!compare && base.id !== compare.id
  const diff = useMemo(() => (comparable ? diffGraphs(base!.graph, compare!.graph) : null), [comparable, base, compare])

  const state = q.isLoading ? 'loading' : q.isError ? classifyError(q.error) : 'success'
  const options = versions.map((v) => ({ value: v.id, label: `${v.version} (${v.status})` }))
  const when = (v: ProcessDefinition) => formatDateTime(v.created_at, undefined, intl.locale)

  const labelOf = (id: string) => {
    const n = diff?.graph.nodes.find((x) => x.id === id)
    return n ? n.label ?? t.typeName(n.node_type) : id
  }
  const fieldName = (f: string) => (['label', 'node_type', 'condition', 'is_default'].includes(f) ? m(`diff.field.${f}`) : f)

  return (
    <section className="lf-pd-versions" aria-label={m('versions.title')} data-testid="definition-versions-pane">
      <p className="lf-pd-versions__lede">{m('versions.lede')}</p>
      <QueryStateBoundary state={state} onRetry={() => void q.refetch()}>
        {truncated && <Banner tone="info">{m('versions.truncated')}</Banner>}
        <div className="lf-pd-versions__scroll">
          <table className="lf-pd-versions__table" aria-label={m('versions.tableLabel')} data-testid="versions-table">
            <thead>
              <tr>
                <th scope="col">{m('versions.col.version')}</th>
                <th scope="col">{m('versions.col.status')}</th>
                <th scope="col">{m('versions.col.by')}</th>
                <th scope="col">{m('versions.col.when')}</th>
                <th scope="col" />
              </tr>
            </thead>
            <tbody>
              {versions.map((v) => (
                <tr key={v.id} className={v.id === def.id ? 'is-current' : undefined} data-testid="versions-row" data-definition-id={v.id}>
                  <td>
                    <span className="lf-pd-versions__mono">{v.version}</span>
                    {v.id === def.id && (
                      <>
                        {' '}
                        <StatusPill tone="current" glyph="ring" data-testid="versions-current">
                          {m('versions.current')}
                        </StatusPill>
                      </>
                    )}
                  </td>
                  <td>
                    <StatusBadge status={v.status} domain="definition" size="sm" />
                  </td>
                  <td>
                    <span className="lf-pd-versions__mono" title={v.created_by}>
                      {v.created_by.slice(0, 8)}
                    </span>
                    {v.owner_module && <div>{m('versions.module', { name: v.owner_module })}</div>}
                  </td>
                  <td>
                    <span className="lf-pd-versions__mono">{when(v)}</span>
                  </td>
                  <td>
                    {v.id !== compareId && (
                      <Button variant="ghost" size="sm" onClick={() => setBaseChoice(v.id)} data-testid="versions-set-base">
                        {m('versions.compareWith')}
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {versions.length < 2 ? (
          <EmptyState title={m('versions.onlyOne')} data-testid="versions-only-one" />
        ) : (
          <>
            <div className="lf-pd-versions__controls">
              <Select label={m('versions.base')} options={options} value={baseId ?? ''} onChange={setBaseChoice} placeholder={baseId ? undefined : ''} />
              <Select label={m('versions.compare')} options={options} value={compareId} onChange={setCompareChoice} />
            </div>
            {!comparable && <Banner tone="info">{m('versions.same')}</Banner>}
            {diff && base && compare && (
              <>
                <p className="lf-pd-versions__summary" aria-live="polite" data-testid="versions-summary">
                  {diffIsEmpty(diff)
                    ? m('versions.noDifferences', { base: base.version, compare: compare.version })
                    : m('versions.summary', {
                        sAdded: diff.counts.nodes.added,
                        sRemoved: diff.counts.nodes.removed,
                        sChanged: diff.counts.nodes.changed,
                        cAdded: diff.counts.edges.added,
                        cRemoved: diff.counts.edges.removed,
                        cChanged: diff.counts.edges.changed,
                      })}
                </p>
                <ul className="lf-pd-versions__legend" aria-label={m('diff.legend')} data-testid="versions-legend">
                  {KINDS.map((k) => (
                    <li key={k}>
                      <StatusPill tone={DIFF_PILL[k].tone} glyph={DIFF_PILL[k].glyph}>
                        {t.diffName(k)}
                      </StatusPill>
                    </li>
                  ))}
                </ul>
                <ProcessDiagramLazy graph={diff.graph} diff={diff} />
                {!diffIsEmpty(diff) && (
                  <>
                    <h3 className="lf-pd-versions__title">{m('versions.changesTitle')}</h3>
                    <ul className="lf-pd-versions__changes" data-testid="versions-changes">
                      {diff.graph.nodes.map((n) => {
                        const e = diff.nodes.get(n.id)
                        if (!e || e.kind === 'unchanged') return null
                        return (
                          <li key={`n-${n.id}`}>
                            <StatusPill tone={DIFF_PILL[e.kind].tone} glyph={DIFF_PILL[e.kind].glyph}>
                              {t.diffName(e.kind)}
                            </StatusPill>{' '}
                            {m('diff.step', { name: labelOf(n.id) })}
                            {e.kind === 'changed' && ` — ${m('diff.changedFields', { fields: e.fields.map(fieldName).join(', ') })}`}
                          </li>
                        )
                      })}
                      {diff.graph.edges.map((ed) => {
                        const e = diff.edges.get(ed.id)
                        if (!e || e.kind === 'unchanged') return null
                        return (
                          <li key={`e-${ed.id}`}>
                            <StatusPill tone={DIFF_PILL[e.kind].tone} glyph={DIFF_PILL[e.kind].glyph}>
                              {t.diffName(e.kind)}
                            </StatusPill>{' '}
                            {m('diff.connection', { from: labelOf(ed.source), to: labelOf(ed.target) })}
                            {e.kind === 'changed' && ` — ${m('diff.changedFields', { fields: e.fields.map(fieldName).join(', ') })}`}
                          </li>
                        )
                      })}
                    </ul>
                  </>
                )}
              </>
            )}
          </>
        )}
      </QueryStateBoundary>
    </section>
  )
}
