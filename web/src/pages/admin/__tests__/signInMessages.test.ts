/** M1: T-1732 / REQ-809, every sign-in text exists in en, ru and kk. */
import { describe, expect, it } from 'vitest'
import { SIGN_IN_REASONS, signInMessages, signInReasonText } from '../signInMessages'

describe('REQ-809 signInMessages', () => {
  it('M1 same keys, none empty, in every language', () => {
    const keys = Object.keys(signInMessages.en).sort()
    for (const loc of ['ru', 'kk'] as const) {
      expect(Object.keys(signInMessages[loc]).sort()).toEqual(keys)
      expect(Object.keys(signInMessages[loc].reasons).sort()).toEqual([...SIGN_IN_REASONS].sort())
    }
    for (const loc of ['en', 'ru', 'kk'] as const) {
      for (const [k, v] of Object.entries(signInMessages[loc])) {
        if (k === 'reasons') for (const t of Object.values(v as Record<string, string>)) expect(t.trim()).not.toBe('')
        else expect((v as string).trim()).not.toBe('')
      }
    }
  })
  it('M2 an unknown reason has no text', () => {
    expect(signInReasonText('weird', signInMessages.en)).toBeUndefined()
    expect(signInReasonText(undefined, signInMessages.en)).toBeUndefined()
  })
})
