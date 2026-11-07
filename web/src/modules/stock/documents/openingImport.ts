/** openingImport — LE2 (T-1449). Turns the answer of the records import of `stock_opening_line` into what the lines editor
 *  shows ("N lines added, M refused" with a reason per refused row). The route writes the lines itself (it finds the draft
 *  by the external reference pair in the file), so the editor never receives rows to add; the screen refetches the draft. */
import { importMessages } from '@/i18n/importMessages'
import { ROW_REASON_TYPES, classifyImportError, type ImportAnswer } from '@/pages/admin/import/importModel'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { emptyLine, type LineForm } from './documentsModel'

export const OPENING_LINE_TYPE = 'stock_opening_line'

function fill(text: string, values: Record<string, string>): string {
  return text.replace(/\{(\w+)\}/g, (m, k: string) => values[k] ?? m)
}

/** The translated text of one refused row (header, reason, violations). */
export function reasonText(locale: UiLocale, reason: NonNullable<ImportAnswer['results'][number]['reason']>): string {
  const cat = importMessages[locale]
  const known = (ROW_REASON_TYPES as readonly string[]).includes(reason.type)
  const base = known ? (cat[`import.reason.${reason.type}`] ?? reason.type) : fill(cat['import.reason.unknown'] ?? reason.type, { type: reason.type })
  const header = reason.header ? `${fill(cat['import.reason.header'] ?? '', { header: reason.header })}. ` : ''
  const violations = (reason.violations ?? []).map((v) => v.message ?? v.code ?? '').filter((x) => x !== '')
  return `${header}${base}${violations.length > 0 ? ` (${violations.join('; ')})` : ''}`
}

export function summariseImport(locale: UiLocale, answer: ImportAnswer): { added: number; refused: { row: number; reason: string }[] } {
  let added = 0
  const refused: { row: number; reason: string }[] = []
  answer.results.forEach((r, i) => {
    if (r.status === 'ok') added += 1
    else refused.push({ row: r.line ?? i + 1, reason: r.reason ? reasonText(locale, r.reason) : (importMessages[locale]['import.error.other'] ?? '') })
  })
  return { added, refused }
}

export function importErrorText(locale: UiLocale, err: unknown): string {
  const cat = importMessages[locale]
  const k = classifyImportError(err)
  switch (k.kind) {
    case 'xlsx':
      return cat[`import.error.${k.code}`] ?? cat['import.error.other'] ?? ''
    case 'unprocessable':
      return fill(cat['import.error.unprocessable'] ?? '', { detail: k.detail })
    default:
      return cat[`import.error.${k.kind}`] ?? cat['import.error.other'] ?? ''
  }
}

/** True when the form lines are exactly the saved ones (field by field, so key order cannot matter). */
export function sameLines(a: readonly LineForm[], b: readonly LineForm[]): boolean {
  if (a.length !== b.length) return false
  const keys = Object.keys(emptyLine()) as (keyof LineForm)[]
  return a.every((l, i) => keys.every((k) => l[k] === b[i]![k]))
}
