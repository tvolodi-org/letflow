/** T-1442 P1-P8 — the sanitize rules equal the design repo's LFPrefs and the server's sanitize_layout/1. */
import { describe, expect, it } from 'vitest'
import { emptyLayout, parseLayoutJson, sanitizeUiLayout, setCols, setPanes, setShell, getPanes, resetScreen } from '../layoutPrefs'

describe('sanitizeUiLayout', () => {
  it('P1 non-object input gives the empty document', () => {
    for (const bad of [null, undefined, 5, 'x', [1]]) expect(sanitizeUiLayout(bad)).toEqual(emptyLayout())
    expect(parseLayoutJson('{nope')).toEqual(emptyLayout())
    expect(parseLayoutJson(null)).toEqual(emptyLayout())
  })

  it('P2 side nav width is clamped to 160-420 and rounded; collapsed must be a boolean', () => {
    expect(sanitizeUiLayout({ shell: { sidenav: { w: 100 } } }).shell.sidenav.w).toBe(160)
    expect(sanitizeUiLayout({ shell: { sidenav: { w: 999 } } }).shell.sidenav.w).toBe(420)
    expect(sanitizeUiLayout({ shell: { sidenav: { w: 250.4 } } }).shell.sidenav.w).toBe(250)
    expect(sanitizeUiLayout({ shell: { sidenav: { w: '250', collapsed: 'yes' } } }).shell.sidenav).toEqual({})
    expect(sanitizeUiLayout({ shell: { sidenav: { collapsed: true } } }).shell.sidenav).toEqual({ collapsed: true })
  })

  it('P3 pane sizes are clamped to 5-85 and rounded to 0.1; an all-null list is dropped', () => {
    const out = sanitizeUiLayout({ screens: { 'a.b': { panes: { s1: [1, 90, null, 38.34], s2: [null, null] } } } })
    expect(out.screens['a.b']?.panes).toEqual({ s1: [5, 85, null, 38.3] })
  })

  it('P4 column widths are clamped to 3-80; bad ids are dropped', () => {
    const out = sanitizeUiLayout({ screens: { s: { cols: { t1: { item: 1, 'Bad Id': 20, qty: 200, x: 'a' } } } } })
    expect(out.screens.s?.cols).toEqual({ t1: { item: 3, qty: 80 } })
  })

  it('P5 bad screen, split and table ids are dropped', () => {
    const long = 'a'.repeat(49)
    const out = sanitizeUiLayout({
      screens: { 'Bad Id': { panes: { s: [20] } }, [long]: { panes: { s: [20] } }, ok: { panes: { 'Bad!': [20], good: [20] } } },
    })
    expect(Object.keys(out.screens)).toEqual(['ok'])
    expect(out.screens.ok?.panes).toEqual({ good: [20] })
  })

  it('P6 caps: 40 screens, 12 panes keys, 12 entries; collapsed keeps integers 0-11', () => {
    const screens: Record<string, unknown> = {}
    for (let i = 0; i < 41; i++) screens[`s${String(i).padStart(2, '0')}`] = { panes: { a: [20] } }
    expect(Object.keys(sanitizeUiLayout({ screens }).screens)).toHaveLength(40)
    const panes: Record<string, number[]> = {}
    for (let i = 0; i < 13; i++) panes[`p${String(i).padStart(2, '0')}`] = [20]
    expect(Object.keys(sanitizeUiLayout({ screens: { s: { panes } } }).screens.s?.panes ?? {})).toHaveLength(12)
    const long = Array.from({ length: 14 }, () => 20)
    expect(sanitizeUiLayout({ screens: { s: { panes: { a: long } } } }).screens.s?.panes?.a).toHaveLength(12)
    const c = sanitizeUiLayout({ screens: { s: { collapsed: { a: [0, 1.5, -1, 12, 3, 'x'] } } } })
    expect(c.screens.s?.collapsed).toEqual({ a: [0, 3] })
  })

  it('P7 over 8192 bytes empties screens, keeps the shell', () => {
    const screens: Record<string, unknown> = {}
    for (let i = 0; i < 40; i++) {
      const cols: Record<string, Record<string, number>> = {}
      for (let t = 0; t < 24; t++) {
        const c: Record<string, number> = {}
        for (let k = 0; k < 6; k++) c[`c${k}`] = 10.5
        cols[`t${String(t).padStart(2, '0')}`] = c
      }
      screens[`s${String(i).padStart(2, '0')}`] = { cols }
    }
    const out = sanitizeUiLayout({ shell: { sidenav: { w: 300 } }, screens })
    expect(out.screens).toEqual({})
    expect(out.shell.sidenav.w).toBe(300)
  })

  it('P8 linesMode is kept only as "grid" or "form" (T-1448, twin of the server); unknown keys are dropped', () => {
    const out = sanitizeUiLayout({ evil: 1, screens: { s: { linesMode: 'grid', foo: 1, panes: { a: [30] } }, t: { linesMode: 'bad' } } })
    expect(out).toEqual({ v: 1, shell: { sidenav: {} }, screens: { s: { panes: { a: [30] }, linesMode: 'grid' } } })
  })
})

describe('immutable setters', () => {
  it('set, read and reset without touching the input', () => {
    const base = emptyLayout()
    const a = setPanes(base, 's', 'sp', [22, null])
    expect(base.screens).toEqual({})
    expect(getPanes(a, 's', 'sp')).toEqual([22, null])
    expect(setPanes(a, 's', 'sp', [null, null]).screens).toEqual({})
    expect(setCols(a, 's', 't', { c: 20 }).screens.s?.cols).toEqual({ t: { c: 20 } })
    expect(setShell(a, { w: 300, collapsed: true }).shell.sidenav).toEqual({ w: 300, collapsed: true })
    expect(setShell(setShell(a, { w: 300 }), { w: null }).shell.sidenav).toEqual({})
    expect(resetScreen(a, 's').screens).toEqual({})
  })
})
