/** DiagramEditPane — T-1563. "Edit diagram" of the definition page: seeds the draft from the stored definition, runs the
 *  live check with the server's validator, and saves through the EXISTING routes only: PATCH /definitions/:id (body
 *  `{graph}`) for a DRAFT, POST /definitions (next version, `copy_variable_schemas_from`) for any other status.
 *  Save is off while a blocking violation is present (create/update would answer 422). Updates are last-write-wins on the
 *  server; before saving, `updated_at` is compared with the value seen at the start and a mismatch asks first (best effort). */
import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Skeleton } from '@/components/ui/Skeleton'
import { definitionsApi } from '@/api/definitions'
import { useDiagramDraft } from '@/hooks/useDiagramDraft'
import { isBlocking, useValidateDraft, type DraftCheck } from '@/hooks/useValidateDraft'
import type { GraphValidationViolation } from '@/api/definitions'
import type { DefinitionGraph, ProcessDefinition } from '@/types/api'
import { nextDraftVersion, withLayoutPositions } from '@/utils/canvas/graphEdit'

const DiagramEditor = lazy(() => import('./DiagramEditor'))
type Sel = import('./DiagramEditor').Sel

type SaveError = null | { kind: 'not_draft' | 'module' | 'duplicate' | 'other'; message: string }

export interface DiagramEditPaneProps {
  def: ProcessDefinition
  /** The Editor has unsaved changes: the diagram draft must not diverge from them. */
  editorDirty: boolean
  onDirtyChange: (dirty: boolean) => void
  /** After a successful save. `id` is the id of the saved draft (a new id when a version copy was made). */
  onSaved: (saved: ProcessDefinition, copied: boolean) => void
  /** Refetch the definition (after a not_draft conflict or a stale warning). */
  onReload: () => void
  /** Screen harness only: a fixed starting state (selection, problems, a banner) for the screenshots. */
  demo?: { selected?: Sel; violations?: GraphValidationViolation[]; error?: NonNullable<SaveError>; saved?: boolean }
}

function classify(err: unknown): NonNullable<SaveError> {
  const x = err as { status?: number; message?: string }
  const message = x?.message ?? ''
  if (x?.status === 409) {
    if (/DRAFT/.test(message)) return { kind: 'not_draft', message }
    if (/module-owned/.test(message)) return { kind: 'module', message }
    if (/already exists/.test(message)) return { kind: 'duplicate', message }
  }
  return { kind: 'other', message }
}

export function DiagramEditPane({ def, editorDirty, onDirtyChange, onSaved, onReload, demo }: DiagramEditPaneProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.edit.${id}` }, values)
  const seed = useMemo<DefinitionGraph>(() => withLayoutPositions(def.graph), [def.graph])
  const draft = useDiagramDraft(seed, def.updated_at)
  const { reset } = draft
  const isDraftDef = def.status === 'DRAFT'
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<SaveError>(demo?.error ?? null)
  const [stale, setStale] = useState(false)
  const [confirmDiscard, setConfirmDiscard] = useState(false)
  const [savedTick, setSavedTick] = useState(demo?.saved === true)
  const [version, setVersion] = useState(() => nextDraftVersion(def.version))
  const [versionTaken, setVersionTaken] = useState(false)

  useEffect(() => onDirtyChange(draft.dirty), [draft.dirty, onDirtyChange])
  // Leaving the pane (unmount) never leaves a stale lock behind.
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  // The definition was reloaded (after a save, or "Reload"): start again from what is stored.
  useEffect(() => {
    reset(seed, def.updated_at)
  }, [seed, def.updated_at, reset])

  const live = useValidateDraft(def.id, draft.graph, !editorDirty && !demo?.violations)
  const check: DraftCheck = demo?.violations ? { phase: 'invalid', violations: demo.violations } : live.check
  const violations = check.phase === 'invalid' ? check.violations : []
  const blocking = violations.filter(isBlocking)

  const blockedReason =
    editorDirty
      ? e('lock.editorDirty')
      : error?.kind === 'module'
        ? e('save.moduleOwned')
        : blocking.length > 0
          ? e('save.blocked', { count: blocking.length })
          : null

  const doSave = useCallback(async () => {
    setSaving(true)
    setError(null)
    setStale(false)
    try {
      let saved: ProcessDefinition
      if (isDraftDef) {
        saved = await definitionsApi.update(def.id, { graph: draft.graph })
      } else {
        saved = await definitionsApi.create({
          name: def.name,
          version,
          description: def.description,
          graph: draft.graph,
          copy_variable_schemas_from: def.id,
        })
      }
      setSavedTick(true)
      onSaved(saved, !isDraftDef)
    } catch (err) {
      const c = classify(err)
      if (c.kind === 'duplicate') setVersionTaken(true)
      setError(c)
    } finally {
      setSaving(false)
    }
  }, [isDraftDef, def, draft.graph, version, onSaved])

  const save = useCallback(async () => {
    if (isDraftDef) {
      // Best effort only: a window remains between this read and the PATCH (no server-side revision check exists).
      try {
        const fresh = await definitionsApi.get(def.id)
        if (draft.seededAt && fresh.updated_at !== draft.seededAt) {
          setStale(true)
          return
        }
      } catch {
        /* the save below reports its own failure */
      }
    }
    await doSave()
  }, [isDraftDef, def.id, draft.seededAt, doSave])

  return (
    <div className="lf-pd-edit__pane" data-testid="diagram-edit-pane">
      {editorDirty && <div data-testid="edit-lock-editor"><Banner tone="warning">{e('lock.editorDirty')}</Banner></div>}
      {!isDraftDef && (
        <div data-testid="edit-copy-note">
        <Banner tone="info">
          {e('copyNote', { status: def.status, version })}
          {versionTaken && (
            <label className="lf-pd-edit__version">
              {' '}
              {e('versionLabel')}{' '}
              <input value={version} onChange={(ev) => setVersion(ev.target.value)} data-testid="edit-version-input" />
            </label>
          )}
        </Banner>
        </div>
      )}
      {stale && (
        <Banner
          tone="warning"
          action={
            <>
              <Button variant="secondary" size="sm" onClick={() => void doSave()} data-testid="edit-stale-anyway">{e('stale.anyway')}</Button>
              <Button variant="ghost" size="sm" onClick={onReload} data-testid="edit-stale-reload">{e('stale.reload')}</Button>
            </>
          }
        >
          <span data-testid="edit-stale">{e('stale.text')}</span>
        </Banner>
      )}
      {error && (
        <Banner
          tone="danger"
          action={error.kind === 'not_draft' ? <Button variant="secondary" size="sm" onClick={onReload} data-testid="edit-error-reload">{e('stale.reload')}</Button> : undefined}
        >
          <span data-testid={`edit-error-${error.kind}`}>{error.kind === 'other' ? e('save.failed', { message: error.message }) : error.message}</span>
        </Banner>
      )}
      {savedTick && !draft.dirty && !error && <div data-testid="edit-saved"><Banner tone="success">{e('saved')}</Banner></div>}
      <Suspense fallback={<Skeleton />}>
        <DiagramEditor
          draft={draft}
          violations={violations}
          check={check}
          initialSelected={demo?.selected}
          toolbar={{
            onSave: () => void save(),
            onDiscard: () => {
              setConfirmDiscard(true)
            },
            saving,
            saveBlockedReason: blockedReason,
            saveLabel: isDraftDef ? e('saveDraft') : e('saveNewVersion', { version }),
          }}
        />
      </Suspense>
      <ConfirmDialog
        open={confirmDiscard}
        title={e('discard')}
        body={e('discardConfirm')}
        confirmText={e('discard')}
        cancelText={e('panel.close')}
        confirmVariant="danger"
        onConfirm={() => {
          draft.reset(seed, def.updated_at)
          setError(null)
          setConfirmDiscard(false)
        }}
        onCancel={() => setConfirmDiscard(false)}
      />
    </div>
  )
}
