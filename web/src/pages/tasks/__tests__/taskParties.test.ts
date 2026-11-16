import { describe, it, expect } from 'vitest'
import { sumQuantities } from '../taskParties'

describe('sumQuantities (T-2019)', () => {
  it('adds decimals exactly and ignores text that is not a number', () => {
    expect(sumQuantities(['0.1', '0.2', '1.000000000'])).toBe('1.300000000')
    expect(sumQuantities(['-2', '1.5', 'x'])).toBe('-0.500000000')
    expect(sumQuantities([])).toBe('0.000000000')
  })
})
