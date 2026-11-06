import { describe, expect, it } from 'vitest'
import { formatDecimal, formatMoney } from '../formatDecimal'
import { formatQuantity } from '../formatQuantity'

describe('F1 formatMoney', () => {
  it('groups and trims zeros (en)', () => {
    expect(formatMoney('450000.000000000', 'en')).toBe('450,000')
    expect(formatMoney('9000000.000000000', 'en')).toBe('9,000,000')
    expect(formatMoney('1234567.5', 'en')).toBe('1,234,567.5')
    expect(formatMoney('0.000000000', 'en')).toBe('0')
    expect(formatMoney('-1500.12345', 'en')).toBe('-1,500.1235')
  })
  it('uses the Intl symbols for ru and kk', () => {
    const parts = new Intl.NumberFormat('ru').formatToParts(1234567.5)
    const g = parts.find((p) => p.type === 'group')!.value
    const d = parts.find((p) => p.type === 'decimal')!.value
    expect(formatMoney('1234567.5', 'ru')).toBe(`1${g}234${g}567${d}5`)
    expect(formatMoney('1234567.5', 'kk')).toMatch(/^1.234.567,5$/)
  })
  it('handles empty, non-decimal and long integers', () => {
    expect(formatMoney(null)).toBe('')
    expect(formatMoney('')).toBe('')
    expect(formatMoney('abc')).toBe('abc')
    expect(formatMoney('123456789012.000000000', 'en')).toBe('123,456,789,012')
    expect(formatDecimal('1.23456', { maxDecimals: 2 })).toBe('1.23')
  })
})

describe('F2 formatQuantity with locale', () => {
  it('groups only when a locale is given', () => {
    expect(formatQuantity('3.000000000', 'en')).toBe('3')
    expect(formatQuantity('12345.5', 'en')).toBe('12,345.5')
    expect(formatQuantity('12345.5')).toBe('12345.5')
  })
})
