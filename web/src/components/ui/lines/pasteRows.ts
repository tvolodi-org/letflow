/** pasteRows — clipboard text (Excel: tab between cells, newline between rows) -> a matrix of cell texts.
 *  A text with no tab and no newline is a single value and is left to the browser (`multi: false`). */
export interface PastedMatrix {
  multi: boolean
  rows: string[][]
}

export function parsePaste(text: string): PastedMatrix {
  const norm = text.replace(/\r\n?/g, '\n')
  if (!norm.includes('\t') && !/\n./.test(norm.replace(/\n$/, ''))) {
    return { multi: false, rows: [[norm.replace(/\n$/, '')]] }
  }
  const lines = norm.replace(/\n+$/, '').split('\n')
  return { multi: true, rows: lines.map((l) => l.split('\t').map((c) => c.trim())) }
}

/** A decimal as typed in a sheet: spaces/nbsp as thousands, comma as the point -> "1234.5"; invalid text is returned
 *  trimmed as it is (the validation names the field). */
export function normalizeDecimal(s: string): string {
  const x = s.replace(/\s/g, '').replace(',', '.')
  return /^\d+(\.\d+)?$/.test(x) ? x : s.trim()
}
