import { client } from './client'
import type { AccessInfo } from '@/auth/access/types'

export interface InstalledModule {
  module_id: string
  version: string
}

export interface InstalledModulesResponse {
  installed_modules: InstalledModule[]
}

export const meApi = {
  listInstalledModules: () => client.get<InstalledModulesResponse>('/api/v1/me/modules'),
  /** GET /me/access (REQ-449): the caller's effective roles, permissions and platform-tenant flag. */
  getAccess: () => client.get<AccessInfo>('/api/v1/me/access'),
  /** Same call with an explicit token, for the login path where it is not installed yet. */
  getAccessWithToken: (token: string) => client.getWithToken<AccessInfo>('/api/v1/me/access', token),
}
