/** REQ-827 — currency directory API client.
 *
 * Wraps GET /api/v1/currencies (role-agnostic, self-service) and
 * PUT /api/v1/currencies/:code (CurrenciesManage) of `Letflow.Routers.Currencies`.
 * Both routes return the full directory: tenant_currency code plus the list.
 */
import { client } from './client'

/** Names of a currency in the three UI languages. */
export interface CurrencyNames {
  en: string
  ru: string
  kk: string
}

/** One entry as returned by GET /api/v1/currencies. */
export interface CurrencyEntry {
  code: string
  numeric_code: string
  minor_units: number
  names: CurrencyNames
  /** True when the tenant has switched this currency on, or when it is the KZT default. */
  active: boolean
}

/** Reply of both GET and successful PUT /api/v1/currencies. */
export interface CurrenciesReply {
  /** The code of the currency currently set as the tenant currency. */
  tenant_currency: string
  currencies: CurrencyEntry[]
}

/** Body for PUT /api/v1/currencies/:code. */
export interface CurrencySwitchBody {
  active: boolean
  tenant_currency?: true
}

export const currenciesApi = {
  /** GET /api/v1/currencies — the full directory with tenant switches. */
  list: () => client.get<CurrenciesReply>('/api/v1/currencies'),
  /** PUT /api/v1/currencies/:code — switch on/off, or set as tenant currency. */
  switch: (code: string, body: CurrencySwitchBody) =>
    client.put<CurrenciesReply>(`/api/v1/currencies/${encodeURIComponent(code)}`, body),
}
