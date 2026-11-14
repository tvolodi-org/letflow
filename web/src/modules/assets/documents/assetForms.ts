import { documentPrintable } from './documentsModel'

/** T-1921: the official forms the asset document screen can print. Data only: a form is one row here plus its message
 *  ids and its backend kinds. The assets module does not import `modules/stock` (module boundary), so this is its own
 *  small copy of the stock registry (`stock/forms/officialForms.ts`). ДА-4 / ДА-3 / ДА-2 join as rows later. */
export type AssetFormId = 'da1'
export type AssetFormFormat = 'docx' | 'pdf'
export type AssetFormLang = 'ru' | 'kk'
export const ASSET_FORM_FORMATS: readonly AssetFormFormat[] = ['docx', 'pdf']

export const ASSET_FORMS: Record<AssetFormId, { labelId: string; kinds: readonly string[] }> = {
  da1: { labelId: 'assets.doc.form.da1', kinds: ['commission', 'handover'] },
}

/** Fallback filename suffix when the server sends no Content-Disposition. */
export const ASSET_FORM_SUFFIX: Record<AssetFormId, string> = { da1: '_DA-1' }

/** The forms exist in ru and kk: the Kazakh UI prints kk, any other UI ru. */
export function assetFormLang(ui: string): AssetFormLang {
  return ui === 'kk' ? 'kk' : 'ru'
}

/** The forms offered for a document: only issued, posted or reversed documents of the form's kinds. */
export function formsForAssetDocument(doc: { kind: string; state: string }): AssetFormId[] {
  if (!documentPrintable(doc)) return []
  return (Object.keys(ASSET_FORMS) as AssetFormId[]).filter((id) => ASSET_FORMS[id].kinds.includes(doc.kind))
}
