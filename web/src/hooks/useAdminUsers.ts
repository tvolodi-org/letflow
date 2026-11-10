import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi, groupsApi } from '@/api/identity'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export type AdminUserFilters = {
  search: string
  status: 'ALL' | 'active' | 'inactive'
  cursor?: string
  page_size: number
}

export function useAdminUsers(filters: AdminUserFilters) {
  const adminKeys = useTenantScopedQueryKeys().admin
  return useQuery({
    queryKey: adminKeys.users(filters),
    queryFn: () =>
      usersApi.list({
        search: filters.search || undefined,
        status: filters.status === 'ALL' ? undefined : filters.status,
        cursor: filters.cursor,
        page_size: filters.page_size,
      }),
  })
}

export function useAdminUser(userId: string) {
  const adminKeys = useTenantScopedQueryKeys().admin
  return useQuery({
    queryKey: adminKeys.userDetail(userId),
    queryFn: () => usersApi.get(userId),
    enabled: userId.length > 0,
  })
}

export function useAdminRoles() {
  const adminKeys = useTenantScopedQueryKeys().admin
  return useQuery({
    queryKey: adminKeys.roles(),
    queryFn: () => rolesApi.list(),
  })
}

export function useAdminGroups() {
  const adminKeys = useTenantScopedQueryKeys().admin
  return useQuery({
    queryKey: adminKeys.groups(),
    queryFn: () => groupsApi.list(),
  })
}

export function useCreateAdminUser() {
  const queryClient = useQueryClient()
  const adminKeys = useTenantScopedQueryKeys().admin
  return useMutation({
    mutationFn: usersApi.create,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: adminKeys.users() })
    },
  })
}

export function useUpdateAdminUser(userId: string) {
  const queryClient = useQueryClient()
  const adminKeys = useTenantScopedQueryKeys().admin
  return useMutation({
    mutationFn: (body: Parameters<typeof usersApi.update>[1]) => usersApi.update(userId, body),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: adminKeys.userDetail(userId) })
      queryClient.invalidateQueries({ queryKey: adminKeys.users() })
    },
  })
}

export function useDeactivateAdminUser(userId: string) {
  const queryClient = useQueryClient()
  const adminKeys = useTenantScopedQueryKeys().admin
  return useMutation({
    mutationFn: () => usersApi.update(userId, { status: 'inactive', is_active: false }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: adminKeys.userDetail(userId) })
      queryClient.invalidateQueries({ queryKey: adminKeys.users() })
    },
  })
}

/** REQ-789: asks the identity provider to e-mail the user a reset link. Changes nothing in the user record, so no invalidation. */
export function useSendPasswordResetInstructions(userId: string) {
  return useMutation({
    mutationFn: () => usersApi.sendPasswordResetInstructions(userId),
  })
}
