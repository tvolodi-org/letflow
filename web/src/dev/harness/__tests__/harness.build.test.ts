// @vitest-environment node
/**
 * Task S0d: the production build has no harness route and no harness module. `import.meta.env.DEV` is a build-time
 * constant; this builds the app into a temp directory and greps the output for the harness strings.
 */
import { describe, expect, it } from 'vitest'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { execFileSync } from 'node:child_process'
import fg from 'fast-glob'
import { HARNESS_ROUTE_MARKER } from '../HarnessPage'

const WEB_DIR = resolve(__dirname, '..', '..', '..', '..')

describe('harness is absent from the production build', () => {
  it(
    'no harness marker, route path or readiness url in any built file',
    () => {
      expect(HARNESS_ROUTE_MARKER).toBe('lf-screen-harness-route-marker')
      const outDir = mkdtempSync(join(tmpdir(), 'lf-harness-build-'))
      try {
        // A child process with NODE_ENV=production, as `npm run build` runs it: inside vitest NODE_ENV is "test",
        // which makes import.meta.env.DEV true.
        execFileSync('npx', ['vite', 'build', '--outDir', outDir, '--emptyOutDir', '--logLevel', 'error'], {
          cwd: WEB_DIR,
          env: { ...process.env, NODE_ENV: 'production' },
          stdio: 'pipe',
        })
        const files = fg.sync('**/*.{js,css,html}', { cwd: outDir })
        expect(files.length).toBeGreaterThan(0)
        const offenders = files.filter(f => {
          const text = readFileSync(join(outDir, f), 'utf8')
          return ['lf-screen-harness-route-marker', '__harness', 'HarnessPage'].some(s => text.includes(s))
        })
        expect(offenders).toEqual([])
      } finally {
        rmSync(outDir, { recursive: true, force: true })
      }
    },
    240_000,
  )
})
