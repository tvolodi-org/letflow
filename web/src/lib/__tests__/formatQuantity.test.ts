/** Q-1 — GH 3735 R7: quantity display. */
import { describe, expect, it } from 'vitest'
import { formatQuantity } from '../formatQuantity'

describe('Q-1 formatQuantity', () => {
  it.each([
    ['40.000000000', '40'],
    ['12.500000000', '12.5'],
    ['40', '40'],
    ['0.0004', '0'],
    ['0.000000000', '0'],
    ['-0.0004', '0'],
    ['1.23456', '1.235'],
    ['1.2344', '1.234'],
    ['0.9996', '1'],
    ['99.9995', '100'],
    ['-12.3456', '-12.346'],
    ['3.250', '3.25'],
    ['007', '7'],
    ['0.5', '0.5'],
  ])('%s -> %s', (input, out) => expect(formatQuantity(input)).toBe(out))

  it('empty and null give an empty string', () => {
    expect(formatQuantity(null)).toBe('')
    expect(formatQuantity(undefined)).toBe('')
    expect(formatQuantity('')).toBe('')
  })

  it('non-numeric text passes through unchanged', () => {
    expect(formatQuantity('abc')).toBe('abc')
    expect(formatQuantity('1e3')).toBe('1e3')
    expect(formatQuantity('1,5')).toBe('1,5')
  })
})
