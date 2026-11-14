/** W1 — T-1921: which official forms the asset document screen offers. Pure. */
import { describe, expect, it } from 'vitest'
import { ASSET_FORM_SUFFIX, assetFormLang, formsForAssetDocument } from '../documents/assetForms'

describe('W1 formsForAssetDocument', () => {
  it.each([
    ['commission', 'issued'], ['commission', 'posted'], ['commission', 'reversed'],
    ['handover', 'issued'], ['handover', 'posted'], ['handover', 'reversed'],
  ])('%s in %s offers DA-1', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual(['da1'])
  })
  it.each([
    ['change', 'posted'], ['writeoff', 'issued'], ['kind_change', 'posted'], ['opening', 'posted'],
    ['commission', 'draft'], ['commission', 'cancelled'], ['handover', 'draft'],
  ])('%s in %s offers nothing', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual([])
  })
  it('the language follows the UI: kk prints kk, anything else ru', () => {
    expect(assetFormLang('kk')).toBe('kk')
    expect(assetFormLang('en')).toBe('ru')
    expect(assetFormLang('ru')).toBe('ru')
  })
  it('the fallback file name suffix is _DA-1', () => {
    expect(ASSET_FORM_SUFFIX.da1).toBe('_DA-1')
  })
})
