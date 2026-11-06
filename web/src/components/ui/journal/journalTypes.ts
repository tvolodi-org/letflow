/** Data shapes of the journal component. The module maps its API rows to these; every string is already text
 *  (names, codes, formatted numbers and dates) so the component shows no id and knows no module word. */
import type { ReactNode } from 'react'

export type JournalStatus = 'posted' | 'reversed' | 'reversal'
export type JournalSign = 'pos' | 'neg' | ''

export interface JournalLeg {
  id: string
  /** "code - title" of the place; empty for a leg the caller may not see (`hidden`). */
  location: string
  item: string
  /** Responsible holder, empty when none. */
  holder: string
  /** Quantity without sign, with the unit ("12.5 pcs"). */
  qty: string
  sign: JournalSign
  /** A masked leg: only quantity and unit are known; `hiddenText` stands where location and item would be. */
  hidden: boolean
}

export interface JournalOp {
  id: string
  /** Posting time, already formatted. */
  time: string
  kind: string
  kindLabel: string
  kindIcon: ReactNode
  /** "RCP-2026-000001 - Receipt"; empty when the operation has no document. */
  docText: string
  /** The two parts of `docText` when both exist: the list shows the number and, under it, the kind. */
  docNumber?: string
  docKind?: string
  docHref?: string
  item: string
  itemMore: number
  qty: string
  qtySign: JournalSign
  status: JournalStatus
  statusLabel: string
  /** "Reversed by RCP-..." / "Reversal of RCP-...", empty when unknown. */
  statusNote: string
  legs: JournalLeg[]
}
