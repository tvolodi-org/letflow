import { documentPrintable } from '../documents/documentsModel'

/** Registry of the official KZ forms the stock screens can print (T-1434, E5e). Data only: a form is one row here plus
 *  its message ids. Only the forms the backend serves today are listed (Z-1 on /documents/:id/print for receipts T-1912, Z-6 for write-offs T-1914;
 *  Z-2 on /documents/:id/print, Inv-10 and Inv-18 on /counts/:id/print/:kind); Z-3 (balances) and Z-5 (transfer) joined
 *  with E5c; Inv-1/3/7 join as rows once their backend routes exist (T-1441: all forms live in this one menu). */
export type OfficialFormId = 'z1' | 'z2' | 'z3' | 'z5' | 'z6' | 'inv10' | 'inv18'
export type OfficialFormFormat = 'docx' | 'pdf'
export type OfficialFormLang = 'ru' | 'kk'
export const OFFICIAL_FORMATS: readonly OfficialFormFormat[] = ['docx', 'pdf']

export const OFFICIAL_FORMS: Record<OfficialFormId, { labelId: string; target: 'document' | 'balances' | 'count'; countKind?: 'sheet' | 'differences' }> = {
  z1: { labelId: 'stock.form.z1', target: 'document' },
  z2: { labelId: 'stock.form.z2', target: 'document' },
  z3: { labelId: 'stock.form.z3', target: 'balances' },
  z5: { labelId: 'stock.form.z5', target: 'document' },
  z6: { labelId: 'stock.form.z6', target: 'document' },
  inv18: { labelId: 'stock.form.inv18', target: 'count', countKind: 'differences' },
  inv10: { labelId: 'stock.form.inv10', target: 'count', countKind: 'sheet' },
}

/** The document forms served by GET /documents/:id/print?form=... (T-1912, T-1416, T-1417, T-1914). */
export const DOCUMENT_FORMS = ['z1', 'z2', 'z5', 'z6'] as const
export type DocumentFormId = (typeof DOCUMENT_FORMS)[number]
export function isDocumentForm(f: string): f is DocumentFormId {
  return (DOCUMENT_FORMS as readonly string[]).includes(f)
}
/** Fallback filename suffix for each document form (used when the server sends no Content-Disposition). */
export const DOCUMENT_FORM_SUFFIX: Record<DocumentFormId, string> = {
  z1: '_Z-1',
  z2: '-Z-2',
  z5: '_Z-5',
  z6: '_Z-6',
}

/** The forms exist in ru and kk: the Kazakh UI prints kk, any other UI ru. */
export function officialFormLang(ui: string): OfficialFormLang {
  return ui === 'kk' ? 'kk' : 'ru'
}

/** Document forms share the act's issued, posted and reversed state policy. */
const DOCUMENT_FORM_OF: Partial<Record<string, DocumentFormId>> = { receipt: 'z1', issue: 'z2', transfer: 'z5', hand_over: 'z5', return: 'z5', write_off: 'z6' }
export function formsForDocument(doc: { kind: string; state: string }): DocumentFormId[] {
  const form = DOCUMENT_FORM_OF[doc.kind]
  return form && documentPrintable(doc) ? [form] : []
}

/** The count order offers both count forms in one menu; which are usable depends on the issued paperwork. */
export function formsForOrder(): OfficialFormId[] {
  return ['inv10', 'inv18']
}
