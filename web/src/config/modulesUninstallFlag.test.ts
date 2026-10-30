// @vitest-environment node
/**
* REQ-630 F1-F3: the module uninstall flag is OFF by default in every
 * non-dev build. Behavioural default + a static assertion over the committed
 * env files, deploy/CI files and vite config that nothing committed sets it true.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { isModulesUninstallEnabled } from './modulesUninstallFlag'

const WEB_ROOT = path.resolve(__dirname, '..', '..')
const REPO_ROOT = path.resolve(WEB_ROOT, '..')

it('F2 the env template documents the flag as false', () => {
  expect(readFileSync(path.join(WEB_ROOT, '.env.example'), 'utf-8')).toMatch(/^VITE_MODULES_UNINSTALL_ENABLED=false$/m)
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('isModulesUninstallEnabled', () => {
  it('is off when the variable is unset', () => {
    vi.stubEnv('VITE_MODULES_UNINSTALL_ENABLED', '')
    expect(isModulesUninstallEnabled()).toBe(false)
  })

  it('is on only for the exact value true', () => {
    vi.stubEnv('VITE_MODULES_UNINSTALL_ENABLED', 'true')
    expect(isModulesUninstallEnabled()).toBe(true)
    for (const v of ['TRUE', '1', 'yes', 'false', ' true', 'on']) {
      vi.stubEnv('VITE_MODULES_UNINSTALL_ENABLED', v)
      expect(isModulesUninstallEnabled()).toBe(false)
    }
  })
})

function listFiles(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name)
    if (statSync(full).isDirectory()) listFiles(full, out)
    else out.push(full)
  }
  return out
}

/** A line that assigns VITE_MODULES_UNINSTALL_ENABLED a true value (env-file, compose,
 *  Dockerfile ARG/ENV or shell style), ignoring comment-only lines. */
const ENABLES_FLAG = /^\s*(?!#)(?:export\s+|ENV\s+|ARG\s+|-\s+)?VITE_MODULES_UNINSTALL_ENABLED\s*[=:]\s*["']?true\b/im

describe('committed build configuration never enables the flag', () => {
  const webEnvFiles = readdirSync(WEB_ROOT)
    .filter((n) => n.startsWith('.env') && !n.endsWith('.local'))
    .map((n) => path.join(WEB_ROOT, n))
  const deployFiles = [
    ...listFiles(path.join(REPO_ROOT, 'deploy')),
    ...listFiles(path.join(REPO_ROOT, '.github')),
    path.join(REPO_ROOT, '.env.example'),
  ].filter((f) => existsSync(f))

  it('scans at least the committed web env template and vite config', () => {
    expect(webEnvFiles.some((f) => f.endsWith('.env.example'))).toBe(true)
    expect(existsSync(path.join(WEB_ROOT, 'vite.config.ts'))).toBe(true)
  })

  for (const file of [...webEnvFiles, ...deployFiles, path.join(WEB_ROOT, 'vite.config.ts')]) {
    it(`${path.relative(REPO_ROOT, file).split(path.sep).join('/')} does not set it true`, () => {
      expect(readFileSync(file, 'utf-8')).not.toMatch(ENABLES_FLAG)
    })
  }

  it('the detector itself flags an enabling line (guards against a vacuous pass)', () => {
    expect('VITE_MODULES_UNINSTALL_ENABLED=true').toMatch(ENABLES_FLAG)
    expect('ENV VITE_MODULES_UNINSTALL_ENABLED=true').toMatch(ENABLES_FLAG)
    expect('# VITE_MODULES_UNINSTALL_ENABLED=true').not.toMatch(ENABLES_FLAG)
    expect('VITE_MODULES_UNINSTALL_ENABLED=false').not.toMatch(ENABLES_FLAG)
  })
})
