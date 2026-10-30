/** ModuleUninstallPage — REQ-630 (decision 0066 D8 slice 5): uninstall and reactivate a tenant module.
 *
 *  Two sections, each with its own mutation and message area. Uninstalled modules
 *  are not listed (no route lists them), so reactivation takes a typed module id.
 *  Error text comes from describeModuleTransitionError only; every 404 reads the same.
 */
import React, { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { useInstalledModules } from '@/hooks/useInstalledModules'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { tenantModulesApi, type TenantModuleTransitionResult } from '@/api/tenantModules'
import { describeModuleTransitionError, type ModuleTransitionError } from './moduleLifecycleErrors'

const th: React.CSSProperties = { textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }
const td: React.CSSProperties = { padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }

function ErrorView({ error }: { error: ModuleTransitionError }): React.ReactElement {
  if (error.kind === 'open_work') {
    return (
      <div role="alert">
        <p>This module still has running work and cannot be uninstalled.</p>
        <p>Open instances: {error.openInstances}</p>
        <p>Open tasks: {error.openTasks}</p>
        <p>Finish or cancel the work and try again.</p>
      </div>
    )
  }
  if (error.kind === 'dependents') {
    return (
      <div role="alert">
        <p>Other installed modules depend on this one:</p>
        <ul>
          {error.dependents.map((d) => (
            <li key={d}>{d}</li>
          ))}
        </ul>
      </div>
    )
  }
  return <div role="alert">{error.text}</div>
}

export default function ModuleUninstallPage(): React.ReactElement {
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const modulesQuery = useInstalledModules()
  const modules = modulesQuery.data ?? []

  const [rationale, setRationale] = useState('')
  const [pending, setPending] = useState<string | null>(null)
  const [uninstallError, setUninstallError] = useState<ModuleTransitionError | null>(null)
  const [uninstallDone, setUninstallDone] = useState<string | null>(null)

  const [reactivateId, setReactivateId] = useState('')
  const [reactivateRationale, setReactivateRationale] = useState('')
  const [reactivateError, setReactivateError] = useState<ModuleTransitionError | null>(null)
  const [reactivateDone, setReactivateDone] = useState<string | null>(null)

  const refreshModules = () => qc.invalidateQueries({ queryKey: tenantKeys.me.modules() })
  const doneText = (r: TenantModuleTransitionResult) => `Module ${r.module_id} is now ${r.status}.`

  const uninstallMutation = useMutation({
    mutationFn: (v: { id: string; rationale: string }) => tenantModulesApi.uninstall(v.id, v.rationale),
    onSuccess: (r) => {
      setUninstallError(null)
      setUninstallDone(doneText(r))
      setRationale('')
      void refreshModules()
    },
    onError: (err) => {
      setUninstallDone(null)
      setUninstallError(describeModuleTransitionError(err))
    },
    onSettled: () => setPending(null),
  })

  const reactivateMutation = useMutation({
    mutationFn: (v: { id: string; rationale: string }) => tenantModulesApi.reactivate(v.id, v.rationale),
    onSuccess: (r) => {
      setReactivateError(null)
      setReactivateDone(doneText(r))
      setReactivateId('')
      setReactivateRationale('')
      void refreshModules()
    },
    onError: (err) => {
      setReactivateDone(null)
      setReactivateError(describeModuleTransitionError(err))
    },
  })

  const rationaleBlank = rationale.trim() === ''
  const reactivateBlank = reactivateId.trim() === '' || reactivateRationale.trim() === ''

  const confirmUninstall = () => {
    if (pending === null || uninstallMutation.isPending) return
    setUninstallError(null)
    setUninstallDone(null)
    uninstallMutation.mutate({ id: pending, rationale: rationale.trim() })
  }

  const submitReactivate = () => {
    if (reactivateBlank || reactivateMutation.isPending) return
    setReactivateError(null)
    setReactivateDone(null)
    reactivateMutation.mutate({ id: reactivateId.trim(), rationale: reactivateRationale.trim() })
  }

  return (
    <PageLayout title="Module lifecycle">
      <div style={{ display: 'flex', flexDirection: 'column', gap: '2rem' }}>
        <section aria-labelledby="installed-modules-heading">
          <h2 id="installed-modules-heading">Installed modules</h2>
          <label style={{ display: 'block', marginBottom: '1rem' }}>
            Rationale (required)
            <br />
            <textarea
              data-testid="uninstall-rationale"
              value={rationale}
              onChange={(e) => setRationale(e.target.value)}
              rows={3}
              style={{ width: '100%' }}
            />
          </label>
          {modulesQuery.isLoading ? (
            <p>Loading installed modules…</p>
          ) : modules.length === 0 ? (
            <p>No installed modules.</p>
          ) : (
            <table data-testid="installed-modules-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
              <thead>
                <tr>
                  {['Module', 'Version', ''].map((h, i) => (
                    <th key={i} style={th}>
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {modules.map((m) => (
                  <tr key={m.module_id}>
                    <td style={td}>{m.module_id}</td>
                    <td style={td}>{m.version}</td>
                    <td style={td}>
                      <Button
                        variant="danger"
                        size="sm"
                        disabled={rationaleBlank || uninstallMutation.isPending}
                        onClick={() => setPending(m.module_id)}
                        data-testid={`uninstall-${m.module_id}`}
                      >
                        Uninstall
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {uninstallError && <ErrorView error={uninstallError} />}
          {uninstallDone && <div role="status">{uninstallDone}</div>}
        </section>

        <section aria-labelledby="reactivate-heading">
          <h2 id="reactivate-heading">Reactivate</h2>
          <p>Uninstalled modules are not listed. Type the module id to reactivate it.</p>
          <label style={{ display: 'block', marginBottom: '.5rem' }}>
            Module id{' '}
            <input data-testid="reactivate-module-id" value={reactivateId} onChange={(e) => setReactivateId(e.target.value)} />
          </label>
          <label style={{ display: 'block', marginBottom: '1rem' }}>
            Rationale (required)
            <br />
            <textarea
              data-testid="reactivate-rationale"
              value={reactivateRationale}
              onChange={(e) => setReactivateRationale(e.target.value)}
              rows={3}
              style={{ width: '100%' }}
            />
          </label>
          <Button
            variant="primary"
            size="md"
            disabled={reactivateBlank || reactivateMutation.isPending}
            onClick={submitReactivate}
            data-testid="reactivate-submit"
          >
            Reactivate
          </Button>
          {reactivateError && <ErrorView error={reactivateError} />}
          {reactivateDone && <div role="status">{reactivateDone}</div>}
        </section>
      </div>

      <ConfirmDialog
        open={pending !== null}
        title={`Uninstall ${pending ?? ''}?`}
        body="Running work blocks the uninstall. Data is kept, and you can reactivate the module later."
        confirmText="Uninstall"
        confirmVariant="danger"
        isLoading={uninstallMutation.isPending}
        onConfirm={confirmUninstall}
        onCancel={() => setPending(null)}
      />
    </PageLayout>
  )
}
