// @vitest-environment node
/**
 * T-1169: web/public/design-system/ is a release artifact copied from the design repo by
 * scripts/sync-design-system.sh. It must not be edited by hand, must not be indexed, and every
 * local file a page names must exist (so /design-system/ and /design-system/examples/org-units.html
 * work as static files with no sign-in). The comparison with the design repo itself is
 * `scripts/sync-design-system.sh --check` (needs the design repo, so not part of this unit test).
 */
import { describe, it, expect } from 'vitest'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, normalize } from 'node:path'

const ROOT = join(__dirname, '..', '..', 'public', 'design-system')
const PAGES = ['index.html', 'examples/org-units.html', 'examples/codes.html', 'examples/import.html']

const manifest = readFileSync(join(ROOT, 'MANIFEST.sha256'), 'utf8')
  .trim()
  .split('\n')
  .map((line) => {
    const m = /^([0-9a-f]{64}) {2}\.\/(.+)$/.exec(line)
    if (!m) throw new Error(`bad manifest line: ${line}`)
    return { hash: m[1], file: m[2] }
  })

describe('design-system copy', () => {
  it('every file matches the manifest written by the sync script (no hand edits)', () => {
    expect(manifest.length).toBeGreaterThan(PAGES.length)
    for (const { hash, file } of manifest) {
      const actual = createHash('sha256').update(readFileSync(join(ROOT, file))).digest('hex')
      expect({ file, actual }).toEqual({ file, actual: hash })
    }
  })

  it('ships the style guide, the three example pages and the generated css', () => {
    const files = manifest.map((m) => m.file)
    for (const f of [...PAGES, 'css/tokens.css', 'css/components.css', 'demo.js']) expect(files).toContain(f)
  })

  it.each(PAGES)('%s is noindex and its local references exist', (page) => {
    const html = readFileSync(join(ROOT, page), 'utf8')
    expect(html).toContain('<meta name="robots" content="noindex">')
    const refs = [...html.matchAll(/(?:href|src)="([^"#?]+)(?:[?#][^"]*)?"/g)]
      .map((m) => m[1])
      .filter((r) => !/^(https?:|\/\/|data:|mailto:)/.test(r))
    for (const ref of refs) {
      expect({ page, ref, exists: existsSync(normalize(join(ROOT, dirname(page), ref))) }).toEqual({ page, ref, exists: true })
    }
  })

  it('style guide carries the copy-date header line', () => {
    const html = readFileSync(join(ROOT, 'index.html'), 'utf8')
    expect(html).toMatch(/Letflow platform design system, copy of \d{4}-\d{2}-\d{2} of letflow-design/)
  })

  it('does not name any tenant or API route', () => {
    for (const page of PAGES) {
      expect(readFileSync(join(ROOT, page), 'utf8')).not.toMatch(/\/api\/|fetch\(/)
    }
  })
})
