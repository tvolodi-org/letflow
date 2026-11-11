import { client } from './client'
import type {
  User,
  Group,
  GroupListResponse,
  GroupMemberAddResult,
  GroupMemberPage,
  Role,
  ApiToken,
  IssuedToken,
  CursorPage,
} from '@/types/api'

// ── Users ──────────────────────────────────────────────────────────────────────

export const usersApi = {
  // ISS-0823/ISS-0816: usersApi.list returns CursorPage<User> (Pagination.page_response
  // emits {items, next_cursor, count}), not PagedResponse<User>.
  // The page param is dead — handle_list/2 reads cursor, not page.
  list: (params?: { cursor?: string; page_size?: number; search?: string; status?: string }) =>
    client.get<CursorPage<User>>('/api/v1/identity/users', params as Record<string, unknown>),

  get: (id: string) =>
    client.get<User>(`/api/v1/identity/users/${id}`),

  create: (body: { username: string; email: string; display_name: string; password: string; role_ids?: string[] }) =>
    client.post<User>('/api/v1/identity/users', body),

  update: (id: string, body: Partial<{ display_name: string; email: string; status: 'active' | 'inactive'; is_active: boolean; role_ids: string[]; group_ids: string[] }>) =>
    client.patch<User>(`/api/v1/identity/users/${id}`, body),

  // REQ-788/REQ-789: asks the identity provider to e-mail the user a reset link. The route accepts only an
  // empty body (a password in it is refused with 422), so the page never handles a password.
  sendPasswordResetInstructions: (id: string) =>
    client.post<{ status: 'requested' }>(`/api/v1/identity/users/${id}/reset-password`, {}),

  // REQ-807/REQ-809: creates the realm login for an internal user; the answer carries the temporary password once.
  // The route refuses a non-empty body, so `{}` (the empty map) is sent.
  createSignIn: (id: string) =>
    client.post<{ user: User; temporary_password: string }>(`/api/v1/identity/users/${id}/sign-in`, {}),

  // `usersApi.delete` removed in ISS-0813.
  // `DELETE /identity/users/:id` does not exist in Letflow.Routers.Identity.__authz_routes__/0
  // at any prefix. Do not re-add until a backend route exists.
}

// ── Groups ─────────────────────────────────────────────────────────────────────

export const groupsApi = {
  list: () =>
    client.get<GroupListResponse>('/api/v1/identity/groups'),

  // `groupsApi.get(id)` and `groupsApi.update(id, body)` were removed in ISS-0765
  // (run `WF03-ISS0765-20260924`). `GET /groups/:id` and `PATCH|PUT /groups/:id` do not
  // exist in `Letflow.Routers.Identity.__authz_routes__/0` at any prefix, and
  // `lib/letflow/identity.ex` has no `get_group/2` or `update_group/3` — these are
  // unimplemented operations, not mis-prefixed ones. Do not re-add a client function for
  // either until a backend route exists; adding one is a WF-01 requirement.

  create: (body: { name: string; display_name: string; description?: string }) =>
    client.post<Group>('/api/v1/identity/groups', body),

  delete: (id: string) =>
    client.delete<void>(`/api/v1/identity/groups/${id}`),

  addMember: (id: string, userId: string) =>
    client.post<GroupMemberAddResult>(`/api/v1/identity/groups/${id}/members`, { user_id: userId }),

  removeMembers: (id: string, userId: string) =>
    client.delete<void>(`/api/v1/identity/groups/${id}/members/${userId}`),

  members: (id: string) =>
    client.get<GroupMemberPage>(`/api/v1/identity/groups/${id}/members`),
}

// ── Roles ──────────────────────────────────────────────────────────────────────

export const rolesApi = {
  list: () =>
    client.get<{ items: Role[] }>('/api/v1/identity/roles'),

  create: (body: { name: string; description?: string }) =>
    client.post<Role>('/api/v1/identity/roles', body),

  // rolesApi.get, rolesApi.update, rolesApi.delete, rolesApi.grantPermission, and
  // rolesApi.revokePermission were removed in ISS-0813.
  // `GET/PATCH/DELETE /roles/:id` and `POST/DELETE /roles/:id/permissions` do not
  // exist in Letflow.Routers.Identity.__authz_routes__/0 at any prefix — these are
  // unimplemented backend operations, not mis-prefixed ones.
  // Do not re-add a client function until a backend route exists (WF-01 requirement).
}

// ── API Tokens ─────────────────────────────────────────────────────────────────

export const tokensApi = {
  list: () =>
    client.get<{ items: ApiToken[] }>('/api/v1/identity/tokens'),

  /** Returns the raw token value once — store it immediately */
  create: (body: { user_id: string; roles: string[]; expires_at?: string }) =>
    client.post<IssuedToken>('/api/v1/identity/tokens', body),

  revoke: (id: string) =>
    client.delete<void>(`/api/v1/identity/tokens/${id}`),
}
