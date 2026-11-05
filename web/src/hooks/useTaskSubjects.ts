/** useTaskSubjects — T-1378. What a task is about, as text ("RC-2026-0007 - Receipt"), never an instance id. The task list
 *  item carries only ids, so the subject is read from the instance's process variables (`document_id`, `document_type`,
 *  `count_order_id`) and the document's number. One cached fetch per instance; a failure shows "Unknown record". */
import { useQueries } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import { client } from '@/api/client'
import { useAuth } from '@/auth/AuthContext'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { referenceQueryKeys } from '@/lib/references/referenceQueryKeys'
import { isUuid } from '@/lib/references/referenceLabel'

// The core inbox cannot import a module (lint rule), so the two stock reads go through the client by route.
const STOCK_DOCUMENTS = '/api/v1/modules/stock/documents'
const STOCK_COUNTS = '/api/v1/modules/stock/counts'

/** The inbox shows at most this many rows; the lookups follow it. */
const CAP = 50

function str(v: unknown): string {
  return typeof v === 'string' ? v : ''
}

async function subjectOf(instanceId: string): Promise<{ number: string; type: string } | null> {
  const inst = await instancesApi.get(instanceId)
  const vars = (inst?.variables ?? {}) as Record<string, unknown>
  const type = str(vars['document_type'])
  const docId = str(vars['document_id'])
  const orderId = str(vars['count_order_id'])
  let number = ''
  if (orderId !== '') number = str((await client.get<{ number?: string | null }>(`${STOCK_COUNTS}/${encodeURIComponent(orderId)}`))?.number)
  else if (type.startsWith('stock_') && docId !== '') number = str((await client.get<{ number?: string | null }>(`${STOCK_DOCUMENTS}/${encodeURIComponent(docId)}`))?.number)
  if (type === '' && number === '') return null
  return { number, type: orderId !== '' && type === '' ? 'count' : type }
}

export function useTaskSubjects(instanceIds: string[]): (instanceId: string) => string {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const msg = REFERENCE_MESSAGES[useUiLocale()]
  const ids = [...new Set(instanceIds)].slice(0, CAP)
  const results = useQueries({
    queries: ids.map((id) => ({
      queryKey: referenceQueryKeys.taskSubject(tenantId, id),
      queryFn: async () => (await subjectOf(id)) ?? { number: '', type: '' },
      retry: false,
    })),
  })
  const byId = new Map(ids.map((id, i) => [id, results[i]]))
  return (instanceId) => {
    const r = byId.get(instanceId)
    if (!r || r.isPending) return msg.loading
    const s = r.data
    if (!s) return msg.unknown
    const word = msg.docType[s.type] ?? (s.type !== '' && !isUuid(s.type) ? s.type : '')
    const text = [s.number, word].filter((x) => x !== '').join(' - ')
    return text === '' ? msg.unknown : text
  }
}
