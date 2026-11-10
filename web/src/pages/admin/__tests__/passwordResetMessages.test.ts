/** T-1657 / REQ-789 M1: the three languages carry the same keys, none empty; the block helper follows the route's order. */
import { describe, expect, it } from 'vitest'
import { passwordResetBlock, passwordResetMessages } from '../passwordResetMessages'

describe('T-1657 passwordResetMessages', () => {
  it('M1 key sets of en/ru/kk are equal and no value is empty', () => {
    const keys = Object.keys(passwordResetMessages.en).sort()
    for (const locale of ['ru', 'kk'] as const) {
      expect(Object.keys(passwordResetMessages[locale]).sort()).toEqual(keys)
    }
    for (const locale of ['en', 'ru', 'kk'] as const) {
      for (const value of Object.values(passwordResetMessages[locale])) expect(value.trim()).not.toBe('')
    }
  })

  it('M2 passwordResetBlock follows the route order', () => {
    const ok = { status: 'active' as const, auth_source: 'oidc', email: 'a@x.io' }
    expect(passwordResetBlock(ok)).toBeNull()
    expect(passwordResetBlock({ ...ok, status: 'inactive', auth_source: 'internal', email: '' })).toBe('inactive')
    expect(passwordResetBlock({ ...ok, auth_source: 'internal', email: '' })).toBe('noLogin')
    expect(passwordResetBlock({ ...ok, email: '  ' })).toBe('noEmail')
  })
})
