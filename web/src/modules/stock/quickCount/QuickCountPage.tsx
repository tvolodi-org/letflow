/** QuickCountPage — REQ-855. Quick count screen: count a single item at a location, show the balance diff,
 *  submit the count, and optionally approve it in-place (four-eyes rule). */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { Banner } from '@/components/ui/Banner'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { FormSection } from '@/components/ui/FormSection'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StockIntlProvider } from '../StockIntlProvider'
import { usePickerOptions } from '../register/stockPickers'
import { stockApi } from '../register/stock.api'
import { stockQueryKeys } from '../register/stockQueryKeys'
import { tasksApi } from '@/api/tasks'
import { classifyError } from '@/utils/classifyError'
import { quickCountApi, type QuickCountBody, type QuickCountDocument } from './quickCount.api'
import {
  EMPTY_FORM, REASON_CODES, errorReasonToField, errorReasonToMessageId, isBannerError, validateQuantity,
  type QuickCountForm,
} from './quickCountModel'

const NONE: never[] = []

/** Harness-only: pre-set initial state for screenshot fixtures without async interaction. */
export interface QuickCountHarnessProps {
  initialForm?: Partial<QuickCountForm>
  initialResult?: QuickCountDocument
  initialSubmitError?: { reason?: string; heldBy?: string }
}

function QuickCountInner({ initialForm, initialResult, initialSubmitError }: QuickCountHarnessProps = {}) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''

  const [form, setForm] = useState<QuickCountForm>(() => ({ ...EMPTY_FORM, ...initialForm }))
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<keyof QuickCountForm, string>>>({})
  const [result, setResult] = useState<QuickCountDocument | null>(initialResult ?? null)
  const [approveTaskId, setApproveTaskId] = useState<string | null>(null)
  const [approveError, setApproveError] = useState<string | null>(null)
  const [submitError, setSubmitError] = useState<{ reason?: string; heldBy?: string } | null>(initialSubmitError ?? null)

  const items = usePickerOptions('catalog_item', NONE)
  const locations = usePickerOptions('location_node', NONE)
  const orgUnits = usePickerOptions('org_unit', NONE)

  // Load item record to check lot_tracking_policy
  const selectedItem = items.find((i) => i.value === form.itemId)
  const isLotTracked = selectedItem?.fields?.['lot_tracking_policy'] === 'lot_tracked'
  const lots = usePickerOptions(
    'catalog_lot',
    form.itemId ? [{ field: 'item_id', op: 'eq', value: form.itemId }] : NONE,
    Boolean(form.itemId && isLotTracked),
  )

  // Load balance when all three keys are present
  const balanceEnabled = Boolean(form.itemId && form.locationId && form.orgUnitId)
  const balanceQuery = useQuery({
    queryKey: stockQueryKeys.balances(tenantId, JSON.stringify({ catalog_item: form.itemId, location: form.locationId, org_unit: form.orgUnitId })),
    queryFn: () => stockApi.balances({ catalog_item: form.itemId, location: form.locationId, org_unit: form.orgUnitId }),
    enabled: balanceEnabled,
    retry: false,
  })

  const balanceQueryState = balanceQuery.isPending ? 'loading' : balanceQuery.isError ? classifyError(balanceQuery.error) : 'success'

  const bookQuantity = balanceEnabled && balanceQuery.data
    ? (balanceQuery.data.rows[0]?.quantity ?? '0')
    : null

  const difference = bookQuantity !== null && form.countedQuantity !== ''
    ? String(Number(form.countedQuantity) - Number(bookQuantity))
    : null

  // Tasks query after result
  const tasksQuery = useQuery({
    queryKey: stockQueryKeys.quickCountTasks(tenantId, result?.id ?? ''),
    queryFn: () => tasksApi.list({ instance_id: result!.id }),
    enabled: Boolean(result?.id),
    retry: false,
  })

  const approveTask = tasksQuery.data?.items[0] ?? null

  // Full task with self_approval_allowed
  const fullTaskQuery = useQuery({
    queryKey: stockQueryKeys.quickCountTask(tenantId, approveTask?.id ?? ''),
    queryFn: () => tasksApi.get(approveTask!.id),
    enabled: Boolean(approveTask?.id),
    retry: false,
  })

  const fullTask = fullTaskQuery.data

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
      setApproveTaskId('done')
      setApproveError(null)
    },
    onError: () => {
      setApproveError(t('stock.qc.error.generic'))
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
      location_id: form.locationId,
      org_unit_id: form.orgUnitId,
      counted_quantity: form.countedQuantity,
      reason_code: form.reasonCode,
      ...(form.lotId ? { catalog_lot_id: form.lotId } : {}),
      ...(form.reasonText.trim() ? { reason_text: form.reasonText.trim() } : {}),
    }
    submitMutation.mutate(body)
  }

  function handleApprove() {
    if (!fullTask?.id) return
    approveMutation.mutate(fullTask.id)
  }

  const reasonOptions = REASON_CODES.map((r) => ({ value: r, label: t(`stock.qc.reason.${r}`) }))

  return (
    <div>
      <PageHeader title={t('stock.qc.title')} lede={t('stock.qc.lede')} />

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

          <FormSection title={t('stock.qc.title')}>
            <Select
              name="catalog_item_id"
              label={t('stock.qc.item')}
              value={form.itemId}
              onChange={set('itemId')}
              options={items}
              placeholder={t('stock.qc.select')}
              error={fieldErrors.itemId}
            />
            <Select
              name="location_id"
              label={t('stock.qc.location')}
              value={form.locationId}
              onChange={set('locationId')}
              options={locations}
              placeholder={t('stock.qc.select')}
              error={fieldErrors.locationId}
            />
            <Select
              name="org_unit_id"
              label={t('stock.qc.orgUnit')}
              value={form.orgUnitId}
              onChange={set('orgUnitId')}
              options={orgUnits}
              placeholder={t('stock.qc.select')}
              error={fieldErrors.orgUnitId}
            />
            {form.itemId && isLotTracked && (
              <Select
                name="catalog_lot_id"
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
                    <span data-testid="book-quantity">{bookQuantity}</span>
                    {difference !== null && (
                      <>
                        <span>{' · '}</span>
                        <span>{t('stock.qc.difference')}: </span>
                        <span data-testid="difference-display">{difference}</span>
                      </>
                    )}
                  </div>
                )}
              </QueryStateBoundary>
            )}

            <Field label={t('stock.qc.countedQuantity')} error={fieldErrors.countedQuantity}>
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
              label={t('stock.qc.reasonCode')}
              value={form.reasonCode}
              onChange={set('reasonCode')}
              options={reasonOptions}
              error={fieldErrors.reasonCode}
            />

            {form.reasonCode === 'other' && (
              <Field label={t('stock.qc.reasonText')} error={fieldErrors.reasonText}>
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
        <div className="lf-card__body" data-testid="quick-count-result">
          <h2>{t('stock.qc.result.title')}</h2>
          <dl>
            <dt>{t('stock.qc.result.number')}</dt>
            <dd data-testid="result-number">{result.number ?? '—'}</dd>
            <dt>{t('stock.qc.result.book')}</dt>
            <dd data-testid="result-book">{result.lines[0]?.book_quantity ?? '—'}</dd>
            <dt>{t('stock.qc.result.counted')}</dt>
            <dd data-testid="result-counted">{result.lines[0]?.counted_quantity ?? '—'}</dd>
            <dt>{t('stock.qc.result.difference')}</dt>
            <dd data-testid="result-difference">{result.lines[0]?.difference ?? '—'}</dd>
            <dt>{t('stock.qc.result.state')}</dt>
            <dd data-testid="result-state">{result.state}</dd>
          </dl>

          {approveTaskId === 'done' ? (
            <Banner tone="success">{t('stock.qc.result.title')}</Banner>
          ) : fullTask?.self_approval_allowed === true ? (
            <div data-testid="approve-section">
              {approveError && <Banner tone="danger">{approveError}</Banner>}
              <Button
                variant="primary"
                onClick={handleApprove}
                disabled={approveMutation.isPending}
                data-testid="approve-button"
              >
                {t('stock.qc.approve')}
              </Button>
            </div>
          ) : fullTask !== undefined ? (
            <div data-testid="four-eyes-hint">
              <Banner tone="info">
                {t('stock.qc.four_eyes_hint')}
              </Banner>
            </div>
          ) : null}
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
