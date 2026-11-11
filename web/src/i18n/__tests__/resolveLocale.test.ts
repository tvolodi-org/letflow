import { describe, expect, it } from 'vitest'
import { resolveLocale } from '../resolveLocale'
import { getUiLocale } from '../uiLocaleStore'
import { resolveUiLocale as assets } from '@/modules/assets/assetsMessages'
import { resolveUiLocale as catalogItems } from '@/modules/catalog_items/catalogItemsMessages'
import { resolveUiLocale as codes } from '@/modules/codes/codesMessages'
import { resolveUiLocale as locations } from '@/modules/locations/locationsMessages'
import { resolveUiLocale as org } from '@/modules/org/orgMessages'

const SUPPORTED = ['en', 'ru', 'kk'] as const

describe('resolveLocale', () => {
  it('undefined candidates give the live UI language', () => {
    expect(resolveLocale(SUPPORTED, undefined)).toBe(getUiLocale())
  })
  it('keeps the base tag of a regional tag', () => {
    expect(resolveLocale(SUPPORTED, ['kk-KZ'])).toBe('kk')
  })
  it('is case-insensitive', () => {
    expect(resolveLocale(SUPPORTED, ['RU'])).toBe('ru')
  })
  it('skips an unsupported tag and takes the next supported one', () => {
    expect(resolveLocale(SUPPORTED, ['de-DE', 'ru'])).toBe('ru')
  })
  it('an unsupported tag alone gives en', () => {
    expect(resolveLocale(SUPPORTED, ['fr'])).toBe('en')
  })
  it('an empty list gives en', () => {
    expect(resolveLocale(SUPPORTED, [])).toBe('en')
  })
  it('the five module resolvers agree with it', () => {
    for (const fn of [assets, catalogItems, codes, locations, org]) {
      expect(fn(['kk-KZ'])).toBe('kk')
      expect(fn(['RU'])).toBe('ru')
      expect(fn(['de', 'ru'])).toBe('ru')
      expect(fn(['fr'])).toBe('en')
      expect(fn([])).toBe('en')
      expect(fn(undefined)).toBe(getUiLocale())
    }
  })
})
