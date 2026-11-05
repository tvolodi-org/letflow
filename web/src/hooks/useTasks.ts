/** TanStack Query hooks for tasks */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { tasksApi } from '@/api/tasks'
import type { CompleteTaskRequest, TaskStatus } from '@/types/api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export function useTasks(params?: { status?: TaskStatus; instance_id?: string }) {
  const taskKeys = useTenantScopedQueryKeys().tasks
  return useQuery({
    queryKey: taskKeys.list(params ?? {}),
    queryFn: () => tasksApi.list(params),
  })
}

export function useTask(id: string) {
  const taskKeys = useTenantScopedQueryKeys().tasks
  return useQuery({
    queryKey: taskKeys.detail(id),
    queryFn: () => tasksApi.get(id),
    enabled: !!id,
  })
}

export function useTaskInbox() {
  const taskKeys = useTenantScopedQueryKeys().tasks
  const pollInterval = Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? 10_000)
  return useQuery({
    queryKey: taskKeys.inbox(),
    queryFn: () => tasksApi.inbox(),
    refetchInterval: pollInterval,
    refetchIntervalInBackground: false,
  })
}

export function useCompleteTask() {
  const qc = useQueryClient()
  const taskKeys = useTenantScopedQueryKeys().tasks
  return useMutation({
    mutationFn: ({ id, body }: { id: string; body: CompleteTaskRequest }) =>
      tasksApi.complete(id, body),
    onSuccess: (_data, { id }) => {
      qc.invalidateQueries({ queryKey: taskKeys.detail(id) })
      qc.invalidateQueries({ queryKey: taskKeys.inbox() })
    },
  })
}

export function useClaimTask() {
  const qc = useQueryClient()
  const taskKeys = useTenantScopedQueryKeys().tasks
  return useMutation({
    mutationFn: (id: string) => tasksApi.claim(id),
    onSuccess: (_data, id) => {
      qc.invalidateQueries({ queryKey: taskKeys.detail(id) })
      qc.invalidateQueries({ queryKey: taskKeys.inbox() })
    },
  })
}

export function useReassignTask() {
  const qc = useQueryClient()
  const taskKeys = useTenantScopedQueryKeys().tasks
  return useMutation({
    mutationFn: ({ id, assigneeRef }: { id: string; assigneeRef: string }) =>
      tasksApi.reassign(id, assigneeRef),
    onSuccess: (_data, { id }) => {
      qc.invalidateQueries({ queryKey: taskKeys.detail(id) })
    },
  })
}
