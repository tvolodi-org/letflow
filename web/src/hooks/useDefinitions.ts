/** TanStack Query hooks — query key factories + hooks for all APIs */
import { useMemo } from 'react'
import { useQuery, useQueries, useMutation, useQueryClient } from '@tanstack/react-query'
import { definitionsApi } from '@/api/definitions'
import { definitionRollbackApi } from '@/api/definitionRollback'
import type { DefinitionStatus, CreateDefinitionRequest, ProcessDefinition } from '@/types/api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useDefinitions(params?: { status?: DefinitionStatus; name?: string }) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.list(params ?? {}),
    queryFn: () => definitionsApi.list(params),
  })
}

export function useDefinition(id: string) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.detail(id),
    queryFn: () => definitionsApi.get(id),
    enabled: !!id,
  })
}

/** Resolves definition name/version for many ids (the instances list sends definition_id only).
 *  Shares the detail cache with useDefinition; an id that fails to load is simply absent. */
export function useDefinitionsByIds(ids: string[]): Map<string, ProcessDefinition> {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  const unique = Array.from(new Set(ids.filter(Boolean)))
  const results = useQueries({
    queries: unique.map((id) => ({
      queryKey: definitionKeys.detail(id),
      queryFn: () => definitionsApi.get(id),
      retry: false,
    })),
  })
  const signature = results.map((r, i) => `${unique[i]}:${r.dataUpdatedAt}`).join('|')
  return useMemo(() => {
    const map = new Map<string, ProcessDefinition>()
    results.forEach((r, i) => {
      if (r.data) map.set(unique[i], r.data)
    })
    return map
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature])
}

export function useCreateDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (body: CreateDefinitionRequest) => definitionsApi.create(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: definitionKeys.all() }),
  })
}

export function useDefinitionVersions(name: string) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.versions(name),
    queryFn: () => definitionsApi.getVersions(name),
    enabled: !!name,
  })
}

export function useActivateDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (id: string) => definitionsApi.activate(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}

/** REQ-431 — read-only, save-time server-side semantic-validation re-check.
 *  No onSuccess invalidation: validate_definition_graph/2 adds no rule of its
 *  own and mutates no server state (design §3.4). Mirrors useActivateDefinition's
 *  shape minus the invalidateQueries calls. */
export function useValidateDefinition() {
  return useMutation({
    mutationFn: (id: string) => definitionsApi.validate(id),
  })
}

export function useArchiveDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (id: string) => definitionsApi.archive(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: definitionKeys.detail(id) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
    },
  })
}

/** REQ-371: rollback/withdrawal mutation. See
 *  `lib/letflow/design/req371-rollback-withdrawal-screen.md` §3 — no
 *  `onSuccess` local change-history write here (`DefinitionRollbackPage.tsx`
 *  owns that as component-local state, §7.2), only the query invalidations
 *  needed so an already-mounted `InstanceBoardPage.tsx` picks up the
 *  restored active version (§1.6/AC4).
 */
export function useRollbackDefinition() {
  const qc = useQueryClient()
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useMutation({
    mutationFn: (args: { processKey: string; targetVersion: string }) =>
      definitionRollbackApi.rollback(args.processKey, { target_version: args.targetVersion }),
    onSuccess: (_data, args) => {
      qc.invalidateQueries({ queryKey: definitionKeys.active(args.processKey) })
      qc.invalidateQueries({ queryKey: definitionKeys.list({}) })
      qc.invalidateQueries({ queryKey: definitionKeys.versions(args.processKey) })
    },
  })
}

// ISS-0820: limit/offset removed — handle_search/1 only reads q, cursor, page_size.
export function useDefinitionSearch(query: string, options?: { page_size?: number; cursor?: string }) {
  const definitionKeys = useTenantScopedQueryKeys().definitions
  return useQuery({
    queryKey: definitionKeys.search(query, options?.page_size, options?.cursor),
    queryFn: () => definitionsApi.search({ q: query, page_size: options?.page_size, cursor: options?.cursor }),
    enabled: query.trim().length > 0,
  })
}
