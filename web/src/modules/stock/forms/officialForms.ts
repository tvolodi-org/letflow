/** Registry of the official KZ forms the stock screens can print (T-1434, E5e). Data only: a form is one row here plus
 *  its message ids. Only the forms the backend serves today are listed (Z-2 on /documents/:id/print, Inv-10 and Inv-18
 *  on /counts/:id/print/:kind); Z-3, Z-5 and Inv-1/3/7 join as rows once their routes are on main. */
export type OfficialFormId = 'z2' | 'inv10' | 'inv18'
export type OfficialFormFormat = 'docx' | 'pdf'
export type OfficialFormLang = 'ru' | 'kk'
export const OFFICIAL_FORMATS: readonly OfficialFormFormat[] = ['docx', 'pdf']

export const OFFICIAL_FORMS: Record<OfficialFormId, { labelId: string; target: 'document' | 'count'; countKind?: 'sheet' | 'differences' }> = {
  z2: { labelId: 'stock.form.z2', target: 'document' },
  inv18: { labelId: 'stock.form.inv18', target: 'count', countKind: 'differences' },
  inv10: { labelId: 'stock.form.inv10', target: 'count', countKind: 'sheet' },
}

/** The forms exist in ru and kk: the Kazakh UI prints kk, any other UI ru. */
export function officialFormLang(ui: string): OfficialFormLang {
  return ui === 'kk' ? 'kk' : 'ru'
}

/** Z-2 is the issue note: on an `issue` document once it is issued or posted. */
export function formsForDocument(doc: { kind: string; state: string }): OfficialFormId[] {
  return doc.kind === 'issue' && (doc.state === 'issued' || doc.state === 'posted') ? ['z2'] : []
}

/** The count order offers both count forms in one menu; which are usable depends on the issued paperwork. */
export function formsForOrder(): OfficialFormId[] {
  return ['inv10', 'inv18']
}
