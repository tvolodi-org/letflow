// @vitest-environment node
/** T-1448 U1-U3: the pure helpers of the lines editor (virtual window, grid keys, paste). */
import { describe, expect, it } from 'vitest'
import { computeWindow } from '../useVirtualRows'
import { nextCell, type NavInput } from '../gridKeys'
import { normalizeDecimal, parsePaste } from '../pasteRows'

describe('U1 virtual window', () => {
  it('1000 rows mount at most 30 and the spacers add up to the full height', () => {
    const w = computeWindow(1000, 40, 0, 600, 8)
    expect(w.last - w.first).toBeLessThanOrEqual(30)
    expect(w.padTop + (w.last - w.first) * 40 + w.padBottom).toBe(1000 * 40)
  })
  it('scrolling moves the window', () => {
    const w = computeWindow(1000, 40, 20000, 600, 8)
    expect(w.first).toBe(500 - 8)
    expect(w.last).toBeGreaterThan(w.first)
    expect(w.padTop).toBe(w.first * 40)
    const end = computeWindow(1000, 40, 1000 * 40, 600, 8)
    expect(end.last).toBe(1000)
    expect(end.padBottom).toBe(0)
  })
  it('an unmeasured viewport (height 0) still gives a bounded window', () => {
    const w = computeWindow(1000, 40, 0, 0, 8)
    expect(w.last - w.first).toBeLessThanOrEqual(30)
  })
})

const base = (over: Partial<NavInput>): NavInput => ({
  cols: ['item', 'lot', 'qty'],
  rows: 3,
  row: 0,
  col: 0,
  key: 'Enter',
  full: false,
  isSkipped: () => false,
  ...over,
})

describe('U2 grid keys', () => {
  it('Enter and Tab go to the next cell, Shift+Tab to the previous, over the row end', () => {
    expect(nextCell(base({}))).toEqual({ kind: 'cell', row: 0, col: 1 })
    expect(nextCell(base({ col: 2, key: 'Tab' }))).toEqual({ kind: 'cell', row: 1, col: 0 })
    expect(nextCell(base({ row: 1, col: 0, key: 'Tab', shift: true }))).toEqual({ kind: 'cell', row: 0, col: 2 })
    expect(nextCell(base({ row: 0, col: 0, key: 'Tab', shift: true }))).toEqual({ kind: 'stay' })
  })
  it('the lot cell of an item without lots is skipped', () => {
    const isSkipped = (row: number, col: string) => row === 0 && col === 'lot'
    expect(nextCell(base({ isSkipped }))).toEqual({ kind: 'cell', row: 0, col: 2 })
    expect(nextCell(base({ row: 0, col: 2, key: 'Tab', shift: true, isSkipped }))).toEqual({ kind: 'cell', row: 0, col: 0 })
  })
  it('arrows keep the column up and down and move within the row left and right', () => {
    expect(nextCell(base({ row: 0, col: 2, key: 'ArrowDown' }))).toEqual({ kind: 'cell', row: 1, col: 2 })
    expect(nextCell(base({ row: 0, key: 'ArrowUp' }))).toEqual({ kind: 'stay' })
    expect(nextCell(base({ row: 1, col: 1, key: 'ArrowRight' }))).toEqual({ kind: 'cell', row: 1, col: 2 })
    expect(nextCell(base({ row: 1, col: 2, key: 'ArrowRight' }))).toEqual({ kind: 'stay' })
  })
  it('Enter in the last cell of the last row adds a row, or refuses at the maximum', () => {
    expect(nextCell(base({ row: 2, col: 2 }))).toEqual({ kind: 'add' })
    expect(nextCell(base({ row: 2, col: 2, full: true }))).toEqual({ kind: 'max' })
  })
})

describe('U3 paste rows', () => {
  it('tab and newline text becomes a matrix', () => {
    const m = parsePaste('BOLT\tL1\t2,5\t1 000,50\r\nNUT\t\t3\t')
    expect(m.multi).toBe(true)
    expect(m.rows).toEqual([['BOLT', 'L1', '2,5', '1 000,50'], ['NUT', '', '3', '']])
  })
  it('a single value is left to the browser', () => {
    expect(parsePaste('BOLT').multi).toBe(false)
    expect(parsePaste('BOLT\n').multi).toBe(false)
  })
  it('comma decimals and space thousands are normalised, other text is kept', () => {
    expect(normalizeDecimal('1 000,50')).toBe('1000.50')
    expect(normalizeDecimal('2,5')).toBe('2.5')
    expect(normalizeDecimal('12')).toBe('12')
    expect(normalizeDecimal(' abc ')).toBe('abc')
  })
})
