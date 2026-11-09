/** openingImport — LE2 (T-1449). Turns the answer of the records import of `stock_opening_line` into what the lines editor
 *  shows ("N lines added, M refused" with a reason per refused row). The route writes the lines itself (it finds the draft
 *  by the external reference pair in the file), so the editor never receives rows to add; the screen refetches the draft. */
import { importMessages } from '@/i18n/importMessages'
import { classifyImportError, reasonSentence, type ImportAnswer } from '@/pages/admin/import/importModel'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { emptyLine, type LineForm } from './documentsModel'

export const OPENING_LINE_TYPE = 'stock_opening_line'

function fill(text: string, values: Record<string, string>): string {
  return text.replace(/\{(\w+)\}/g, (m, k: string) => values[k] ?? m)
}

/** The translated text of one refused row (header, reason, violations). Violations use the shared localized helper. */
export function reasonText(locale: UiLocale, reason: NonNullable<ImportAnswer['results'][number]['reason']>): string {
  const cat = importMessages[locale]
  const header = reason.header ? `${fill(cat['import.reason.header'] ?? '', { header: reason.header })}. ` : ''
  return `${header}${reasonSentence(locale, reason)}`
}

export function summariseImport(
  locale: UiLocale,
  answer: ImportAnswer,
): { added: number; refused: { row: number; reason: string }[]; applied?: boolean } {
  let added = 0
  const refused: { row: number; reason: string }[] = []
  answer.results.forEach((r, i) => {
    // A rolled-back run (applied false) wrote nothing: its "ok" rows are hypothetical and do not count as added.
    if (r.status === 'ok') added += answer.applied === false ? 0 : 1
    else refused.push({ row: r.line ?? i + 1, reason: r.reason ? reasonText(locale, r.reason) : (importMessages[locale]['import.error.other'] ?? '') })
  })
  return answer.applied === undefined ? { added, refused } : { added, refused, applied: answer.applied }
}

export function importErrorText(locale: UiLocale, err: unknown): string {
  const cat = importMessages[locale]
  const k = classifyImportError(err)
  switch (k.kind) {
    case 'xlsx': {
      const named = k.headers ? cat[`import.error.${k.code}_named`] : undefined
      if (named && k.headers) return fill(named, { headers: k.headers.join(', ') })
      return cat[`import.error.${k.code}`] ?? cat['import.error.other'] ?? ''
    }
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
