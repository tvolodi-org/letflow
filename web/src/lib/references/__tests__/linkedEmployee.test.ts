import { describe, expect, it } from 'vitest'
import { linkedEmployeeId } from '../linkedEmployee'

const emps = [
  { value: 'e1', fields: { user_id: null } },
  { value: 'e2', fields: { user_id: 'AAAA-1' } },
  { value: 'e3' },
  { value: 'e4', fields: { user_id: 'aaaa-1' } },
]

describe('linkedEmployeeId', () => {
  it('finds the first employee linked to the user', () => {
    expect(linkedEmployeeId('aaaa-1', emps)).toBe('e2')
  })
  it('compares case-insensitively', () => {
    expect(linkedEmployeeId('AAAA-1', [{ value: 'x', fields: { user_id: 'aaaa-1' } }])).toBe('x')
  })
  it('returns null when nothing matches', () => {
    expect(linkedEmployeeId('zzz', emps)).toBeNull()
  })
  it('returns null for no user or empty user', () => {
    expect(linkedEmployeeId(null, emps)).toBeNull()
    expect(linkedEmployeeId('', emps)).toBeNull()
  })
  it('returns null for an empty list', () => {
    expect(linkedEmployeeId('aaaa-1', [])).toBeNull()
  })
})
