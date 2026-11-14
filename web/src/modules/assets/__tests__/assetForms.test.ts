/** W1 — T-1921: which official forms the asset document screen offers. Pure. */
import { describe, expect, it } from 'vitest'
import { ASSET_FORM_SUFFIX, assetFormLang, formsForAssetDocument } from '../documents/assetForms'

describe('W1 formsForAssetDocument', () => {
  it.each([
    ['commission', 'issued'], ['commission', 'posted'], ['commission', 'reversed'],
  ])('%s in %s offers DA-1', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual(['da1'])
  })
  it.each([['handover', 'issued'], ['handover', 'posted'], ['handover', 'reversed']])('%s in %s offers DA-1 and DA-4', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual(['da1', 'da4'])
  })
  it.each([['change', 'issued'], ['change', 'posted'], ['change', 'reversed']])('%s in %s offers DA-4 only', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual(['da4'])
  })
  it.each([
    ['change', 'draft'], ['change', 'cancelled'], ['writeoff', 'draft'], ['writeoff', 'cancelled'], ['kind_change', 'posted'], ['opening', 'posted'],
    ['commission', 'draft'], ['commission', 'cancelled'], ['handover', 'draft'],
  ])('%s in %s offers nothing', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual([])
  })
  it.each([['writeoff', 'issued'], ['writeoff', 'posted'], ['writeoff', 'reversed']])('%s in %s offers DA-3 only', (kind, state) => {
    expect(formsForAssetDocument({ kind, state })).toEqual(['da3'])
  })
  it('the language follows the UI: kk prints kk, anything else ru', () => {
    expect(assetFormLang('kk')).toBe('kk')
    expect(assetFormLang('en')).toBe('ru')
    expect(assetFormLang('ru')).toBe('ru')
  })
  it('the fallback file name suffixes', () => {
    expect(ASSET_FORM_SUFFIX.da1).toBe('_DA-1')
    expect(ASSET_FORM_SUFFIX.da3).toBe('_DA-3')
    expect(ASSET_FORM_SUFFIX.da4).toBe('_DA-4')
  })
})
