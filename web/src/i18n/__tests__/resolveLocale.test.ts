import { describe, expect, it } from 'vitest'
import { resolveLocale } from '../resolveLocale'
import { getUiLocale } from '../uiLocaleStore'

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
})
