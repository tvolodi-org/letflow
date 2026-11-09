import { describe, it, expect } from 'vitest'
import { feedbackMessages } from '@/components/ui/feedbackMessages'
import { saveErrorText } from '@/utils/saveError'

const en = feedbackMessages.en
const ru = feedbackMessages.ru

describe('saveErrorText (T-1553 S1-S7)', () => {
  it.each([
    [400, en.saveInvalid],
    [422, en.saveInvalid],
    [401, en.saveForbidden],
    [403, en.saveForbidden],
    [404, en.saveNotFound],
    [409, en.saveConflict],
    [500, en.saveFailed],
    [503, en.saveFailed],
  ])('S1-S5: status %i maps to its class text', (status, text) => {
    expect(saveErrorText({ status, message: 'x', code: 'y' }, en)).toBe(text)
  })

  it('S6: 429 with Retry-After names the seconds, without it uses the generic text', () => {
    expect(saveErrorText({ status: 429, details: { retryAfter: 12 } }, en)).toBe(
      'Too many requests. Wait 12 s and try again.',
    )
    expect(saveErrorText({ status: 429 }, en)).toBe(en.saveRateLimitNoWait)
  })

  it('S7: a network error or non-error value maps to the failed text, in ru too', () => {
    expect(saveErrorText(new TypeError('Failed to fetch'), ru)).toBe(ru.saveFailed)
    expect(saveErrorText(null, ru)).toBe(ru.saveFailed)
  })

  it('S8: server message and code never reach the text', () => {
    const t = saveErrorText({ status: 422, message: 'insufficient_stock 409', code: 'insufficient_stock' }, en)
    expect(t).not.toContain('insufficient_stock')
    expect(t).not.toContain('409')
  })
})
