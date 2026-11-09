import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const SRC = join(__dirname, '../../src')

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) {
      if (name !== '__tests__') walk(p, out)
    } else if (name.endsWith('.tsx') && !/\.test\./.test(name)) out.push(p)
  }
  return out
}

// Own Tab handler, reviewed by hand (design T-1586, dialog inventory in docs/design-system/accessibility.md).
const OWN_TRAP = ['components/ui/Dialog.tsx', 'components/instances/CancelInstanceDialog.tsx', 'components/instances/RebindPinDialog.tsx']

describe('modal dialog inventory (T-1586)', () => {
  const files = walk(SRC).filter((f) => /^\s*(<div\s+)?(role="dialog"|aria-modal="true")|<div[^>]*role="dialog"/m.test(readFileSync(f, 'utf8')))

  it('D1: every file with a modal dialog traps focus', () => {
    expect(files.length).toBeGreaterThan(10)
    for (const f of files) {
      const rel = relative(SRC, f).split('\\').join('/')
      const s = readFileSync(f, 'utf8')
      const ok = OWN_TRAP.includes(rel) ? s.includes("'Tab'") : s.includes('useModalFocus') || /<Dialog\b|<ConfirmDialog\b/.test(s) || rel === 'components/ui/DateField.tsx'
      expect(ok, rel).toBe(true)
    }
  })

  it('D5: the date calendar popover is not aria-modal', () => {
    const s = readFileSync(join(SRC, 'components/ui/DateField.tsx'), 'utf8')
    expect(s).toContain('role="dialog"')
    expect(s).not.toContain('aria-modal')
  })
})
