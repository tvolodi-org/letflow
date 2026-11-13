/** CurrenciesPage — REQ-827: currency directory admin screen.
 *
 * Tenant administrator switches currencies on/off and sets the tenant currency.
 * Route: /admin/currencies, permission CurrenciesManage.
 * The list read (GET /api/v1/currencies) is role-agnostic, but the route is
 * behind RequirePermission so only holders reach this page.
 */
import React, { useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { PageLayout } from '@/components/ui/PageLayout'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { classifyError } from '@/utils/classifyError'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { CurrenciesIntlProvider } from '@/i18n/CurrenciesIntlProvider'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { currenciesApi, type CurrencyEntry, type CurrencySwitchBody } from '@/api/currencies'
import type { UiLocale } from '@/i18n/uiLocaleStore'

const th: React.CSSProperties = {
  textAlign: 'left',
  padding: '.5rem .75rem',
  borderBottom: '2px solid var(--border-default)',
  whiteSpace: 'nowrap',
}
const td: React.CSSProperties = { padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }

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
  const listState = listQuery.isLoading ? 'loading' : listQuery.isError ? classifyError(listQuery.error) : 'success'

  const filtered = useMemo(
    () => (data?.currencies ?? []).filter((e) => matches(e, search)),
    [data?.currencies, search],
  )

  return (
    <PageLayout title={f({ id: 'currencies.title' })}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
        <input
          data-testid="currencies-search"
          type="search"
          placeholder={f({ id: 'currencies.search.placeholder' })}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ maxWidth: '24rem', padding: '.45rem .6rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}
        />

        {switchError && (
          <p role="alert" data-testid="switch-error" style={{ color: 'var(--danger)', margin: 0 }}>
            {switchError}
          </p>
        )}

        <QueryStateBoundary state={listState} onRetry={() => void listQuery.refetch()}>
          {filtered.length === 0 && search ? (
            <p data-testid="currencies-empty">{f({ id: 'currencies.empty' })}</p>
          ) : (
            <table
              data-testid="currencies-table"
              style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}
            >
              <thead>
                <tr>
                  {[
                    f({ id: 'currencies.col.code' }),
                    f({ id: 'currencies.col.name' }),
                    f({ id: 'currencies.col.minorUnits' }),
                    f({ id: 'currencies.col.active' }),
                    f({ id: 'currencies.col.tenantCurrency' }),
                  ].map((h) => (
                    <th key={h} style={th}>
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {filtered.map((entry) => {
                  const isTenantCurrency = entry.code === tenantCurrency
                  const name = entry.names[locale as 'en' | 'ru' | 'kk'] ?? entry.names.en
                  const isPending = switchMutation.isPending && switchMutation.variables?.code === entry.code

                  return (
                    <tr key={entry.code} data-testid={`currency-row-${entry.code}`}>
                      <td style={td}>{entry.code}</td>
                      <td style={td}>{name}</td>
                      <td style={td}>{entry.minor_units}</td>
                      <td style={td}>
                        {isTenantCurrency ? (
                          <span
                            data-testid={`switch-${entry.code}`}
                            title={f({ id: 'currencies.switch.disabled' })}
                            aria-disabled="true"
                            style={{ opacity: 0.4, cursor: 'not-allowed' }}
                          >
                            <input
                              type="checkbox"
                              checked={true}
                              disabled
                              aria-label={f({ id: 'currencies.col.active' })}
                            />
                          </span>
                        ) : (
                          <input
                            data-testid={`switch-${entry.code}`}
                            type="checkbox"
                            checked={entry.active}
                            disabled={isPending}
                            aria-label={f({ id: 'currencies.col.active' })}
                            onChange={(e) =>
                              switchMutation.mutate({ code: entry.code, body: { active: e.target.checked } })
                            }
                          />
                        )}
                      </td>
                      <td style={td}>
                        {isTenantCurrency ? (
                          <span data-testid={`tenant-currency-mark-${entry.code}`}>
                            {f({ id: 'currencies.tenantCurrency.mark' })}
                          </span>
                        ) : (
                          <Button
                            variant="ghost"
                            size="sm"
                            data-testid={`make-tenant-currency-${entry.code}`}
                            loading={isPending}
                            onClick={() =>
                              switchMutation.mutate({
                                code: entry.code,
                                body: { active: true, tenant_currency: true },
                              })
                            }
                          >
                            {f({ id: 'currencies.action.makeTenantCurrency' })}
                          </Button>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
        </QueryStateBoundary>
      </div>
    </PageLayout>
  )
}
