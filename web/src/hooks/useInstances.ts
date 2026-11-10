/** TanStack Query hooks for process instances */
import { useEffect, useMemo, useRef } from 'react'
import { useQuery, useMutation, useQueryClient, useInfiniteQuery } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import type {
  InstanceStatus,
  NodeEnteredItem,
  NodeEntriesPage,
  StartInstanceRequest,
  TimelineEntry,
  TimelinePage,
} from '@/types/api'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'

export interface EventFilters {
  event_type?: string
  from?: string
  to?: string
}

export function useInstances(params?: {
  status?: InstanceStatus[]
  definition_id?: string
  cursor?: string
  page_size?: number
}) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const filters = {
    status: params?.status,
    definition_id: params?.definition_id,
    cursor: params?.cursor,
    page_size: params?.page_size,
  }

  return useQuery({
    queryKey: instanceKeys.list(filters),
    queryFn: () => instancesApi.list(params),
  })
}

export function useInstance(id: string) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.detail(id),
    queryFn: () => instancesApi.get(id),
    enabled: !!id,
  })
}

export function useInstanceEvents(id: string, filters?: EventFilters) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useQuery({
    queryKey: instanceKeys.events(id, filters),
    queryFn: () => instancesApi.events(id, filters),
    enabled: !!id,
  })
}

export function useInstanceTimeline(
  id: string,
  params?: { cursor?: string; page_size?: number },
  enabled = true,
) {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const cursor = params?.cursor ?? null
  const pageSize = params?.page_size ?? 50

  return useQuery({
    queryKey: instanceKeys.timeline(id, cursor, pageSize),
    queryFn: () => instancesApi.timeline(id, params),
    enabled: !!id && enabled,
  })
}

/** T-1520: page size and page cap of the full-timeline read (200 is the server maximum; 25 pages = 5000 events). */
export const TIMELINE_ALL_PAGE_SIZE = 200
export const MAX_TIMELINE_PAGES = 25

export interface InstanceTimelineAll {
  /** De-duplicated by `event_id`, ascending `sequence_num`. */
  entries: TimelineEntry[]
  /** False while pages are missing: a failed page, the page cap, or still loading. */
  complete: boolean
  truncated: boolean
  isError: boolean
  retry: () => void
}

/** T-1520: every timeline page of an instance, for the diagram's path evidence. Pages are fetched one after the
 *  other until `next_cursor` is null (capped at MAX_TIMELINE_PAGES). While the instance is ACTIVE the stored pages
 *  are re-read every 2 s (5 s beyond 3 pages): the cursor is opaque and the last page has no cursor, so a refetch of
 *  all pages is how new events arrive. When the instance leaves ACTIVE one final refetch runs, then polling stops. */
export function useInstanceTimelineAll(id: string, opts: { status?: InstanceStatus | string; pageSize?: number } = {}): InstanceTimelineAll {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const pageSize = opts.pageSize ?? TIMELINE_ALL_PAGE_SIZE
  const live = opts.status === 'ACTIVE'
  const q = useInfiniteQuery({
    queryKey: instanceKeys.timelineAll(id),
    queryFn: ({ pageParam }) =>
      instancesApi.timeline(id, { page_size: pageSize, ...(pageParam ? { cursor: pageParam } : {}) }) as Promise<TimelinePage>,
    initialPageParam: null as string | null,
    getNextPageParam: (last: TimelinePage, all: TimelinePage[]) =>
      all.length >= MAX_TIMELINE_PAGES ? undefined : last?.next_cursor ?? undefined,
    enabled: !!id,
    retry: false,
    refetchInterval: (query) => (live ? ((query.state.data?.pages.length ?? 0) > 3 ? 5000 : 2000) : false),
  })
  const { hasNextPage, isFetchingNextPage, fetchNextPage, isError, refetch } = q
  useEffect(() => {
    if (hasNextPage && !isFetchingNextPage && !isError) void fetchNextPage()
  }, [hasNextPage, isFetchingNextPage, isError, fetchNextPage])

  // One final refetch when the instance leaves ACTIVE, so the last events are not missed.
  const prevStatus = useRef(opts.status)
  useEffect(() => {
    if (prevStatus.current === 'ACTIVE' && opts.status !== undefined && opts.status !== 'ACTIVE') void refetch()
    prevStatus.current = opts.status
  }, [opts.status, refetch])

  const pages = q.data?.pages
  const lastCursor = pages && pages.length > 0 ? pages[pages.length - 1]?.next_cursor ?? null : null
  const truncated = !!pages && pages.length >= MAX_TIMELINE_PAGES && lastCursor !== null
  const entries = useMemo(() => {
    const seen = new Set<string>()
    const out: TimelineEntry[] = []
    for (const p of pages ?? []) {
      for (const e of p?.items ?? []) {
        if (seen.has(e.event_id)) continue
        seen.add(e.event_id)
        out.push(e)
      }
    }
    return out.sort((a, b) => a.sequence_num - b.sequence_num)
  }, [pages])
  return {
    entries,
    complete: !!pages && !isError && lastCursor === null,
    truncated,
    isError,
    retry: () => {
      if (hasNextPage) void fetchNextPage()
      else void refetch()
    },
  }
}

export interface InstanceNodeEntries {
  /** De-duplicated by `event_id`, ascending `sequence_number`. */
  entries: NodeEnteredItem[]
  /** False while pages are missing: a failed page, the page cap, or still loading. */
  complete: boolean
  truncated: boolean
  isLoading: boolean
  isError: boolean
  retry: () => void
}

/** T-1635: every NODE_ENTERED page of an instance (REQ-793), for the replay screen. Same paging, cap and polling as
 *  `useInstanceTimelineAll`: pages are followed until `next_cursor` is null (capped at MAX_TIMELINE_PAGES); while the
 *  instance is ACTIVE the stored pages are re-read every 2 s (5 s beyond 3 pages); one final refetch when it leaves ACTIVE. */
export function useInstanceNodeEntries(id: string, opts: { status?: InstanceStatus | string; pageSize?: number } = {}): InstanceNodeEntries {
  const instanceKeys = useTenantScopedQueryKeys().instances
  const pageSize = opts.pageSize ?? TIMELINE_ALL_PAGE_SIZE
  const live = opts.status === 'ACTIVE'
  const q = useInfiniteQuery({
    queryKey: instanceKeys.nodeEntries(id),
    queryFn: ({ pageParam }) =>
      instancesApi.nodeEntries(id, { page_size: pageSize, ...(pageParam ? { cursor: pageParam } : {}) }),
    initialPageParam: null as string | null,
    getNextPageParam: (last: NodeEntriesPage, all: NodeEntriesPage[]) =>
      all.length >= MAX_TIMELINE_PAGES ? undefined : last?.next_cursor ?? undefined,
    enabled: !!id,
    retry: false,
    refetchInterval: (query) => (live ? ((query.state.data?.pages.length ?? 0) > 3 ? 5000 : 2000) : false),
  })
  const { hasNextPage, isFetchingNextPage, fetchNextPage, isError, refetch } = q
  // The page count is a dependency too: a page that answers at once can batch isFetchingNextPage true→false into
  // one render, and without it the effect would not run again after the second page.
  const pageCount = q.data?.pages.length ?? 0
  useEffect(() => {
    if (hasNextPage && !isFetchingNextPage && !isError) void fetchNextPage()
  }, [hasNextPage, isFetchingNextPage, isError, fetchNextPage, pageCount])

  const prevStatus = useRef(opts.status)
  useEffect(() => {
    if (prevStatus.current === 'ACTIVE' && opts.status !== undefined && opts.status !== 'ACTIVE') void refetch()
    prevStatus.current = opts.status
  }, [opts.status, refetch])

  const pages = q.data?.pages
  const lastCursor = pages && pages.length > 0 ? pages[pages.length - 1]?.next_cursor ?? null : null
  const truncated = !!pages && pages.length >= MAX_TIMELINE_PAGES && lastCursor !== null
  const entries = useMemo(() => {
    const seen = new Set<string>()
    const out: NodeEnteredItem[] = []
    for (const p of pages ?? []) {
      for (const e of p?.items ?? []) {
        if (seen.has(e.event_id)) continue
        seen.add(e.event_id)
        out.push(e)
      }
    }
    return out.sort((a, b) => a.sequence_number - b.sequence_number)
  }, [pages])
  return {
    entries,
    complete: !!pages && !isError && lastCursor === null,
    truncated,
    isLoading: q.isLoading,
    isError,
    retry: () => {
      if (hasNextPage) void fetchNextPage()
      else void refetch()
    },
  }
}

export function useStartInstance() {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useMutation({
    mutationFn: (body: StartInstanceRequest) => instancesApi.start(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: instanceKeys.all() }),
  })
}

export function useCancelInstance() {
  const qc = useQueryClient()
  const instanceKeys = useTenantScopedQueryKeys().instances
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason?: string }) =>
      instancesApi.cancel(id, reason),
    onMutate: async ({ id }) => {
      await qc.cancelQueries({ queryKey: instanceKeys.detail(id) })
      const previous = qc.getQueryData(instanceKeys.detail(id))
      qc.setQueryData(instanceKeys.detail(id), (old: unknown) =>
        old ? { ...(old as object), status: 'CANCELLED' } : old,
      )
      return { previous }
    },
    onError: (_err, { id }, ctx) => {
      qc.setQueryData(instanceKeys.detail(id), ctx?.previous)
    },
    onSettled: (_data, _err, { id }) => {
      qc.invalidateQueries({ queryKey: instanceKeys.detail(id) })
      qc.invalidateQueries({ queryKey: instanceKeys.all() })
    },
  })
}
