/** cardActions — T-1880 / D-135. The operations offered on an asset card and the one rule that says when each is
 *  allowed (docs/assets/card-actions.md). The panel menu, the row menu and the panel buttons all render from
 *  `CARD_ACTIONS`. A later action (Opening, Count) is one more entry; an action of another module sets `href` instead
 *  of `kind`. The rule mirrors the server: `held` is `Checks.held?/2` (`asset_already_in_register`), the holder rows
 *  are the ledger balance read; the server stays the authority at issue and posting. */
import type { AssetBalanceRow } from './register/assetRegister.api'
import { ASSETS_POST } from './assetsPermissions'
import type { DocKind } from './documents/documentsModel'

export type CardActionId = 'commission' | 'change' | 'handover' | 'writeoff'

export interface CardFacts {
  active: boolean
  kind: string
  /** `GET /cards/:id/lock` `held`; undefined while unread or from an older server (treated as false). */
  held: boolean | undefined
  /** Non-zero holder rows of `GET /balances?asset=`; undefined while unread. */
  rows: AssetBalanceRow[] | undefined
  canRead: boolean
  /** A read failed. */
  failed?: boolean
}

export type CardStatus = 'retired' | 'held_pending' | 'in_register' | 'new' | 'unknown'

const ONE_UNIT_KINDS = ['fixed', 'intangible']

export function cardStatus(f: CardFacts): CardStatus {
  if (!f.active) return 'retired'
  if (!f.canRead) return 'unknown'
  const rows = f.rows ?? []
  if (rows.length > 0) return 'in_register'
  if (f.held === true && ONE_UNIT_KINDS.includes(f.kind)) return 'held_pending'
  return 'new'
}

export interface CardActionSpec {
  id: CardActionId
  /** The document kind the action opens (`/admin/assets/documents/new?kind=`). */
  kind: DocKind
  labelId: string
  permission: string
  /** null: allowed; else the reason id (`assets.cardActions.reason.<id>`). */
  rule: (f: CardFacts) => string | null
}

const needsRegister = (f: CardFacts): string | null => {
  if (!f.active) return 'retired'
  if (!f.canRead) return 'noRead'
  if (f.rows === undefined) return f.failed ? 'noRead' : 'loading'
  const status = cardStatus(f)
  if (status === 'held_pending') return 'pendingPosting'
  return status === 'in_register' ? null : 'notInRegister'
}

export const CARD_ACTIONS: readonly CardActionSpec[] = [
  {
    id: 'commission',
    kind: 'commission',
    labelId: 'assets.cardActions.action.commission',
    permission: ASSETS_POST,
    rule: (f) => {
      if (!f.active) return 'retired'
      if (!f.canRead) return 'noRead'
      if (f.rows === undefined) return f.failed ? 'noRead' : 'loading'
      // fixed and intangible: one unit in the register, the server's `asset_already_in_register` (`held`); a low value
      // card may be commissioned again. An unknown `held` (older server) counts as false: the server still refuses at issue.
      if (ONE_UNIT_KINDS.includes(f.kind) && f.held === true) return 'held'
      return null
    },
  },
  { id: 'change', kind: 'change', labelId: 'assets.cardActions.action.change', permission: ASSETS_POST, rule: needsRegister },
  { id: 'handover', kind: 'handover', labelId: 'assets.cardActions.action.handover', permission: ASSETS_POST, rule: needsRegister },
  { id: 'writeoff', kind: 'writeoff', labelId: 'assets.cardActions.action.writeoff', permission: ASSETS_POST, rule: needsRegister },
]

export type CardActionState = { allowed: true } | { allowed: false; reasonId: string }

export function cardActionState(id: CardActionId, f: CardFacts): CardActionState {
  const spec = CARD_ACTIONS.find((a) => a.id === id)
  const reason = spec ? spec.rule(f) : 'noRead'
  return reason === null ? { allowed: true } : { allowed: false, reasonId: `assets.cardActions.reason.${reason}` }
}

export function newDocumentHref(kind: string, assetIds: string[]): string {
  const p = new URLSearchParams({ kind })
  for (const id of assetIds) p.append('asset', id)
  return `/admin/assets/documents/new?${p.toString()}`
}

export const cardHref = (id: string): string => `/admin/assets/cards?${new URLSearchParams({ card: id }).toString()}`
