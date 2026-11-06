/** formatDecimal — T-1433 R9b. A money/decimal figure for DISPLAY: grouped per language, at most `maxDecimals`
 *  decimals, trailing zeros trimmed (`450000.000000000` -> `450,000`). String work, no floats. Empty/null -> ''. */
import { localizeDecimalText, roundDecimalText } from '@/lib/formatQuantity'

export const MONEY_MAX_DECIMALS = 4

export function formatDecimal(
  value: string | number | null | undefined,
  opts: { maxDecimals: number; locale?: string },
): string {
  if (value === null || value === undefined || value === '') return ''
  const body = roundDecimalText(String(value).trim(), opts.maxDecimals)
  if (body === null) return String(value)
  return opts.locale ? localizeDecimalText(body, opts.locale) : body
}

export function formatMoney(value: string | number | null | undefined, locale?: string): string {
  return formatDecimal(value, { maxDecimals: MONEY_MAX_DECIMALS, locale })
}
