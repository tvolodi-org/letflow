/** formatQuantity — GH 3735 R7. A quantity for DISPLAY: the server keeps up to 9 decimals, the screen shows at most
 *  3, with trailing zeros trimmed (`40.000000000` -> `40`, `12.500000000` -> `12.5`, `1.23456` -> `1.235`).
 *  Works on the decimal text (no floats, no precision loss), rounds half away from zero, never returns `-0`.
 *  Empty/null -> '' (the caller adds its dash); text that is not a plain decimal is returned unchanged.
 *  There is no per-unit table: `catalog_uom` has no precision field and unit codes are tenant text, so whole
 *  pieces print as `40` through the trim rule and a fractional quantity is never hidden. */
export const QUANTITY_MAX_DECIMALS = 3

const DECIMAL = /^(-?)(\d+)(?:\.(\d+))?$/

/** Rounds/trims a plain decimal text to at most `maxDecimals` decimals (string work, no floats). Returns null when the
 *  text is not a plain decimal. */
export function roundDecimalText(text: string, maxDecimals: number): string | null {
  const m = DECIMAL.exec(text)
  if (!m) return null
  const neg = m[1] === '-'
  let int = m[2].replace(/^0+(?=\d)/, '')
  let frac = m[3] ?? ''
  if (frac.length > maxDecimals) {
    const roundUp = frac.charCodeAt(maxDecimals) >= 53 // '5'
    frac = frac.slice(0, maxDecimals)
    if (roundUp) {
      const digits = (int + frac).split('')
      let i = digits.length - 1
      while (i >= 0) {
        if (digits[i] === '9') {
          digits[i] = '0'
          i -= 1
        } else {
          digits[i] = String(Number(digits[i]) + 1)
          break
        }
      }
      if (i < 0) digits.unshift('1')
      const all = digits.join('')
      int = all.slice(0, all.length - maxDecimals)
      frac = all.slice(all.length - maxDecimals)
    }
  }
  frac = frac.replace(/0+$/, '')
  const body = frac ? `${int}.${frac}` : int
  const isZero = /^0(\.0*)?$/.test(body)
  return neg && !isZero ? `-${body}` : body
}

/** With `locale`, the integer digits are grouped and the decimal separator follows the language. */
export function formatQuantity(value: string | number | null | undefined, locale?: string): string {
  if (value === null || value === undefined || value === '') return ''
  const body = roundDecimalText(String(value).trim(), QUANTITY_MAX_DECIMALS)
  if (body === null) return String(value)
  return locale ? localizeDecimalText(body, locale) : body
}

/** Applies the locale's group and decimal symbols to a plain decimal text. */
export function localizeDecimalText(body: string, locale: string): string {
  let group = ','
  let decimal = '.'
  try {
    for (const part of new Intl.NumberFormat(locale).formatToParts(1234567.5)) {
      if (part.type === 'group') group = part.value
      if (part.type === 'decimal') decimal = part.value
    }
  } catch {
    // unknown locale tag: keep the English symbols
  }
  const neg = body.startsWith('-')
  const [int, frac] = (neg ? body.slice(1) : body).split('.')
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, group)
  return `${neg ? '-' : ''}${grouped}${frac ? decimal + frac : ''}`
}
