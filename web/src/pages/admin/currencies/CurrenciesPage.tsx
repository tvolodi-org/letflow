/** CurrenciesPage — REQ-827: currency directory admin screen.
 *
 * Tenant administrator switches currencies on/off and sets the tenant currency.
 * Route: /admin/currencies, permission CurrenciesManage.
 * The list read (GET /api/v1/currencies) is role-agnostic, but the route is
 * behind RequirePermission so only holders reach this page.
 */
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'
import React, { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Search } from 'lucide-react'
import { PageHeader } from '@/components/ui/PageHeader'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Switch } from '@/components/ui/Checkbox'
import { StatusPill } from '@/components/ui/StatusPill'
import { Field } from '@/components/ui/Field'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { useToast } from '@/hooks/useToast'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { CurrenciesIntlProvider } from '@/i18n/CurrenciesIntlProvider'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { currenciesApi, type CurrencyEntry, type CurrencySwitchBody } from '@/api/currencies'
import type { UiLocale } from '@/i18n/uiLocaleStore'

/** Extract the reason code string from a thrown ApiError or similar. */
function errorCode(err: unknown): string | null {
  const e = err as { code?: unknown } | null
  const c = e?.code
  return typeof c === 'string' ? c : null
}

/** True when the search term matches the currency entry (code or any name). */
function matches(entry: CurrencyEntry, term: string): boolean {
  if (!term) return true
  const t = term.toLowerCase()
  return (
    entry.code.toLowerCase().includes(t) ||
    entry.names.en.toLowerCase().includes(t) ||
    entry.names.ru.toLowerCase().includes(t) ||
    entry.names.kk.toLowerCase().includes(t)
  )
}

export default function CurrenciesPage({ locale }: { locale?: UiLocale }): React.ReactElement {
  return (
    <CurrenciesIntlProvider locale={locale}>
      <CurrenciesPageInner />
    </CurrenciesIntlProvider>
  )
}

function CurrenciesPageInner(): React.ReactElement {
  const { formatMessage: f } = useIntl()
  const locale = useUiLocale()
  const qc = useQueryClient()
  const toast = useToast()
  const tenantKeys = useTenantScopedQueryKeys()

  const [search, setSearch] = useState('')
  const [switchError, setSwitchError] = useState<string | null>(null)

  const listQuery = useQuery({
    queryKey: tenantKeys.currencies.list(),
    queryFn: () => currenciesApi.list(),
  })

  const refresh = () => qc.invalidateQueries({ queryKey: tenantKeys.currencies.all() })

  const switchMutation = useMutation({
    mutationFn: ({ code, body }: { code: string; body: CurrencySwitchBody }) =>
      currenciesApi.switch(code, body),
    onSuccess: () => {
      setSwitchError(null)
      toast.success(f({ id: 'currencies.toast.saved' }))
      void refresh()
    },
    onError: (err: unknown) => {
      const code = errorCode(err)
      let key: string
      if (code === 'currency_is_tenant_currency') key = 'currencies.error.currency_is_tenant_currency'
      else if (code === 'currency_unknown') key = 'currencies.error.currency_unknown'
      else key = 'currencies.error.invalid_body'
      setSwitchError(f({ id: key }))
    },
  })

  const data = listQuery.data
  const tenantCurrency = data?.tenant_currency ?? ''
  const filtered = useMemo(
    () => (data?.currencies ?? []).filter((e) => matches(e, search)),
    [data?.currencies, search],
  )

  const columns: DataTableColumn<CurrencyEntry>[] = [
    { id: 'code', header: f({ id: 'currencies.col.code' }), mono: true, render: (e) => e.code },
    {
      id: 'name',
      header: f({ id: 'currencies.col.name' }),
      render: (e) => e.names[locale as 'en' | 'ru' | 'kk'] ?? e.names.en,
    },
    { id: 'minor', header: f({ id: 'currencies.col.minorUnits' }), mono: true, render: (e) => String(e.minor_units) },
    {
      id: 'active',
      header: f({ id: 'currencies.col.active' }),
      render: (e) => {
        const label = f({ id: 'currencies.col.active' })
        if (e.code === tenantCurrency) {
          return (
            <span data-testid={`switch-${e.code}`} title={f({ id: 'currencies.switch.disabled' })}>
              <Switch label={label} checked disabled onChange={() => undefined} />
            </span>
          )
        }
        const pending = switchMutation.isPending && switchMutation.variables?.code === e.code
        return (
          <Switch
            data-testid={`switch-${e.code}`}
            label={label}
            checked={e.active}
            disabled={pending}
            onChange={(checked) => switchMutation.mutate({ code: e.code, body: { active: checked } })}
          />
        )
      },
    },
    {
      id: 'tenant',
      header: f({ id: 'currencies.col.tenantCurrency' }),
      render: (e) => {
        if (e.code === tenantCurrency) {
          return (
            <StatusPill tone="current" glyph="dot" data-testid={`tenant-currency-mark-${e.code}`}>
              {f({ id: 'currencies.tenantCurrency.mark' })}
            </StatusPill>
          )
        }
        const pending = switchMutation.isPending && switchMutation.variables?.code === e.code
        return (
          <Button
            variant="ghost"
            size="sm"
            data-testid={`make-tenant-currency-${e.code}`}
            loading={pending}
            onClick={() =>
              switchMutation.mutate({ code: e.code, body: { active: true, tenant_currency: true } })
            }
          >
            {f({ id: 'currencies.action.makeTenantCurrency' })}
          </Button>
        )
      },
    },
  ]

  return (
    <>
      <PageHeader
        eyebrow={f({ id: 'currencies.eyebrow' })}
        title={f({ id: 'currencies.title' })}
        lede={f({ id: 'currencies.lede' })}
      />
      <div className="lf-btn-row">
        <Field label={f({ id: 'currencies.search.placeholder' })} hideLabel leadingIcon={<Search className="lf-icon" aria-hidden="true" />}>
          <input
            data-testid="currencies-search"
            type="search"
            aria-label={f({ id: 'currencies.search.placeholder' })}
            placeholder={f({ id: 'currencies.search.placeholder' })}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </Field>
      </div>

      {switchError && (
        <div data-testid="switch-error">
          <Banner tone="danger">{switchError}</Banner>
        </div>
      )}

      <div data-testid={listQuery.isLoading ? 'currencies-loading' : 'currencies-table'}>
        <QueryStateBoundary
          state={listQuery.isLoading ? 'loading' : listQuery.isError ? classifyError(listQuery.error) : 'success'}
          onRetry={() => void listQuery.refetch()}
        >
          <DataTable
            columns={columns}
            data={filtered}
            labels={{ loading: f({ id: 'currencies.loading' }), retry: f({ id: 'currencies.retry' }) }}
            getRowId={(e) => e.code}
            emptyMessage={f({ id: search ? 'currencies.empty' : 'currencies.emptyAll' })}
          />
        </QueryStateBoundary>
      </div>
    </>
  )
}
