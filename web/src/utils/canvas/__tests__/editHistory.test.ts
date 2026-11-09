import { describe, expect, it } from 'vitest'
import { HISTORY_LIMIT, dragCoalescer, canRedo, canUndo, initialHistory, push, redo, reset, undo } from '../editHistory'

describe('editHistory', () => {
  it('U1 undo and redo walk the steps in order', () => {
    let h = initialHistory(0)
    h = push(push(h, 1), 2)
    h = undo(h)
    expect(h.present).toBe(1)
    h = undo(h)
    expect(h.present).toBe(0)
    expect(canUndo(h)).toBe(false)
    h = redo(redo(h))
    expect(h.present).toBe(2)
    expect(canRedo(h)).toBe(false)
  })

  it('U2 a new edit clears redo', () => {
    let h = push(push(initialHistory(0), 1), 2)
    h = push(undo(h), 9)
    expect(canRedo(h)).toBe(false)
    expect(h.present).toBe(9)
  })

  it('U3 same coalesce key is one step; a different key is another', () => {
    let h = initialHistory('')
    h = push(h, 'a', 'label:n')
    h = push(h, 'ab', 'label:n')
    h = push(h, 'abc', 'label:n')
    expect(h.past).toHaveLength(1)
    expect(undo(h).present).toBe('')
    expect(push(h, 'x', 'label:m').past).toHaveLength(2)
  })

  it('U4 the stack is bounded, reset forgets it', () => {
    let h = initialHistory(0)
    for (let i = 1; i <= HISTORY_LIMIT + 20; i += 1) h = push(h, i)
    expect(h.past).toHaveLength(HISTORY_LIMIT)
    expect(canUndo(reset(5))).toBe(false)
  })

  it('U6 two separate drags of one step are two undo steps; one drag is one', () => {
    const key = dragCoalescer()
    let h = initialHistory(0)
    // drag 1: 0 -> 10 -> 20, ends with the dragging:false change
    for (const [x, dragging] of [[10, true], [20, true], [20, false]] as const) h = push(h, x, key('n', dragging))
    // drag 2: 20 -> 30 -> 40
    for (const [x, dragging] of [[30, true], [40, true], [40, false]] as const) h = push(h, x, key('n', dragging))
    expect(h.past).toEqual([0, 20])
    expect(undo(h).present).toBe(20)
    expect(undo(undo(h)).present).toBe(0)
    expect(redo(undo(h)).present).toBe(40)
  })

  it('U6b a change that reports no drag (keyboard) gets no key', () => {
    expect(dragCoalescer()('n', undefined)).toBeUndefined()
  })
})
