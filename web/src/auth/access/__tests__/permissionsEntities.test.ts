/** REQ-634 P1 — the new permission atoms equal the backend atoms and the fixtures agree. */
import { describe, expect, it } from 'vitest'
import { P } from '../types'
import { ACCESS_FIXTURES } from '../fixtures'

describe('REQ-634 P1 permission atoms', () => {
  it('names the backend atoms', () => {
    expect(P.EntitiesQuery).toBe('EntitiesQuery')
    expect(P.EntitiesAggregate).toBe('EntitiesAggregate')
  })

  it('tenantAdmin and platformAdmin fixtures hold both; candidate and agentRunner hold neither query', () => {
    for (const name of ['tenantAdmin', 'platformAdmin'] as const) {
      const perms: readonly string[] = ACCESS_FIXTURES[name].permissions
      expect(perms).toContain(P.EntitiesQuery)
      expect(perms).toContain(P.EntitiesAggregate)
    }
    for (const name of ['agentRunner', 'candidate'] as const) {
      const perms: readonly string[] = ACCESS_FIXTURES[name].permissions
      expect(perms).not.toContain(P.EntitiesQuery)
    }
  })
})
