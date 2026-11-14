/** useTenantCurrency — REQ-828. Reads the currency directory through the REQ-827 client (the one place the screens
 *  read it from) and answers the tenant currency: its code and its name in the UI language. While the directory is
 *  unknown, failed or malformed (the reply of an unrelated mock) `code` is '' and the screens fall back to no
 *  currency text, never to a fixed sign. */
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { currenciesApi, type CurrencyEntry } from '../api/currencies'
import { useTenantScopedQueryKeys } from '../api/useTenantScopedQueryKeys'

export interface TenantCurrency {
  /** ISO code of the tenant currency, '' while unknown. */
  code: string
  /** Name in the UI language (en when the UI language has no catalog), '' while unknown. */
  name: string
  /** Code and name for a stored code: `KZT — Tenge`, or the bare code when the directory does not list it. */
  describe: (code: string) => string
}

function nameIn(entry: CurrencyEntry | undefined, locale: string): string {
  if (!entry) return ''
  const names = entry.names as unknown as Record<string, string>
  return names[locale.slice(0, 2)] ?? entry.names.en
}

export function useTenantCurrency(): TenantCurrency {
  const intl = useIntl()
  const keys = useTenantScopedQueryKeys()
  const query = useQuery({ queryKey: keys.currencies.list(), queryFn: () => currenciesApi.list(), retry: false })
  const data = query.data
  const list = data && Array.isArray(data.currencies) ? data.currencies : []
  const code = data && typeof data.tenant_currency === 'string' ? data.tenant_currency : ''
  const describe = (c: string) => {
    const name = nameIn(
      list.find((e) => e.code === c),
      intl.locale,
    )
    return name === '' ? c : `${c} — ${name}`
  }
  return { code, name: nameIn(list.find((e) => e.code === code), intl.locale), describe }
}
