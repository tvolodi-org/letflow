import { describe, expect, it } from 'vitest'
import { documentStateTone } from '../documentStateTone'

describe('documentStateTone', () => {
  it.each([
    ['draft', 'neutral', 'ring'],
    ['issued', 'info', 'half'],
    ['posted', 'success', 'dot'],
    ['reversed', 'warning', 'triangle'],
    ['cancelled', 'neutral', 'dash'],
    ['anything-else', 'neutral', 'dot'],
  ])('%s -> %s / %s', (state, tone, glyph) => {
    expect(documentStateTone(state)).toEqual({ tone, glyph })
  })
})
