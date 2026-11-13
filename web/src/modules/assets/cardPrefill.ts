/** cardPrefill — T-1880 / D-135. The draft a document form opens with when it is started from asset cards
 *  (`documents/new?kind=<kind>&asset=<card id>`): the cards are the LINES, the header comes from the card's holder row in
 *  the register (docs/assets/card-actions.md, "Pre-fill contract"). Nothing is saved here; the form posts on Save. */
import type { AssetBalanceRow } from './register/assetRegister.api'
import { MAX_LINES, emptyForm, emptySide, trimZeros, type FormState, type SideForm } from './documents/documentForm'
import type { DocKind } from './documents/documentsModel'

export interface PrefillCard {
  id: string
  kind: string
  orgUnitId: string
}

/** The card ids of `?asset=`: empty values dropped, repeated ids once, at most `MAX_LINES`. */
export function assetParams(params: URLSearchParams): string[] {
  const out: string[] = []
  for (const v of params.getAll('asset')) if (v !== '' && !out.includes(v) && out.length < MAX_LINES) out.push(v)
  return out
}

const sameRow = (a: AssetBalanceRow, b: AssetBalanceRow) =>
  a.org_unit === b.org_unit &&
  (a.location ?? '') === (b.location ?? '') &&
  a.material_responsible === b.material_responsible &&
  (a.actual_user ?? '') === (b.actual_user ?? '')

const sideOf = (r: AssetBalanceRow): SideForm => ({
  orgUnitId: r.org_unit,
  locationId: r.location ?? '',
  responsibleId: r.material_responsible,
  userId: r.actual_user ?? '',
})

const ONE_UNIT = ['fixed', 'intangible']

/** The form of a new document of `kind` with `cards` as its lines. `manyHolders` is `'card'` when one card is held in
 *  several places, `'cards'` when multiple cards have different holders, false when the header could be taken as one. */
export function prefillForm(
  kind: DocKind,
  cards: PrefillCard[],
  rowsById: Record<string, AssetBalanceRow[] | undefined>,
  eventTime?: string,
): { form: FormState; manyHolders: 'card' | 'cards' | false } {
  const form = emptyForm(kind, eventTime)
  if (kind === 'kind_change' || cards.length === 0) return { form, manyHolders: false }
  let manyHolders: 'card' | 'cards' | false = false
  const holders: AssetBalanceRow[] = []
  const lines = cards.map((c) => {
    const rows = rowsById[c.id] ?? []
    let quantity = '1'
    if (kind !== 'commission' && rows.length > 0) {
      if (rows.length === 1 && !ONE_UNIT.includes(c.kind)) quantity = trimZeros(rows[0].quantity)
      if (rows.length > 1) manyHolders = manyHolders === 'cards' ? 'cards' : 'card'
      else if (holders.length === 0) holders.push(rows[0])
      else if (!sameRow(holders[0], rows[0])) manyHolders = 'cards'
    }
    return { assetId: c.id, quantity }
  })
  form.lines = lines
  if (kind === 'commission') {
    const units = new Set(cards.map((c) => c.orgUnitId))
    if (units.size === 1) {
      const only = [...units][0]
      if (only !== '') form.from = { ...emptySide(), orgUnitId: only }
    }
    return { form, manyHolders: false }
  }
  const holder = holders[0]
  if (holder !== undefined && !manyHolders) {
    form.from = sideOf(holder)
    if (kind === 'handover') form.to = { ...emptySide(), orgUnitId: holder.org_unit, locationId: holder.location ?? '' }
  }
  return { form, manyHolders }
}
