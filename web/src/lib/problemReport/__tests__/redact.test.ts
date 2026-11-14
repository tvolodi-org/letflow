/** W6 (T-1950): the client mask equals the server's. The 17 pairs are copied verbatim from
 *  test/letflow/problem_reports/capture_test.exs `@pairs` (which names this file); keep both in step. */
import { describe, expect, it } from 'vitest'
import { maskText, normalizeName, normalizePath, oneLine } from '../redact'

const PAIRS: Array<[string, string]> = [
  ['Act dated 2026-11-14', 'Act dated 2026-11-14'],
  ['14.11.2026 10:30', '14.11.2026 10:30'],
  ['on 2026-11-14 10:30 it failed', 'on 2026-11-14 10:30 it failed'],
  ['Amount 1 250 000.00 KZT', 'Amount 1 250 000.00 KZT'],
  ['inv 000123456', 'inv 000123456'],
  ['see SR-42', 'see SR-42'],
  ['12.11.2026 сумма 12 500 000,00', '12.11.2026 сумма 12 500 000,00'],
  ['call +7 701 123 45 67 please', 'call [phone] please'],
  ['tel 87011234567', 'tel [phone]'],
  ['+7 (701) 123-45-67', '[phone]'],
  ['UK +44 20 7946 0958.', 'UK [phone].'],
  ['тел. 8 701 123 45 67, акт №000123456', 'тел. [phone], акт №000123456'],
  ['Bearer abc.def-123 x', 'Bearer [REDACTED] x'],
  ['token eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl end', 'token [REDACTED] end'],
  ['key sk-abcdefghijklmnop1234', 'key [REDACTED]'],
  ['password=hunter2 ok', 'password=[REDACTED] ok'],
  ['mail ivan.petrov@example.kz now', 'mail [email] now'],
]

describe('maskText (W6)', () => {
  it('has the 17 shared pairs', () => {
    expect(PAIRS).toHaveLength(17)
  })
  it.each(PAIRS)('%s', (input, expected) => {
    expect(maskText(input)).toBe(expected)
  })
})

describe('normalizePath (W6)', () => {
  it('turns ids into :id and drops query and hash', () => {
    expect(normalizePath('/api/v1/tasks/0b9f8e7a-1111-4222-8333-444455556666?x=1#h')).toBe('/api/v1/tasks/:id')
    expect(normalizePath('/admin/assets/documents/12345')).toBe('/admin/assets/documents/:id')
    expect(normalizePath('/a/' + 'z'.repeat(41))).toBe('/a/:id')
    expect(normalizePath('/tasks')).toBe('/tasks')
    expect(normalizePath('/a/b12')).toBe('/a/b12')
  })
})

describe('normalizeName and oneLine', () => {
  it('masks ids in an action name and cuts to 80', () => {
    expect(normalizeName('row-0b9f8e7a-1111-4222-8333-444455556666')).toBe('row-:id')
    expect(normalizeName('task-12345')).toBe('task-:id')
    expect(normalizeName('x'.repeat(100))).toHaveLength(80)
  })
  it('replaces control characters by one space', () => {
    expect(oneLine('a\r\nb c')).toBe('a b c')
  })
})
