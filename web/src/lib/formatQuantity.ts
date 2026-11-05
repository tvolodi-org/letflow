/** formatQuantity — GH 3735 R7. A quantity for DISPLAY: the server keeps up to 9 decimals, the screen shows at most
 *  3, with trailing zeros trimmed (`40.000000000` -> `40`, `12.500000000` -> `12.5`, `1.23456` -> `1.235`).
 *  Works on the decimal text (no floats, no precision loss), rounds half away from zero, never returns `-0`.
 *  Empty/null -> '' (the caller adds its dash); text that is not a plain decimal is returned unchanged.
 *  There is no per-unit table: `catalog_uom` has no precision field and unit codes are tenant text, so whole
 *  pieces print as `40` through the trim rule and a fractional quantity is never hidden. */
export const QUANTITY_MAX_DECIMALS = 3

const DECIMAL = /^(-?)(\d+)(?:\.(\d+))?$/

export function formatQuantity(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return ''
  const text = String(value).trim()
  const m = DECIMAL.exec(text)
  if (!m) return String(value)
  const neg = m[1] === '-'
  let int = m[2].replace(/^0+(?=\d)/, '')
  let frac = m[3] ?? ''
  if (frac.length > QUANTITY_MAX_DECIMALS) {
    const roundUp = frac.charCodeAt(QUANTITY_MAX_DECIMALS) >= 53 // '5'
    frac = frac.slice(0, QUANTITY_MAX_DECIMALS)
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
      int = all.slice(0, all.length - QUANTITY_MAX_DECIMALS)
      frac = all.slice(all.length - QUANTITY_MAX_DECIMALS)
    }
  }
  frac = frac.replace(/0+$/, '')
  const body = frac ? `${int}.${frac}` : int
  const isZero = /^0(\.0*)?$/.test(body)
  return neg && !isZero ? `-${body}` : body
}
