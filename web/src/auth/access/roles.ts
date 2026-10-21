/**
 * The built-in role names, the same set as `@roles` in `lib/letflow/api/authorization.ex`
 * (tests/guards/role-set.spec.ts keeps the two equal). Role names may appear only inside this
 * directory (tests/guards/no-role-literals.spec.ts): the rest of the SPA asks `can(permission)`.
 */
export const ROLES = [
  'PLATFORM_ADMIN',
  'PROCESS_DESIGNER',
  'PROCESS_OPERATOR',
  'TASK_WORKER',
  'AGENT_RUNNER',
  'CANDIDATE',
  'TENANT_ADMIN',
  'TENANT_AUDITOR',
] as const

export type Role = (typeof ROLES)[number]
