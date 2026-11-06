/** Tone and glyph of a document state pill (a word and a glyph, never colour alone). */
import type { StatusGlyph, StatusTone } from '@/components/ui/StatusPill'

export function stateTone(state: string): { tone: StatusTone; glyph: StatusGlyph } {
  switch (state) {
    case 'draft': return { tone: 'neutral', glyph: 'ring' }
    case 'issued': return { tone: 'info', glyph: 'half' }
    case 'posted': return { tone: 'success', glyph: 'dot' }
    case 'reversed': return { tone: 'warning', glyph: 'triangle' }
    case 'cancelled': return { tone: 'neutral', glyph: 'dash' }
    default: return { tone: 'neutral', glyph: 'dot' }
  }
}
