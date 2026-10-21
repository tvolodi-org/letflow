// @vitest-environment node
/**
 * REQ-129 / REQ-450 — proves the access module's `ROLES` list
 * (web/src/auth/access/roles.ts, the only place the SPA names roles) is exactly the
 * authorization matrix's role set (`Letflow.Api.Authorization.roles/0`).
 *
 * This guard used to measure AppShell's nav-gating `Role` union one-directionally, because
 * that union left out the machine role `AGENT_RUNNER` (decisions/0013-authorization-role-set.md).
 * The union is gone: nav and page gating ask `can(permission)` against GET /me/access, and
 * `ROLES` is a full mirror of the matrix, so the asymmetry no longer exists and the check is
 * now an equality. It is a moved measurement, not a weaker one: a role in either list and not
 * the other fails.
 *
 * The matrix's role list is read directly out of lib/letflow/api/authorization.ex's `@roles`
 * module attribute (not hand-copied here) so this check can't itself drift from the Elixir
 * source of truth. The Elixir-side equivalent -- realm vs. matrix -- lives in
 * test/letflow/api/authorization_role_realm_test.exs.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ROLES } from '../../src/auth/access/roles'
import { extractMatrixRoles } from './matrixRoles'

const REPO_ROOT = join(__dirname, '..', '..', '..')
const AUTHORIZATION_EX_PATH = join(REPO_ROOT, 'lib', 'letflow', 'api', 'authorization.ex')

describe('role-set: the access module ROLES list equals the authorization matrix role set', () => {
  it('ROLES in web/src/auth/access/roles.ts equals Letflow.Api.Authorization.roles/0 exactly', () => {
    const matrixRoles = extractMatrixRoles(readFileSync(AUTHORIZATION_EX_PATH, 'utf8'))

    expect(matrixRoles.length).toBeGreaterThan(0)

    const missingFromSpa = matrixRoles.filter((role) => !(ROLES as readonly string[]).includes(role))
    const unknownToMatrix = ROLES.filter((role) => !matrixRoles.includes(role))

    expect(
      { missingFromSpa, unknownToMatrix },
      `ROLES (web/src/auth/access/roles.ts) and the matrix roles (lib/letflow/api/authorization.ex) differ. ` +
        'Per decisions/0013-authorization-role-set.md, do not resolve this by editing this guard -- ' +
        'fix whichever source is wrong, or write a new decision record if the role set itself is changing.',
    ).toEqual({ missingFromSpa: [], unknownToMatrix: [] })
  })
})
