/** Record codes share the Codes screen's invalidation prefix, including writes made from either screen. */
import { useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { useInstalledModules } from './useInstalledModules'
import { fetchPickPage, fetchRecordCodes, recordCodesApi, recordCodesKeys, reasonOf, type CodeKind, type CodeTarget } from '@/lib/codes/recordCodes.api'

export function useCodesAvailable() {
  const read = useAccess().can('CodesRead')
  const modules = useInstalledModules({ enabled: read })
  return read && !!modules.data?.some((m) => m.module_id === 'codes')
}
export function useRecordCodes(type: CodeTarget, id: string, enabled: boolean) {
  const tenant = useAuth().session?.tenant_id ?? ''
  return useQuery({ queryKey: recordCodesKeys.record(tenant, type, id), queryFn: () => fetchRecordCodes(type, id),
    enabled, retry: false, structuralSharing: false,
    placeholderData: (prev, query) => query?.queryKey[4] === id ? prev : undefined })
}
export function usePickableCodes(search: string, enabled: boolean) {
  const tenant = useAuth().session?.tenant_id ?? ''
  return useQuery({ queryKey: recordCodesKeys.pick(tenant, search), queryFn: () => fetchPickPage(search), enabled, retry: false })
}
type Command = { op: 'new'; value: string; kind: CodeKind } | { op: 'attach' | 'release'; codeId: string }
export function useRecordCodeWrite(type: CodeTarget, target: string) {
  const tenant = useAuth().session?.tenant_id ?? ''
  const client = useQueryClient()
  const attempt = useRef<{ fingerprint: string; key: string } | null>(null)
  const busy = useRef(false)
  const [isPending, setPending] = useState(false)
  const [error, setError] = useState<unknown>(null)
  async function submit(cmd: Command): Promise<'ok' | 'notFound' | 'error'> {
    if (busy.current) return 'error'
    busy.current = true
    setPending(true)
    setError(null)
    const fingerprint = JSON.stringify([type, target, cmd])
    const key = attempt.current?.fingerprint === fingerprint ? attempt.current.key : crypto.randomUUID()
    attempt.current = { fingerprint, key }
    try {
      if (cmd.op === 'new') {
        const received = await recordCodesApi.receive(cmd.value, cmd.kind, key)
        if (!Array.isArray(received) || typeof received[0]?.code_id !== 'string') throw new Error('Invalid receive response')
        await recordCodesApi.assign(received[0].code_id, type, target, `${key}-assign`)
      } else if (cmd.op === 'attach') await recordCodesApi.assign(cmd.codeId, type, target, key)
      else await recordCodesApi.release(cmd.codeId, key)
      attempt.current = null
      await client.invalidateQueries({ queryKey: recordCodesKeys.all(tenant) })
      return 'ok'
    } catch (err) {
      setError(err)
      // Receiving may already have succeeded. Refresh the free-code picker even on an assign failure.
      await client.invalidateQueries({ queryKey: recordCodesKeys.all(tenant) })
      if (reasonOf(err).status === 404) { attempt.current = null; return 'notFound' }
      return 'error'
    } finally { busy.current = false; setPending(false) }
  }
  return { submit, isPending, error, clearError: () => setError(null) }
}
