/** Contracts of LFLinesEditor (generic: no module words). A caller describes its lines with columns; the editor owns the
 *  layout, virtual rows, keyboard, paste, scan, search, error navigation and the two entry modes. */
import type { ReactNode } from 'react'

export type LeMode = 'grid' | 'form'

/** A catalog item as the editor needs it (code + title; `lotTracked` decides if the lot cell is shown). */
export interface LeItem {
  id: string
  code: string
  title: string
  unit?: string
  /** Id of the unit the quantity is counted in (the item's base unit). */
  unitId?: string
  lotTracked?: boolean
  barcode?: string
}

export interface LeCatalog {
  /** Exact code, `CODE – Title`, a barcode or a unique title -> the item, else null. */
  resolve: (text: string) => LeItem | null
  /** At most 8 items for the picker list. */
  suggest: (text: string) => LeItem[]
  byId: (id: string) => LeItem | null
}

/** One error of a line: `col` names the column (undefined = the whole line). `message` is already translated. */
export interface LeError {
  col?: string
  message: string
}

export interface LeCellCtx<L> {
  line: L
  index: number
  /** DOM id of the control: `ln-<index>-<col>` (stable ids used by tests and aria). */
  id: string
  invalid: boolean
  describedBy?: string
  /** Replace fields of this line. */
  patch: (p: Partial<L>) => void
  /** Called when the user leaves the cell (marks the line as touched). */
  onBlur: () => void
  /** True when the cell is drawn in the one-line form (labelled, wider). */
  inForm: boolean
}

export interface LeColumn<L> {
  key: string
  label: string
  num?: boolean
  /** The column takes the free width (an item name); the others keep a fixed share. */
  grow?: boolean
  /** Editable cell; omitted for display-only columns. */
  cell?: (ctx: LeCellCtx<L>) => ReactNode
  /** Display text/node for read-only grid, the saved table and the posted view. */
  view: (line: L) => ReactNode
  /** Cell is skipped by the keyboard and shown as a dash for this line (a lot cell of an item without lots). */
  skip?: (line: L) => boolean
  /** Paste: put the pasted text into this column of the line. A reason means the text was refused. */
  paste?: (line: L, text: string) => { line: L; reason?: string }
  /** Hide in the saved-lines table of the line-by-line mode (kept in the form). */
  savedHidden?: boolean
}

export interface LeScanResult<L> {
  status: 'inc' | 'new' | 'unknown'
  lines: L[]
  /** Index of the line that was incremented/added. */
  index?: number
  qty?: string
}

export interface LeState {
  kind: 'ready' | 'loading' | 'error'
}

export interface LFLinesEditorProps<L> {
  lines: L[]
  onChange: (lines: L[]) => void
  columns: LeColumn<L>[]
  blank: () => L
  duplicate: (line: L) => L
  /** True for a line with nothing entered (an empty document has one such line; the empty state shows for it). */
  isBlank: (line: L) => boolean
  max: number
  mode: LeMode
  onModeChange: (m: LeMode) => void
  state?: 'ready' | 'loading' | 'error'
  onRetry?: () => void
  readOnly?: boolean
  noPermission?: boolean
  /** Errors from the caller (after Save draft, or from the server), by line index. */
  errors?: Record<number, LeError[]>
  /** A message about the whole list ("between 1 and N lines"). */
  listError?: string
  /** Live validation of one line; shown for touched lines (or all lines when `showErrors`). */
  validateLine?: (line: L) => LeError[]
  showErrors?: boolean
  /** Text a search matches against. */
  searchText: (line: L) => string
  /** Scan: add or increment. Absent = no scan field. */
  scan?: (code: string, lines: L[]) => LeScanResult<L>
  /** Import entry; absent = no button. The caller adds rows through `controller.importRows`. */
  onImport?: (controller: LeImportController<L>) => void
  /** A total shown in the sticky footer under the column `col`. */
  totals?: (lines: L[]) => { col: string; node: ReactNode } | null
  /** Prefix of DOM ids and aria ids (tests, labels). */
  screenId: string
  'data-testid'?: string
}

export interface LeImportController<L> {
  importRows: (rows: { line: L; reason?: string }[]) => void
}
