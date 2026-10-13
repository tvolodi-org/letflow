// @vitest-environment node
/**
 * GRD-UI-03: Bundle scan — scan dist/assets/*.js after a clean vite build.
 *
 * Phase 1: Clean web/dist
 * Phase 2: Run npm run build (cwd: web/)
 * Phase 3: Discover dist/assets/*.js — fail if none found
 * Phase 4: Apply bundle-applicable patterns; fail if any violations found
 * Timeout: 180 000 ms.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync, rmSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { execSync } from 'node:child_process'
import fg from 'fast-glob'
import { PATTERNS } from './forbidlist'
import { writeViolations, assertRedacted } from './reporter'
import { scanBundle, summaryLines, type ScanFile } from './scan-core'

const WEB_DIR = join(__dirname, '..', '..')
const DIST_DIR = join(WEB_DIR, 'dist')

describe('bundle-scan', () => {
  it(
    'built bundle contains no guard violations',
    () => {
      // Phase 1: Clean
      rmSync(DIST_DIR, { recursive: true, force: true })

      // Phase 2: Build
      execSync('npm run build', { cwd: WEB_DIR, stdio: 'inherit' })

      // Phase 3: Discover assets
      const assetFiles = fg.sync('dist/assets/*.js', { cwd: WEB_DIR })
      expect(assetFiles.length, 'no build assets found — vite build produced no JS chunks').toBeGreaterThan(0)

      const bundlePatterns = PATTERNS.filter(p => p.appliesTo === 'bundle' || p.appliesTo === 'both')
      const evaluatedPatterns = bundlePatterns.map(p => p.name)

      // Phase 4: Scan
      const assets: ScanFile[] = assetFiles.map(relFile => ({
        wsPath: 'web/' + relFile.split('\\').join('/'),
        content: readFileSync(join(WEB_DIR, relFile), 'utf8'),
      }))
      const result = scanBundle(assets, bundlePatterns)
      const { violations } = result

      const ts = new Date().toISOString().slice(0, 19).split(':').join('-')
      const runId = process.env.GUARD_RUN_ID ?? ts
      assertRedacted(violations)
      writeViolations(violations, evaluatedPatterns, runId)

      if (violations.length > 0) {
        const summary = summaryLines(result, v => v.file).join('\n')
        expect.fail(`Bundle scan found ${violations.length} violation(s):\n${summary}`)
      }

      expect(violations).toHaveLength(0)
    },
    180_000,
  )

  it('GRD-UI-03 AC4: literal-colour is detected in a synthetic bundle fixture', () => {
    // Creates a temp JS asset with a raw hex colour literal (CSS-style, outside a string)
    // and verifies the literal-colour pattern fires — proving bundle-phase detection works.
    const ASSETS_DIR = join(DIST_DIR, 'assets')
    mkdirSync(ASSETS_DIR, { recursive: true })
    const fixturePath = join(ASSETS_DIR, '__guard-test-literal-colour.js')
    writeFileSync(fixturePath, '.btn{color:#ff0000;background:#e2e8f0;}\n', 'utf8')

    try {
      const wsPath = 'web/dist/assets/__guard-test-literal-colour.js'
      const content = readFileSync(fixturePath, 'utf8')
      const literalColour = PATTERNS.find(p => p.name === 'literal-colour')!

      // the same scan function the main test uses (scan-core.ts)
      const { violations } = scanBundle([{ wsPath, content }], [literalColour])

      expect(violations).toHaveLength(1)
      expect(violations[0].patternName).toBe('literal-colour')
    } finally {
      rmSync(fixturePath, { force: true })
    }
  })
})
