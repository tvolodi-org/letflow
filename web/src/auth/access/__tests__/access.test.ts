// @vitest-environment node
import { describe, expect, it } from 'vitest'
import { accessState, ERROR_STATE, LOADING_STATE } from '../fixtures'
import { can, canManageTenants, isCandidate, isPlatformTenant, rolesOf } from '../access'
import { P } from '../types'

describe('can() over a mocked /me/access fixture', () => {
  it('is true only for a permission the fixture lists', () => {
    expect(can(accessState('tenantAdmin'), P.UsersGroupsRolesManage)).toBe(true)
    expect(can(accessState('taskWorker'), P.UsersGroupsRolesManage)).toBe(false)
    expect(can(accessState('operator'), P.DlqOperate)).toBe(true)
    expect(can(accessState('designer'), P.DlqOperate)).toBe(false)
    expect(can(accessState('auditor'), P.AuditRead)).toBe(true)
  })

  it('is false for an unknown permission name', () => {
    expect(can(accessState('platformAdmin'), 'NoSuchPermission')).toBe(false)
  })

  it.each([
    ['loading', LOADING_STATE],
    ['error', ERROR_STATE],
  ])('is false for every permission while access is %s', (_name, state) => {
    expect(can(state, P.InstancesRead)).toBe(false)
    expect(can(state, P.TenantsManage)).toBe(false)
    expect(isPlatformTenant(state)).toBe(false)
    expect(canManageTenants(state)).toBe(false)
    expect(rolesOf(state)).toEqual([])
  })
})

describe('platform authority', () => {
  it('canManageTenants needs the platform tenant AND the permission', () => {
    expect(canManageTenants(accessState('platformAdmin'))).toBe(true)
    expect(canManageTenants(accessState('tenantAdmin'))).toBe(false)
    // the permission without the platform flag is not platform authority
    expect(
      canManageTenants({ status: 'ready', info: { roles: [], permissions: [P.TenantsManage], platform_tenant: false } }),
    ).toBe(false)
    // the platform flag without the permission neither
    expect(
      canManageTenants({ status: 'ready', info: { roles: [], permissions: [], platform_tenant: true } }),
    ).toBe(false)
  })

  it('isCandidate follows the reported roles', () => {
    expect(isCandidate(accessState('candidate'))).toBe(true)
    expect(isCandidate(accessState('taskWorker'))).toBe(false)
  })
})
