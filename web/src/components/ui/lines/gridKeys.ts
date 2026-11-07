/** gridKeys — where the focus goes from a cell (pure, no DOM). Cells are addressed by (row, column index); a column the
 *  row skips (a lot cell of an item without lots) is passed over. */
export type NavKey = 'Enter' | 'Tab' | 'ArrowUp' | 'ArrowDown' | 'ArrowLeft' | 'ArrowRight'

export interface NavInput {
  cols: readonly string[]
  rows: number
  row: number
  col: number
  key: NavKey
  shift?: boolean
  /** The list already holds the maximum number of lines. */
  full: boolean
  isSkipped: (row: number, col: string) => boolean
}

export type NavResult =
  | { kind: 'cell'; row: number; col: number }
  | { kind: 'add' }
  | { kind: 'max' }
  | { kind: 'stay' }

function step(i: NavInput, row: number, col: number, dir: 1 | -1): { row: number; col: number } | null {
  let r = row
  let c = col + dir
  for (;;) {
    if (c >= i.cols.length) {
      r += 1
      c = 0
    } else if (c < 0) {
      r -= 1
      c = i.cols.length - 1
    }
    if (r < 0 || r >= i.rows) return null
    if (!i.isSkipped(r, i.cols[c]!)) return { row: r, col: c }
    c += dir
  }
}

/** Enter/Tab: the next cell in reading order (Shift: previous). Past the last cell of the last row: add a row, or
 *  refuse at the maximum. Arrows: the same column of the neighbour row, or the neighbour cell of the row. */
export function nextCell(i: NavInput): NavResult {
  const { key, row, col } = i
  if (key === 'Enter' || key === 'Tab') {
    const back = key === 'Tab' && i.shift
    const to = step(i, row, col, back ? -1 : 1)
    if (to) return { kind: 'cell', ...to }
    if (back) return { kind: 'stay' }
    return i.full ? { kind: 'max' } : { kind: 'add' }
  }
  if (key === 'ArrowUp' || key === 'ArrowDown') {
    const d = key === 'ArrowDown' ? 1 : -1
    let r = row + d
    while (r >= 0 && r < i.rows && i.isSkipped(r, i.cols[col]!)) r += d
    return r >= 0 && r < i.rows ? { kind: 'cell', row: r, col } : { kind: 'stay' }
  }
  const to = step(i, row, col, key === 'ArrowRight' ? 1 : -1)
  return to && to.row === row ? { kind: 'cell', ...to } : { kind: 'stay' }
}
