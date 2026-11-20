/** QuickCountPage — REQ-855. Quick count screen: count a single item at a location, show the balance diff,
 *  submit the count, and optionally approve it in-place (four-eyes rule). */
import { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { FormSection } from '@/components/ui/FormSection'
import { ItemPicker } from '@/components/ui/lines/ItemPicker'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StatusPill } from '@/components/ui/StatusPill'
import { useToast } from '@/hooks/useToast'
import { documentStateTone } from '@/lib/documentStateTone'
import { formatQuantity } from '@/lib/formatQuantity'
import { StockIntlProvider } from '../StockIntlProvider'
import { usePickerOptions } from '../register/stockPickers'
import { buildCatalog } from '../documents/linesCatalog'
import { stockApi } from '../register/stock.api'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { tasksApi } from '@/api/tasks'
import { classifyError } from '@/utils/classifyError'
import type { RendererState } from '@/utils/classifyError'
import { quickCountApi, type QuickCountBody, type QuickCountDocument } from './quickCount.api'
import {
  EMPTY_FORM, REASON_CODES, errorReasonToField, errorReasonToMessageId, isBannerError, needsLot, subtractDecimal, validateQuantity,
  type QuickCountForm,
} from './quickCountModel'

const NONE: never[] = []

interface BalanceRow { responsible?: string | null; lot?: string | null; unit_ref?: string | null; quantity?: string | null }

/** Query of GET /balances for the form's key: the route's slot names, the lot only when one is chosen. */
export function balanceKeyParams(form: QuickCountForm): Record<string, string> {
  return {
    sku: form.itemId,
    location: form.locationId,
    org_unit: form.orgUnitId,
    ...(form.responsibleId ? { responsible: form.responsibleId } : {}),
    ...(form.lotId ? { lot: form.lotId } : {}),
  }
}

/** The row the server books against: the chosen responsible, lot (none when empty), the item's base unit. */
export function bookRow<R extends BalanceRow>(rows: R[], lotId: string, uomId: string, responsibleId = ''): R | undefined {
  return rows.find((row) =>
    (row.responsible ?? '') === responsibleId && (row.lot ?? '') === lotId && (!uomId || !row.unit_ref || row.unit_ref === uomId))
}

function baseUomId(fields: Record<string, unknown> | undefined): string {
  const value = fields?.['base_uom_id']
  return typeof value === 'string' ? value : ''
}

/** Harness-only: pre-set initial state for screenshot fixtures without async interaction. */
export interface QuickCountHarnessProps {
  initialForm?: Partial<QuickCountForm>
  initialResult?: QuickCountDocument
  initialSubmitError?: { reason?: string; heldBy?: string }
  /** Show the post-approval state directly (toast already fired, New count button visible). */
  initialApproved?: boolean
  /** Pre-set field-level validation errors (for the validation-errors harness state). */
  initialFieldErrors?: Partial<Record<keyof QuickCountForm, string>>
  /** Pre-set approve-error message (for the approve-error harness state). */
  initialApproveError?: string
}

function QuickCountInner({ initialForm, initialResult, initialSubmitError, initialApproved, initialFieldErrors, initialApproveError }: QuickCountHarnessProps = {}) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const toast = useToast()

  const [form, setForm] = useState<QuickCountForm>(() => ({ ...EMPTY_FORM, ...initialForm }))
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<keyof QuickCountForm, string>>>(
    Object.fromEntries(
      Object.entries(initialFieldErrors ?? {}).filter(([, v]) => v !== undefined).map(([k, v]) => [k, t(v!)])
    ) as Partial<Record<keyof QuickCountForm, string>>
  )
  const [result, setResult] = useState<QuickCountDocument | null>(initialResult ?? null)
  const [approvedSuccessfully, setApprovedSuccessfully] = useState<boolean>(initialApproved ?? false)
  const [approveError, setApproveError] = useState<string | null>(
    initialApproveError ? t(initialApproveError) : null
  )
  const [submitError, setSubmitError] = useState<{ reason?: string; heldBy?: string } | null>(initialSubmitError ?? null)

  const items = usePickerOptions('catalog_item', NONE)
  const locations = usePickerOptions('location_node', NONE)
  const employees = usePickerOptions('org_employee', NONE)
  const orgUnits = usePickerOptions('org_unit', NONE)

  // The item field finds by code, name or barcode, and a keyboard scanner's code + Enter picks the item (ItemPicker).
  const catalog = useMemo(() => buildCatalog(items), [items])
  const selectedItem = items.find((i) => i.value === form.itemId)
  const isLotTracked = needsLot(selectedItem?.fields)
  const lots = usePickerOptions(
    'catalog_lot',
    form.itemId ? [{ field: 'item_id', op: 'eq', value: form.itemId }] : NONE,
    Boolean(form.itemId && isLotTracked),
  )

  // Load balance when all three keys are present
  // GH 4874: the server keeps the place on the line, not on the document header; fall back to the chosen one.
  const resultLocation = result ? (result.location_id ?? result.lines[0]?.location_id ?? form.locationId) || null : null
  const balanceEnabled = Boolean(form.itemId && form.locationId && form.orgUnitId)
  // The route's slot keys (sku, location, org_unit, lot): any other key is refused with invalid_filter.
  const balanceParams = balanceKeyParams(form)
  const balanceQuery = useQuery({
    queryKey: stockQueryKeys.balances(tenantId, JSON.stringify(balanceParams)),
    queryFn: () => stockApi.balances(balanceParams),
    enabled: balanceEnabled,
    retry: false,
  })

  const balanceQueryState = balanceQuery.isPending ? 'loading' : balanceQuery.isError ? classifyError(balanceQuery.error) : 'success'

  // Match the selected responsible and lot exactly (empty means unassigned), in the
  // item's base unit; the client drops empty query values, so that slot is picked from the rows here.
  const uomId = baseUomId(selectedItem?.fields)
  const bookQuantity = balanceEnabled && balanceQuery.data
    ? (bookRow(balanceQuery.data.rows, form.lotId, uomId, form.responsibleId)?.quantity ?? '0')
    : null

  // Exact decimal subtraction: a float would show 10.3 - 10.1 as 0.20000000000000107.
  const difference = bookQuantity !== null && form.countedQuantity !== ''
    ? subtractDecimal(form.countedQuantity, bookQuantity)
    : null

  // Tasks query after result
  const tasksQuery = useQuery({
    queryKey: stockQueryKeys.quickCountTasks(tenantId, result?.id ?? ''),
    queryFn: () => tasksApi.list({ instance_id: result!.id }),
    enabled: Boolean(result?.id),
    retry: false,
  })

  // The pending approve task only: the counter's own submit task belongs to the same instance.
  const approveTask = tasksQuery.data?.items.find((task) => task.node_id === 'approve' && task.status === 'PENDING') ?? null

  // Full task with self_approval_allowed
  const fullTaskQuery = useQuery({
    queryKey: stockQueryKeys.quickCountTask(tenantId, approveTask?.id ?? ''),
    queryFn: () => tasksApi.get(approveTask!.id),
    enabled: Boolean(approveTask?.id),
    retry: false,
  })

  const fullTask = fullTaskQuery.data

  const taskQueryState: RendererState = !result
    ? 'success'
    : tasksQuery.isPending
    ? 'loading'
    : tasksQuery.isError
    ? classifyError(tasksQuery.error)
    : Boolean(approveTask?.id) && fullTaskQuery.isPending
    ? 'loading'
    : Boolean(approveTask?.id) && fullTaskQuery.isError
    ? classifyError(fullTaskQuery.error)
    : 'success'

  const set = <K extends keyof QuickCountForm>(key: K) => (value: QuickCountForm[K]) => {
    if (key === 'itemId') {
      setForm((f) => ({ ...f, itemId: value as string, lotId: '' }))
    } else {
      setForm((f) => ({ ...f, [key]: value }))
    }
    setFieldErrors((e) => ({ ...e, [key]: undefined }))
  }

  const submitMutation = useMutation({
    mutationFn: (body: QuickCountBody) => quickCountApi.create(body),
    onSuccess: (doc) => {
      setResult(doc)
      setSubmitError(null)
    },
    onError: (err: unknown) => {
      const e = err as { status?: number; details?: { reason?: string; held_by?: string } }
      const reason = e.details?.reason
      const heldBy = e.details?.held_by
      if (isBannerError(reason)) {
        setSubmitError({ reason, heldBy })
      } else {
        const field = errorReasonToField(reason)
        if (field) {
          setFieldErrors((fe) => ({ ...fe, [field]: t(errorReasonToMessageId(reason)) }))
        } else {
          setSubmitError({ reason })
        }
      }
    },
  })

  const approveMutation = useMutation({
    mutationFn: (id: string) => tasksApi.complete(id, {}),
    onSuccess: () => {
      toast.success(t('stock.qc.result.approved'))
      setApprovedSuccessfully(true)
      setApproveError(null)
    },
    onError: () => {
      setApproveError(t('stock.qc.error.approve_failed'))
    },
  })

  function validate(): boolean {
    const errs: Partial<Record<keyof QuickCountForm, string>> = {}
    const qErr = validateQuantity(form.countedQuantity)
    if (qErr) errs.countedQuantity = t(qErr)
    if (!form.itemId) errs.itemId = t('stock.qc.error.field_required')
    if (!form.locationId) errs.locationId = t('stock.qc.error.field_required')
    if (!form.orgUnitId) errs.orgUnitId = t('stock.qc.error.field_required')
    if (form.reasonCode === 'other') {
      if (!form.reasonText.trim()) errs.reasonText = t('stock.qc.err.reason_text_required')
      else if (form.reasonText.length > 500) errs.reasonText = t('stock.qc.err.reason_text_too_long')
    }
    setFieldErrors(errs)
    return Object.keys(errs).length === 0
  }

  function handleSubmit() {
    if (!validate()) return
    setSubmitError(null)
    const body: QuickCountBody = {
      catalog_item_id: form.itemId,
      catalog_uom_id: uomId,
      location_id: form.locationId,
      org_unit_id: form.orgUnitId,
      counted_quantity: form.countedQuantity,
      reason_code: form.reasonCode,
      ...(form.responsibleId ? { responsible_id: form.responsibleId } : {}),
      ...(form.lotId ? { catalog_lot_id: form.lotId } : {}),
      ...(form.reasonText.trim() ? { reason_text: form.reasonText.trim() } : {}),
    }
    submitMutation.mutate(body)
  }

  function handleApprove() {
    if (!fullTask?.id) return
    approveMutation.mutate(fullTask.id)
  }

  function handleNewCount() {
    // Keep location and org unit; reset everything else
    setForm((f) => ({ ...EMPTY_FORM, locationId: f.locationId, orgUnitId: f.orgUnitId }))
    setResult(null)
    setApprovedSuccessfully(false)
    setApproveError(null)
    setSubmitError(null)
    setFieldErrors({})
  }

  const reasonOptions = REASON_CODES.map((r) => ({ value: r, label: t(`stock.qc.reason.${r}`) }))

  return (
    <div>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.qc.title')} lede={t('stock.qc.lede')} />

      {!result && (
        <div className="lf-card__body lf-form" data-testid="quick-count-form">
          {submitError && (
            <div data-testid="submit-error-banner">
              <Banner tone="danger">
                {isBannerError(submitError.reason)
                  ? t(errorReasonToMessageId(submitError.reason), submitError.heldBy ? { held_by: submitError.heldBy } : {})
                  : t(errorReasonToMessageId(submitError.reason))}
              </Banner>
            </div>
          )}

          <FormSection title={t('stock.qc.form.section')}>
            <div className={fieldErrors.itemId ? 'lf-field lf-field--l lf-field--error' : 'lf-field lf-field--l'} data-testid="item-field">
              <label className="lf-label" htmlFor="qc-item">{t('stock.qc.item')}</label>
              <ItemPicker
                id="qc-item"
                value={form.itemId}
                catalog={catalog}
                label={t('stock.qc.item')}
                invalid={Boolean(fieldErrors.itemId)}
                describedBy={fieldErrors.itemId ? 'qc-item-error' : 'qc-item-hint'}
                onPick={(item) => set('itemId')(item?.id ?? '')}
                pickOnEnter
              />
              {fieldErrors.itemId ? (
                <span className="lf-error" id="qc-item-error">
                  <AlertCircle className="lf-icon" aria-hidden="true" />
                  {fieldErrors.itemId}
                </span>
              ) : (
                <span className="lf-hint" id="qc-item-hint">{t('stock.qc.item_hint')}</span>
              )}
            </div>
            <Select
              name="location_id"
              width="m"
              label={t('stock.qc.location')}
              value={form.locationId}
              onChange={set('locationId')}
              options={locations}
              placeholder={t('stock.qc.select')}
              error={fieldErrors.locationId}
            />
            <Select
              name="org_unit_id"
              width="m"
              label={t('stock.qc.orgUnit')}
              value={form.orgUnitId}
              onChange={set('orgUnitId')}
              options={orgUnits}
              placeholder={t('stock.qc.select')}
              error={fieldErrors.orgUnitId}
            />
            <Select
              name="responsible_id"
              width="m"
              label={t('stock.qc.responsible')}
              value={form.responsibleId}
              onChange={set('responsibleId')}
              options={[{ value: "", label: t('stock.qc.unassigned') }, ...employees]}
            />
            {form.itemId && isLotTracked && (
              <Select
                name="catalog_lot_id"
                width="m"
                label={t('stock.qc.lot')}
                value={form.lotId}
                onChange={set('lotId')}
                options={lots}
                placeholder={t('stock.qc.select')}
                error={fieldErrors.lotId}
              />
            )}

            {balanceEnabled && (
              <QueryStateBoundary state={balanceQueryState} onRetry={() => void balanceQuery.refetch()}>
                {bookQuantity !== null && (
                  <div data-testid="balance-display">
                    <span>{t('stock.qc.balance')}: </span>
                    <span data-testid="book-quantity" className="mono">{formatQuantity(bookQuantity, intl.locale)}</span>
                    {difference !== null && (
                      <>
                        <span>{' · '}</span>
                        <span>{t('stock.qc.difference')}: </span>
                        <span data-testid="difference-display" className="mono">{formatQuantity(difference, intl.locale)}</span>
                      </>
                    )}
                  </div>
                )}
              </QueryStateBoundary>
            )}

            <Field label={t('stock.qc.countedQuantity')} error={fieldErrors.countedQuantity} width="s" mono>
              <input
                type="text"
                name="counted_quantity"
                value={form.countedQuantity}
                onChange={(e) => set('countedQuantity')(e.target.value)}
                data-testid="counted-quantity-input"
              />
            </Field>

            <Select
              name="reason_code"
              width="m"
              label={t('stock.qc.reasonCode')}
              value={form.reasonCode}
              onChange={set('reasonCode')}
              options={reasonOptions}
              error={fieldErrors.reasonCode}
            />

            {form.reasonCode === 'other' && (
              <Field label={t('stock.qc.reasonText')} error={fieldErrors.reasonText} width="l">
                <textarea
                  name="reason_text"
                  value={form.reasonText}
                  onChange={(e) => set('reasonText')(e.target.value)}
                  data-testid="reason-text-input"
                />
              </Field>
            )}
          </FormSection>

          <div className="lf-form__actions">
            <Button
              variant="primary"
              onClick={handleSubmit}
              disabled={submitMutation.isPending}
              data-testid="submit-quick-count"
            >
              {t('stock.qc.submit')}
            </Button>
          </div>
        </div>
      )}

      {result && (
        <div className="lf-card__body lf-form" data-testid="quick-count-result">
          <FormSection title={t('stock.qc.result.title')}>
            <dl className="lf-dl" data-testid="result-facts">
              <dt>{t('stock.qc.result.item')}</dt>
              <dd data-testid="result-item">
                {items.find(i => i.value === result.lines[0]?.catalog_item_id)?.label ?? result.lines[0]?.catalog_item_id ?? '—'}
              </dd>
              <dt>{t('stock.qc.result.location')}</dt>
              <dd data-testid="result-location">
                {resultLocation ? (locations.find(l => l.value === resultLocation)?.label ?? resultLocation) : '—'}
              </dd>
              <dt>{t('stock.qc.result.org_unit')}</dt>
              <dd data-testid="result-org-unit">
                {orgUnits.find(u => u.value === (result.org_unit_id ?? ''))?.label ?? result.org_unit_id ?? '—'}
              </dd>
              {result.lines[0]?.catalog_lot_id && (
                <>
                  <dt>{t('stock.qc.result.lot')}</dt>
                  <dd data-testid="result-lot">
                    <span className="mono">{lots.find(l => l.value === result.lines[0].catalog_lot_id)?.label ?? result.lines[0].catalog_lot_id}</span>
                  </dd>
                </>
              )}
              {result.reason_code && (
                <>
                  <dt>{t('stock.qc.result.reason')}</dt>
                  <dd data-testid="result-reason">
                    {t(`stock.qc.reason.${result.reason_code}`)}
                    {result.reason_text && ` — ${result.reason_text}`}
                  </dd>
                </>
              )}
              <dt>{t('stock.qc.result.number')}</dt>
              <dd data-testid="result-number"><span className="mono">{result.number ?? '—'}</span></dd>
              <dt>{t('stock.qc.result.book')}</dt>
              <dd data-testid="result-book"><span className="mono">{formatQuantity(result.lines[0]?.book_quantity, intl.locale) || '—'}</span></dd>
              <dt>{t('stock.qc.result.counted')}</dt>
              <dd data-testid="result-counted"><span className="mono">{formatQuantity(result.lines[0]?.counted_quantity, intl.locale) || '—'}</span></dd>
              <dt>{t('stock.qc.result.difference')}</dt>
              <dd data-testid="result-difference"><span className="mono">{formatQuantity(result.lines[0]?.difference, intl.locale) || '—'}</span></dd>
              <dt>{t('stock.qc.result.state')}</dt>
              <dd data-testid="result-state">
                {approvedSuccessfully ? (
                  <StatusPill tone="success" glyph="dot">{t('stock.qc.result.state.approved')}</StatusPill>
                ) : (() => {
                  const tone = documentStateTone(result.state)
                  return (
                    <StatusPill tone={tone.tone} glyph={tone.glyph}>
                      {t(`stock.doc.state.${result.state}`)}
                    </StatusPill>
                  )
                })()}
              </dd>
            </dl>
          </FormSection>

          {approvedSuccessfully ? (
            <div className="lf-form__actions" data-testid="approved-actions">
              <Button
                variant="secondary"
                onClick={handleNewCount}
                data-testid="new-count-button"
              >
                {t('stock.qc.new_count')}
              </Button>
            </div>
          ) : (
            <>
              <div className="lf-form__actions" data-testid="result-actions">
                <Button
                  variant="secondary"
                  onClick={handleNewCount}
                  data-testid="new-count-button"
                >
                  {t('stock.qc.new_count')}
                </Button>
              </div>
              <QueryStateBoundary
                state={taskQueryState}
                onRetry={() => { void tasksQuery.refetch(); if (approveTask?.id) void fullTaskQuery.refetch() }}
              >
                {fullTask?.self_approval_allowed === true ? (
                  <>
                    {approveError && (
                      <div data-testid="approve-error-banner">
                        <Banner tone="danger">{approveError}</Banner>
                      </div>
                    )}
                    <div className="lf-form__actions" data-testid="approve-section">
                      <Button
                        variant="primary"
                        onClick={handleApprove}
                        disabled={approveMutation.isPending}
                        data-testid="approve-button"
                      >
                        {t('stock.qc.approve')}
                      </Button>
                    </div>
                  </>
                ) : fullTask !== undefined ? (
                  <>
                    <Banner tone="info">{t('stock.qc.four_eyes_hint')}</Banner>
                    <div data-testid="four-eyes-hint">
                      <Link to="/tasks" data-testid="my-tasks-link">{t('stock.qc.my_tasks_link')}</Link>
                    </div>
                  </>
                ) : result.state === 'issued' ? (
                  // No pending approve task came back: the count still waits for approval, so say where it is done.
                  <>
                    <div data-testid="no-task-hint">
                      <Banner tone="info">{t('stock.qc.four_eyes_hint')}</Banner>
                    </div>
                    <div>
                      <Link to="/tasks" data-testid="my-tasks-link">{t('stock.qc.my_tasks_link')}</Link>
                    </div>
                  </>
                ) : null}
              </QueryStateBoundary>
            </>
          )}
        </div>
      )}
    </div>
  )
}

export default function QuickCountPage() {
  return (
    <StockIntlProvider>
      <QuickCountInner />
    </StockIntlProvider>
  )
}

/** Harness-only: render a specific UI state for screenshots without async interaction. */
export function QuickCountPageHarness(props: QuickCountHarnessProps) {
  return (
    <StockIntlProvider>
      <QuickCountInner {...props} />
    </StockIntlProvider>
  )
}
