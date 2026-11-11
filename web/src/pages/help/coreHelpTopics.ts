/** coreHelpTopics — T-1691. The closed list of static help topics of the core admin screens built after B2#8 (users
 *  import, password reset, instance replay, module rollouts), the screen each one explains and the permission of that
 *  screen (help never opens for a user who cannot open the screen). Route: `/help/:topic`. */
import { P, type Permission } from '@/auth/access'

export const CORE_HELP_TOPICS = ['usersImport', 'passwordReset', 'instanceReplay', 'moduleRollouts', 'createSignIn'] as const
export type CoreHelpTopic = (typeof CORE_HELP_TOPICS)[number]

/** `permission` is absent where the screen itself has no guard (instances); `platformOnly` as the screen's route. */
export const CORE_HELP_ACCESS: Record<CoreHelpTopic, { permission?: Permission; platformOnly?: boolean }> = {
  usersImport: { permission: P.UsersGroupsRolesManage },
  passwordReset: { permission: P.UsersGroupsRolesManage },
  instanceReplay: {},
  moduleRollouts: { permission: P.ModuleRolloutsManage, platformOnly: true },
  createSignIn: { permission: P.UsersGroupsRolesManage },
}

export const CORE_HELP_BACK: Record<CoreHelpTopic, string> = {
  usersImport: '/admin/users/import',
  passwordReset: '/admin/users',
  instanceReplay: '/instances',
  moduleRollouts: '/admin/module-rollouts',
  createSignIn: '/admin/users',
}

export function isCoreHelpTopic(value: string | undefined): value is CoreHelpTopic {
  return value !== undefined && (CORE_HELP_TOPICS as readonly string[]).includes(value)
}

export const coreHelpPath = (topic: CoreHelpTopic) => `/help/${topic}`
