/** cardActions — T-1880 / D-135. The operations offered on an asset card and the one rule that says when each is
 *  allowed (docs/assets/card-actions.md). The panel menu, the row menu and the panel buttons all render from
 *  `CARD_ACTIONS`. A later action (Opening, Count) is one more entry; an action of another module sets `href` instead
 *  of `kind`. The rule mirrors the server: `held` is `Checks.held?/2` (`asset_already_in_register`), the holder rows
 *  are the ledger balance read; the server stays the authority at issue and posting. */
import type { AssetBalanceRow } from './register/assetRegister.api'
import { ASSETS_POST } from './assetsPermissions'
import { MAINTENANCE_REQUEST_CREATE, maintenanceNewRequestHref } from './maintenanceCardAction'
import type { DocKind } from './documents/documentsModel'

export type CardActionId = 'commission' | 'change' | 'handover' | 'writeoff' | 'reportProblem'

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
  /** The maintenance module is installed in the tenant (REQ-898: the card action of another module). */
  maintenanceInstalled: boolean
  /** The caller holds MaintenanceRequestCreate (REQ-898). */
  canReport: boolean
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
  kind?: DocKind
  /** The screen of another module the action opens (REQ-898): it leaves the assets module. */
  href?: (cardId: string) => string
  labelId: string
  permission: string
  /** null: allowed; else the reason id (`assets.cardActions.reason.<id>`). */
  rule: (f: CardFacts) => string | null
  /** The action is not rendered at all when the rule refuses it (it belongs to another module and needs its own
   *  context; the other actions stay visible with their reason). */
  hidden?: boolean
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
  // REQ-898: the action of the maintenance module. It is shown only when the module is installed, the caller
  // holds MaintenanceRequestCreate and the card is active; otherwise it is not rendered at all.
  {
    id: 'reportProblem',
    href: maintenanceNewRequestHref,
    labelId: 'assets.cardActions.action.reportProblem',
    permission: MAINTENANCE_REQUEST_CREATE,
    hidden: true,
    rule: (f) => {
      if (!f.active) return 'retired'
      if (!f.maintenanceInstalled) return 'noMaintenance'
      if (!f.canReport) return 'noPermission'
      return null
    },
  },
]

export type CardActionState = { allowed: true } | { allowed: false; reasonId: string; hidden: boolean }

export function cardActionState(id: CardActionId, f: CardFacts): CardActionState {
  const spec = CARD_ACTIONS.find((a) => a.id === id)
  const reason = spec ? spec.rule(f) : 'noRead'
  if (reason === null) return { allowed: true }
  return { allowed: false, reasonId: `assets.cardActions.reason.${reason}`, hidden: spec?.hidden === true }
}

/** The actions of the card that open a document of this module (the selection bar works on rows of cards, so the
 *  action of another module is not part of it). */
export const CARD_DOCUMENT_ACTIONS: readonly CardActionSpec[] = CARD_ACTIONS.filter((a) => a.kind !== undefined)

export type SelectionActionState = { allowed: true } | { allowed: false; reasonId: string; number: string }

/** Returns allowed if the action is allowed for EVERY item in the list; otherwise the first blocker's reason and number.
 *  Empty list → noneSelected. Any loading fact → loading. */
export function selectionActionState(
  id: CardActionId,
  items: { number: string; facts: CardFacts }[],
): SelectionActionState {
  if (items.length === 0) return { allowed: false, reasonId: 'assets.cardActions.reason.noneSelected', number: '' }
  for (const { number, facts } of items) {
    const state = cardActionState(id, facts)
    if (!state.allowed) return { allowed: false, reasonId: state.reasonId, number }
  }
  return { allowed: true }
}

export function newDocumentHref(kind: string, assetIds: string[]): string {
  const p = new URLSearchParams({ kind })
  for (const id of assetIds) p.append('asset', id)
  return `/admin/assets/documents/new?${p.toString()}`
}

export const cardHref = (id: string): string => `/admin/assets/cards?${new URLSearchParams({ card: id }).toString()}`
