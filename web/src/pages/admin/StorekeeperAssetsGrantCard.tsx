/** T-1570 (D-097) — Users and groups: the tenant administrator switches the storekeeper's asset access on or off.
 *  Two checkboxes (read, post); the save sends the FULL list (the PUT replaces it). Mounted only for
 *  `UsersGroupsRolesManage`; the server decides again. States: loading, load error (retry), not installed,
 *  default, saving, save error, saved. */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { roleGrantsApi, type StorekeeperAssetGrant } from '@/api/roleGrants'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { storekeeperGrantMessages } from './storekeeperGrantMessages'

const ORDER: StorekeeperAssetGrant[] = ['AssetsRead', 'AssetsPost']

export default function StorekeeperAssetsGrantCard() {
  const m = storekeeperGrantMessages[useUiLocale()]
  const qc = useQueryClient()
  const key = useTenantScopedQueryKeys().admin.roleGrants()
  const [draft, setDraft] = useState<StorekeeperAssetGrant[] | null>(null)
  const [saved, setSaved] = useState(false)

  const query = useQuery({ queryKey: key, queryFn: () => roleGrantsApi.get() })
  const stored = query.data?.storekeeper
  const current = draft ?? (Array.isArray(stored) ? stored : [])

  const save = useMutation({
    mutationFn: (list: StorekeeperAssetGrant[]) => roleGrantsApi.putStorekeeper(list),
    onSuccess: () => {
      setDraft(null)
      setSaved(true)
      void qc.invalidateQueries({ queryKey: key })
    },
  })

  const toggle = (grant: StorekeeperAssetGrant, on: boolean) => {
    setSaved(false)
    const next = ORDER.filter((g) => (g === grant ? on : current.includes(g)))
    setDraft(next)
  }

  const notInstalled = query.isError && (query.error as { status?: number } | null)?.status === 404

  return (
    <section className="lf-card" aria-labelledby="storekeeper-grant-title" data-testid="storekeeper-grant-card">
      <h3 id="storekeeper-grant-title">{m.title}</h3>
      <p>{m.lede}</p>
      {query.isLoading && <p role="status">{m.loading}</p>}
      {notInstalled && <Banner tone="info">{m.notInstalled}</Banner>}
      {query.isError && !notInstalled && (
        <Banner
          tone="danger"
          action={<Button variant="secondary" size="sm" onClick={() => void query.refetch()}>{m.retry}</Button>}
        >
          {m.loadError}
        </Banner>
      )}
      {query.isSuccess && (
        <div>
          <Checkbox
            data-testid="grant-read"
            label={m.read}
            checked={current.includes('AssetsRead')}
            onChange={(on) => toggle('AssetsRead', on)}
          />
          <Checkbox
            data-testid="grant-post"
            label={m.post}
            checked={current.includes('AssetsPost')}
            onChange={(on) => toggle('AssetsPost', on)}
          />
          {save.isError && <Banner tone="danger">{m.saveError}</Banner>}
          {saved && !save.isError && <Banner tone="success">{m.saved}</Banner>}
          <Button
            variant="primary"
            size="md"
            loading={save.isPending}
            disabled={draft === null}
            onClick={() => save.mutate(current)}
          >
            {m.save}
          </Button>
        </div>
      )}
    </section>
  )
}
