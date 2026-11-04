/** L1 — GH 3767 / REQ-724: pure helpers. The document-view link itself (criterion 4) belongs to REQ-722. */
import { describe, expect, it } from 'vitest'
import { balanceParams, errorKind, isMasked, movementParams, movementsLinkFor, rangeError } from '../register/stockRegisterModel'

describe('L1 model', () => {
  it('movementsLinkFor targets the movements screen with document_id', () => {
    expect(movementsLinkFor('d 1')).toBe('/admin/stock/movements?document_id=d%201')
  })
  it('params drop empty values and never carry basis or tenant', () => {
    expect(balanceParams({ sku: 'a', location: '', org_unit: ' ', responsible: '', lot: '' })).toEqual({ sku: 'a' })
    expect(movementParams({ cause: '', document_id: ' d ', from_seq: '5', to_seq: '2' })).toEqual({ document_id: 'd' })
  })
  it('rangeError only for two numbers in the wrong order', () => {
    expect(rangeError('9', '3')).toBe(true)
    expect(rangeError('3', '9')).toBe(false)
    expect(rangeError('', '3')).toBe(false)
  })
  it('classifies errors and masked legs', () => {
    expect(errorKind({ status: 422 })).toBe('invalid')
    expect(errorKind({ status: 404 })).toBe('notFound')
    expect(errorKind({ status: 403 })).toBe('forbidden')
    expect(errorKind(new Error('x'))).toBe('generic')
    expect(isMasked({ leg_no: 1, quantity: '1', unit_ref: 'u', masked: true })).toBe(true)
    expect(isMasked({ leg_no: 1, quantity: '1', unit_ref: 'u' })).toBe(false)
  })
})
