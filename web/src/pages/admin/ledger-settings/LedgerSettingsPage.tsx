/** LedgerSettingsPage — REQ-839 (Qoimeks parity G4 part 7; decision 0090 rule 5).
 *  Route /admin/ledger-settings, permission LedgerSettingsManage. Lists the switchable ledger registrations
 *  and switches one in a short dialog with a required reason (design-system rule 2a: a single-answer action).
 *  Server: GET /api/v1/ledger-settings, PUT /api/v1/ledger-settings/:registration.
 *  `initialDialog`, `initialReason` and `submitOnMount` are HARNESS-ONLY props (the screenshot tool cannot
 *  click); the router never passes them. */
import React, { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { PageHeader } from '@/components/ui/PageHeader'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Dialog } from '@/components/ui/Dialog'
import { Banner } from '@/components/ui/Banner'
import { Field } from '@/components/ui/Field'
import { StatusPill } from '@/components/ui/StatusPill'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { useToast } from '@/hooks/useToast'
import { useLedgerSettingsList, useSaveLedgerSetting } from '@/hooks/useLedgerSettings'
import { classifyError } from '@/utils/classifyError'
import { formatDateTime } from '@/i18n/format'
import type { LedgerSetting } from '@/api/ledgerSettings'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { LedgerSettingsIntlProvider } from './LedgerSettingsIntlProvider'
import { registrationName, saveErrorKey } from './ledgerSettingsModel'

export interface LedgerSettingsPageProps {
  locale?: UiLocale
  /** Harness only: open the dialog of this registration on mount. */
  initialDialog?: string
  /** Harness only: the reason the dialog starts with. */
  initialReason?: string
  /** Harness only: submit the initial reason once, one frame after mount. */
  submitOnMount?: boolean
}

export default function LedgerSettingsPage(props: LedgerSettingsPageProps): React.ReactElement {
  return (
    <LedgerSettingsIntlProvider locale={props.locale}>
      <LedgerSettingsInner {...props} />
    </LedgerSettingsIntlProvider>
  )
}

function LedgerSettingsInner({ initialDialog, initialReason, submitOnMount }: LedgerSettingsPageProps) {
  const intl = useIntl()
  const locale = intl.locale as UiLocale
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const toast = useToast()
  const list = useLedgerSettingsList()
  const save = useSaveLedgerSetting()
  const [target, setTarget] = useState<string | null>(initialDialog ?? null)
  const [reason, setReason] = useState(initialReason ?? '')
  const [missing, setMissing] = useState(false)

  const items = list.data?.items ?? []
  const row = target === null ? null : (items.find((r) => r.registration === target) ?? null)
  const toAllowed = row !== null && !row.allow_negative

  const errorKey = save.isError ? saveErrorKey(save.error) : null
  const reasonError =
    missing && reason.trim() === ''
      ? t('ledgerSettings.reason.required')
      : errorKey === 'ledgerSettings.error.invalid_reason'
        ? t(errorKey)
        : null
  const bannerError = errorKey !== null && errorKey !== 'ledgerSettings.error.invalid_reason' ? t(errorKey) : null

  const open = (r: LedgerSetting) => {
    save.reset()
    setReason('')
    setMissing(false)
    setTarget(r.registration)
  }
  const close = () => {
    if (save.isPending) return
    save.reset()
    setTarget(null)
    setMissing(false)
  }

  const submit = (override?: string) => {
    if (row === null || save.isPending) return
    const trimmed = (override ?? reason).trim()
    if (trimmed === '') {
      setMissing(true)
      return
    }
    save.mutate(
      { registration: row.registration, body: { allow_negative: !row.allow_negative, reason: trimmed } },
      {
        onSuccess: () => {
          setTarget(null)
          toast.success(t('ledgerSettings.toast.saved'))
        },
      },
    )
  }

  useEffect(() => {
    if (!submitOnMount) return
    const frame = requestAnimationFrame(() => submit(initialReason ?? ''))
    return () => cancelAnimationFrame(frame)
    // Once the row is loaded: the harness reason is fixed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [row !== null])

  const columns: DataTableColumn<LedgerSetting>[] = [
    {
      id: 'registration',
      header: t('ledgerSettings.col.registration'),
      render: (r) => (
        <>
          {registrationName(r.registration, locale)}
          <br />
          <span className="mono caption lf-faint">{r.registration}</span>
        </>
      ),
    },
    {
      id: 'value',
      header: t('ledgerSettings.col.value'),
      render: (r) => (
        <StatusPill tone={r.allow_negative ? 'warning' : 'success'} glyph={r.allow_negative ? 'triangle' : 'dot'}>
          {t(r.allow_negative ? 'ledgerSettings.pill.allowed' : 'ledgerSettings.pill.refused')}
        </StatusPill>
      ),
    },
    {
      id: 'changed',
      header: t('ledgerSettings.col.changed'),
      render: (r) =>
        r.changed_at == null
          ? t('ledgerSettings.change.never')
          : t('ledgerSettings.change.by', {
              name: r.changed_by_name ?? t('ledgerSettings.change.unknownUser'),
              when: formatDateTime(r.changed_at),
            }),
    },
    { id: 'reason', header: t('ledgerSettings.col.reason'), render: (r) => r.reason ?? '—' },
    {
      id: 'action',
      header: t('ledgerSettings.col.action'),
      render: (r) => (
        <Button
          variant="secondary"
          size="sm"
          data-testid={`ledger-setting-switch-${r.registration}`}
          onClick={() => open(r)}
        >
          {t(r.allow_negative ? 'ledgerSettings.toRefused' : 'ledgerSettings.toAllowed')}
        </Button>
      ),
    },
  ]

  return (
    <>
      <PageHeader eyebrow={t('ledgerSettings.eyebrow')} title={t('ledgerSettings.title')} lede={t('ledgerSettings.lede')} />
      <QueryStateBoundary
        state={list.isError ? classifyError(list.error) : 'success'}
        onRetry={() => void list.refetch()}
      >
        <DataTable
          density="compact"
          columns={columns}
          data={items}
          isLoading={list.isLoading}
          getRowId={(r) => r.registration}
          emptyMessage={t('ledgerSettings.empty')}
          emptyText={t('ledgerSettings.emptyText')}
          labels={{ loading: t('ledgerSettings.loading'), retry: t('ledgerSettings.retry') }}
        />
      </QueryStateBoundary>
      <Dialog
        open={row !== null}
        testId="ledger-setting-dialog"
        title={t(toAllowed ? 'ledgerSettings.dialog.allowTitle' : 'ledgerSettings.dialog.refuseTitle', {
          name: row ? registrationName(row.registration, locale) : '',
        })}
        confirmText={t('ledgerSettings.confirm')}
        cancelText={t('ledgerSettings.cancel')}
        confirmVariant={toAllowed ? 'danger' : 'primary'}
        isLoading={save.isPending}
        error={bannerError}
        onConfirm={() => submit()}
        onCancel={close}
      >
        <Banner tone="warning" title={t('ledgerSettings.dialog.warnTitle')}>
          <span data-testid="ledger-setting-warning">
            {t(toAllowed ? 'ledgerSettings.dialog.warnAllow' : 'ledgerSettings.dialog.warnRefuse')}
          </span>
        </Banner>
        <Field
          label={t('ledgerSettings.reason.label')}
          hint={t('ledgerSettings.reason.hint')}
          error={reasonError ?? undefined}
        >
          <textarea
            data-testid="ledger-setting-reason"
            rows={3}
            maxLength={500}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </Field>
      </Dialog>
    </>
  )
}
