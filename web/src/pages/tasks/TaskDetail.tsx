/** TaskDetail — T-1380. The detail panel of a task: the action named for the task (Claim, then Post / Approve / Reverse),
 *  the separation-of-duties hint and refusal as readable text, the document (header and lines, read-only) and the task
 *  form. No id is shown: references go through useReferenceLabels (code - title). */
import { formatQuantity } from '@/lib/formatQuantity'
import { Fragment, useEffect, useMemo, useState } from 'react'
import { X } from 'lucide-react'
import { useTask, useCompleteTask, useClaimTask } from '@/hooks/useTasks'
import { useTaskSubjects } from '@/hooks/useTaskSubjects'
import { useTaskCompletionAttachments } from '@/hooks/useAttachments'
import { isSeparationOfDuties } from '@/api/client'
import { useToast } from '@/hooks/useToast'
import { P, useAccess } from '@/auth/access'
import { Checkbox } from '@/components/ui/Checkbox'
import { Field } from '@/components/ui/Field'
import { Button } from '@/components/ui/Button'
import { DetailHeader } from '@/components/ui/DetailHeader'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { DefinitionName } from '@/components/ui/DefinitionName'
import { Banner } from '@/components/ui/Banner'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { useReferenceLabels, type ReferenceIds } from '@/lib/references/useReferenceLabels'
import { formatDateTimeInZone } from '@/i18n/format'
import { TASKS_TIME_ZONE } from './taskTimeZone'
import { actionKind, classify } from './taskInboxModel'
import { taskErrorText } from './taskErrors'
import type { TaskMessages } from './taskMessages'
import { useTaskContexts, type TaskDoc } from './useTaskDocument'
import type { UiLocale } from '@/i18n/uiLocaleStore'

function docIds(doc: TaskDoc | null): ReferenceIds {
  if (!doc) return {}
  const orgUnits = [doc.orgUnitId].filter((x): x is string => !!x)
  const locations = [doc.locationId, doc.fromLocationId, doc.toLocationId, ...doc.locationIds].filter((x): x is string => !!x)
  return {
    org_unit: orgUnits,
    location_node: [...locations, ...doc.lines.map((l) => l.locationId).filter((x): x is string => !!x)],
    catalog_item: doc.lines.map((l) => l.catalog_item_id).filter((x) => x !== ''),
    catalog_uom: doc.lines.map((l) => l.catalog_uom_id).filter((x) => x !== ''),
    assets_card: doc.lines.map((l) => l.assetId).filter((x): x is string => !!x),
    catalog_lot: doc.lines.map((l) => l.catalog_lot_id).filter((x): x is string => !!x),
  }
}

const fmt = (v: string, locale: string) => formatDateTimeInZone(v, { timeZone: TASKS_TIME_ZONE, locale })

function DocumentSummary({ doc, m, refMsg, label, locale }: {
  locale: string
  doc: TaskDoc
  m: TaskMessages
  refMsg: (typeof REFERENCE_MESSAGES)['en']
  label: ReturnType<typeof useReferenceLabels>
}) {
  const rows: [string, string][] = []
  // Asset documents name cards, not catalog items: no unit and lot columns.
  const isAsset = doc.typeKey?.startsWith('assets_') === true
  const kindWord = refMsg.docType[doc.type === 'count' ? 'count' : (doc.typeKey ?? `stock_${doc.kind}`)] ?? doc.kind
  rows.push([m.number, doc.number], [m.kind, kindWord], [m.state, m.states[doc.state] ?? doc.state])
  if (doc.orgUnitId) rows.push([m.orgUnit, label('org_unit', doc.orgUnitId)])
  if (doc.locationId) rows.push([m.location, label('location_node', doc.locationId)])
  if (doc.fromLocationId) rows.push([m.from, label('location_node', doc.fromLocationId)])
  if (doc.toLocationId) rows.push([m.to, label('location_node', doc.toLocationId)])
  if (doc.locationIds.length > 0) rows.push([m.location, doc.locationIds.map((id) => label('location_node', id)).join(', ')])
  if (doc.eventTime) rows.push([m.created, fmt(doc.eventTime, locale)])
  if (doc.plannedStart && doc.plannedEnd) rows.push([m.plannedPeriod, `${fmt(doc.plannedStart, locale)} – ${fmt(doc.plannedEnd, locale)}`])
  if (doc.note) rows.push([m.note, doc.note])
  return (
    <>
      <dl className="lf-dl" data-testid="task-document-header">
        {rows
          .filter(([, v]) => v !== '')
          .map(([k, v]) => (
            <Fragment key={k}>
              <dt>{k}</dt>
              <dd>{v}</dd>
            </Fragment>
          ))}
      </dl>
      {doc.lines.length > 0 && (
        <div className="lf-table-wrap">
          <table className="lf-table lf-table--compact" data-testid="task-document-lines">
            <caption>{m.linesHeading}</caption>
            <thead>
              <tr>
                <th scope="col">{m.colItem}</th>
                {isAsset && <th scope="col">{m.location}</th>}
                {!isAsset && <th scope="col">{m.colUnit}</th>}
                {!isAsset && <th scope="col">{m.colLot}</th>}
                <th scope="col" className="is-end">{m.colQuantity}</th>
              </tr>
            </thead>
            <tbody>
              {doc.lines.map((l) => (
                <tr key={l.line_no}>
                  <td>{l.assetId !== undefined ? label('assets_card', l.assetId) : label('catalog_item', l.catalog_item_id)}</td>
                  {isAsset && <td>{l.locationId ? label('location_node', l.locationId) : ''}</td>}
                  {!isAsset && <td>{label('catalog_uom', l.catalog_uom_id)}</td>}
                  {!isAsset && <td>{l.catalog_lot_id ? label('catalog_lot', l.catalog_lot_id) : ''}</td>}
                  <td className="is-num">{formatQuantity(l.quantity, locale)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  )
}

export function TaskDetail({ taskId, onClose, m, locale, userId }: {
  taskId: string
  onClose: () => void
  m: TaskMessages
  locale: UiLocale
  userId: string | null
}) {
  const { data: task, isLoading } = useTask(taskId)
  const complete = useCompleteTask()
  const claim = useClaimTask()
  const toast = useToast()
  const { can } = useAccess()
  const canCompleteTask = can(P.TasksComplete)
  const refMsg = REFERENCE_MESSAGES[locale]
  const completionAttachments = useTaskCompletionAttachments(task?.instance_id ?? '', taskId, task?.status === 'COMPLETED')
  const [formValues, setFormValues] = useState<Record<string, unknown>>({})
  const subjectOf = useTaskSubjects(task ? [task.instance_id] : [])
  const contextOf = useTaskContexts(task ? [task.instance_id] : [])
  const ctx = task ? contextOf(task.instance_id) : undefined
  const doc = ctx?.doc ?? null
  const ids = useMemo(() => [docIds(doc)], [doc])
  const label = useReferenceLabels(ids)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  if (isLoading) {
    return (
      <div data-testid="task-detail-panel" className="lf-card__body">
        <p className="lf-muted">{m.loadingTask}</p>
      </div>
    )
  }
  if (!task) {
    return (
      <div data-testid="task-detail-panel" className="lf-card__body">
        <DetailHeader title={m.taskNotFound} />
      </div>
    )
  }

  const kind = actionKind(task)
  const cls = classify(task, userId)
  const pending = task.status === 'PENDING'
  const actionWord = kind === 'other' ? m.complete : m.actions[kind]
  const failure = claim.error ?? complete.error
  const issuedByMe = !!ctx?.issuerId && ctx.issuerId === userId
  const title = kind === 'other' ? task.node_name : m.actions[kind]

  const doClaim = () =>
    claim.mutate(taskId, {
      onSuccess: () => toast.success(m.claimed, { description: m.claimedHint }),
      onError: (e) => toast.error(taskErrorText(e, kind, m)),
    })
  const doComplete = () =>
    complete.mutate(
      { id: taskId, body: { output_variables: formValues } },
      {
        onSuccess: () => toast.success(m.done[kind] ?? m.done['other']),
        onError: (e) => toast.error(taskErrorText(e, kind, m)),
      },
    )

  const properties = (task.form_schema && typeof task.form_schema === 'object'
    ? ((task.form_schema as Record<string, unknown>).properties as Record<string, Record<string, unknown>> | undefined)
    : undefined) ?? {}
  const required = Array.isArray((task.form_schema as Record<string, unknown> | undefined)?.required)
    ? ((task.form_schema as Record<string, unknown>).required as string[])
    : []

  return (
    <div data-testid="task-detail-panel">
      <DetailHeader
        title={title}
        path={subjectOf(task.instance_id)}
        status={<StatusBadge status={task.status} domain="task" />}
        actions={<Button variant="ghost" size="sm" iconOnly icon={<X className="lf-icon" aria-hidden="true" />} label={m.close} onClick={onClose} data-testid="task-detail-close" />}
      />
      <div className="lf-card__body lf-form">
      <span data-testid="task-detail-title" className="sr-only">{task.node_name}</span>

      {failure != null && (
        <Banner tone="danger">
          <span data-testid={isSeparationOfDuties(failure) ? 'task-sod-error' : 'task-error'} role="alert">{taskErrorText(failure, kind, m)}</span>
        </Banner>
      )}
      {failure == null && pending && issuedByMe && kind === 'approve' && cls !== 'other' && (
        <Banner tone="info">
          <span data-testid="task-sod-hint">{m.sodHint[kind]}</span>
        </Banner>
      )}

      {pending && !canCompleteTask && <p className="lf-muted">{m.noPermission}</p>}
      {pending && canCompleteTask && (
        <div className="lf-btn-row">
          {cls === 'available' && (
            <Button variant="primary" size="md" data-testid="task-claim-button" onClick={doClaim} loading={claim.isPending}>
              {claim.isPending ? m.claiming : m.claim}
            </Button>
          )}
          {cls === 'mine' && (
            <Button variant="primary" size="md" data-testid="task-complete-button" onClick={doComplete} loading={complete.isPending}>
              {complete.isPending ? m.completing : actionWord}
            </Button>
          )}
        </div>
      )}

      {task.status === 'COMPLETED' && completionAttachments.data && completionAttachments.data.length > 0 && (
        <p className="lf-muted" data-testid="task-decision-attachments">
          {completionAttachments.data.length === 1 ? m.reviewedOne : m.reviewedMany}
          {completionAttachments.data.map((a) => a.file_name).join(', ')}
        </p>
      )}

      <div data-testid="instance-variables" className="lf-form__section">
        <h3 className="lf-form__title">{m.documentHeading}</h3>
        {doc ? (
          <DocumentSummary doc={doc} m={m} refMsg={refMsg} label={label} locale={locale} />
        ) : (
          ctx !== undefined && <p className="lf-muted">{m.documentUnavailable}</p>
        )}
      </div>

      <dl className="lf-dl">
        <dt>{m.definition}</dt>
        <dd data-testid="instance-definition-name">{task.definition_name ? <DefinitionName name={task.definition_name} /> : '—'}</dd>
        <dt>{refMsg.instanceLabel}</dt>
        <dd data-testid="instance-id" data-instance-id={task.instance_id}>{subjectOf(task.instance_id)}</dd>
        {task.correlation_key && (
          <>
            <dt>{m.correlation}</dt>
            <dd data-testid="instance-correlation-key">{task.correlation_key}</dd>
          </>
        )}
        <dt>{m.created}</dt>
        <dd>{fmt(task.created_at, locale)}</dd>
      </dl>

      {Object.keys(properties).length > 0 && (
        <div className="lf-form__section">
          <h3 className="lf-form__title">{m.taskForm}</h3>
          <div className="lf-form">
            {Object.entries(properties).map(([name, def]) => {
              const type = (def?.type as string) || 'string'
              const fieldTitle = (def?.title as string) || name
              return (
                type === 'boolean' ? (
                  <Checkbox
                    key={name}
                    label={fieldTitle}
                    data-testid={`form-field-${name}`}
                    checked={Boolean(formValues[name])}
                    onChange={(checked) => setFormValues((prev) => ({ ...prev, [name]: checked }))}
                  />
                ) : (
                  <Field
                    key={name}
                    label={required.includes(name) ? `${fieldTitle} *` : fieldTitle}
                  >
                    <input
                      data-testid={`form-field-${name}`}
                      type={type === 'number' ? 'number' : 'text'}
                      placeholder={fieldTitle}
                      value={(formValues[name] as string | number | undefined) ?? ''}
                      onChange={(e) =>
                        setFormValues((prev) => ({
                          ...prev,
                          [name]: type === 'number' ? (e.target.value === '' ? undefined : Number(e.target.value)) : e.target.value,
                        }))
                      }
                    />
                  </Field>
                )
              )
            })}
          </div>
        </div>
      )}
      </div>
    </div>
  )
}
