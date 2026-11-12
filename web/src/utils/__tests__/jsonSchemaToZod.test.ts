import { describe, expect, it } from 'vitest'
import { compileFormSchemaToZod } from '../jsonSchemaToZod'
import type { TaskFormField } from '@/types/forms'

const f = (over: Partial<TaskFormField>): TaskFormField =>
  ({ name: 'x', type: 'string', required: true, ...over }) as TaskFormField

describe('compileFormSchemaToZod (zod 4)', () => {
  it('string min/max/pattern/email', () => {
    const s = compileFormSchemaToZod(f({ minLength: 2, maxLength: 4, pattern: '^a' }))
    expect(s.safeParse('abc').success).toBe(true)
    expect(s.safeParse('a').success).toBe(false)
    expect(s.safeParse('abcde').success).toBe(false)
    expect(s.safeParse('bcd').success).toBe(false)
    const e = compileFormSchemaToZod(f({ format: 'email' }))
    expect(e.safeParse('a@b.co').success).toBe(true)
    expect(e.safeParse('nope').success).toBe(false)
  })

  it('number bounds and multipleOf', () => {
    const s = compileFormSchemaToZod(f({ type: 'number', minimum: 1, maximum: 10, multipleOf: 2 }))
    expect(s.safeParse(4).success).toBe(true)
    expect(s.safeParse(3).success).toBe(false)
    expect(s.safeParse(12).success).toBe(false)
  })

  it('enum, optional, date, object, array', () => {
    const en = compileFormSchemaToZod(f({ type: 'select', enum: ['a', 'b'] }))
    expect(en.safeParse('a').success).toBe(true)
    expect(en.safeParse('c').success).toBe(false)
    const opt = compileFormSchemaToZod(f({ required: false }))
    expect(opt.safeParse(undefined).success).toBe(true)
    expect(compileFormSchemaToZod(f({ type: 'date' })).safeParse('2026-01-02').success).toBe(true)
    const obj = compileFormSchemaToZod(
      f({ type: 'object', properties: { n: f({ name: 'n', type: 'number' }) } }),
    )
    expect(obj.safeParse({ n: 1 }).success).toBe(true)
    expect(obj.safeParse({ n: 'x' }).success).toBe(false)
    const arr = compileFormSchemaToZod(f({ type: 'array', items: f({ type: 'boolean' }) }))
    expect(arr.safeParse([true, false]).success).toBe(true)
    expect(arr.safeParse([1]).success).toBe(false)
  })
})
