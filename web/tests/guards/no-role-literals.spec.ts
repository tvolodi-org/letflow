// @vitest-environment node
/**
 * REQ-450 / GH #2238 — role names live in one place.
 *
 * The SPA decides what to show from GET /me/access through `can(permission)` /
 * `useAccess()` (web/src/auth/access). Hand-copied role lists drifted from the server's matrix
 * (one of them named a role, `PROCESS_ADMIN`, that does not exist), so:
 *
 *   1. no `*.ts` / `*.tsx` file under web/src, outside web/src/auth/access/, contains a built-in
 *      role name as a whole word (comments and tests included: a test picks an access fixture by
 *      key and never writes a role name);
 *   2. no file under web/ (node_modules and build output aside) contains the word PROCESS_ADMIN,
 *      the role that never existed.
 *
 * The role names are read out of lib/letflow/api/authorization.ex's `@roles` attribute, so the
 * list cannot drift from the server.
 */

import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { extractMatrixRoles } from './matrixRoles'

const WEB_ROOT = join(__dirname, '..', '..')
const REPO_ROOT = join(WEB_ROOT, '..')
const SRC_ROOT = join(WEB_ROOT, 'src')
const ACCESS_DIR = join(SRC_ROOT, 'auth', 'access')
const SKIPPED_DIRS = new Set(['node_modules', 'dist', 'playwright-report', 'test-results', '.vite', 'coverage'])

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (SKIPPED_DIRS.has(name)) continue
    const full = join(dir, name)
    const st = statSync(full)
    if (st.isDirectory()) walk(full, out)
    else out.push(full)
  }
  return out
}

/** `file:line` for every whole-word occurrence of one of `words` in `text`. */
export function findWholeWords(text: string, words: readonly string[], label: string): string[] {
  const re = new RegExp(String.raw`\b(?:${words.join('|')})\b`)
  const hits: string[] = []
  text.split(/\r?\n/).forEach((line, i) => {
    if (re.test(line)) hits.push(`${label}:${i + 1}`)
  })
  return hits
}

const matrixRoles = extractMatrixRoles(
  readFileSync(join(REPO_ROOT, 'lib', 'letflow', 'api', 'authorization.ex'), 'utf8'),
)

describe('no-role-literals', () => {
  it('self-check: the scanner flags a role name in a sample and ignores a longer identifier', () => {
    expect(findWholeWords(`x\nconst r = '${matrixRoles[0]}'`, matrixRoles, 'sample.ts')).toEqual(['sample.ts:2'])
    expect(findWholeWords(`const ${matrixRoles[0]}_SESSION = 1`, matrixRoles, 'sample.ts')).toEqual([])
  })

  it('reads the eight built-in roles from the matrix', () => {
    expect(matrixRoles).toHaveLength(8)
  })

  it('no role name appears in web/src outside web/src/auth/access', () => {
    const hits = walk(SRC_ROOT)
      .filter((f) => /\.(ts|tsx)$/.test(f) && !f.endsWith('.d.ts'))
      .filter((f) => !f.startsWith(ACCESS_DIR + sep))
      .flatMap((f) =>
        findWholeWords(readFileSync(f, 'utf8'), matrixRoles, relative(WEB_ROOT, f).split(sep).join('/')),
      )
    expect(
      hits,
      'Role names belong in web/src/auth/access only. Gate with can(<permission>) from the access module; ' +
        'in a test pick a fixture from web/src/auth/access/fixtures.ts by key.',
    ).toEqual([])
  })

  it('PROCESS_ADMIN (a role that does not exist) appears nowhere under web/', () => {
    const hits = walk(WEB_ROOT)
      .filter((f) => !f.endsWith(join('tests', 'guards', 'no-role-literals.spec.ts')))
      .filter((f) => /\.(ts|tsx|js|jsx|json|md|yml|yaml|html|css)$/.test(f) && !f.endsWith('package-lock.json'))
      .flatMap((f) => findWholeWords(readFileSync(f, 'utf8'), ['PROCESS_ADMIN'], relative(WEB_ROOT, f).split(sep).join('/')))
    expect(hits).toEqual([])
  })
})
