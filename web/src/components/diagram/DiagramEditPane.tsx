/** DiagramEditPane — T-1563. "Edit diagram" of the definition page: seeds the draft from the stored definition, runs the
 *  live check with the server's validator, and saves through the EXISTING routes only: PATCH /definitions/:id (body
 *  `{graph}`) for a DRAFT, POST /definitions (next version, `copy_variable_schemas_from`) for any other status.
 *  Save is off while a blocking violation is present (create/update would answer 422). Updates are last-write-wins on the
 *  server; before saving, `updated_at` is compared with the value seen at the start and a mismatch asks first (best effort). */
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Skeleton } from '@/components/ui/Skeleton'
import { definitionsApi } from '@/api/definitions'
import { useDiagramDraft, type DiagramDraft } from '@/hooks/useDiagramDraft'
import { isBlocking, useValidateDraft, type DraftCheck } from '@/hooks/useValidateDraft'
import type { GraphValidationViolation } from '@/api/definitions'
import type { DeclaredVariable, DefinitionGraph, ProcessDefinition } from '@/types/api'
import { DESIGNER_ERROR_PREFIX, designerErrorKey } from '@/i18n/designerErrorMessages'
import { addVariable, sameVariables } from '@/utils/canvas/declaredVariables'
import { DeclaredVariablesContext, type DeclaredVariables } from './DeclaredVariablesContext'
import { VariablesPanel } from './VariablesPanel'
import { nextDraftVersion, withLayoutPositions } from '@/utils/canvas/graphEdit'

const DiagramEditor = lazy(() => import('./DiagramEditor'))
type Sel = import('./DiagramEditor').Sel

type SaveError = null | { kind: 'not_draft' | 'module' | 'duplicate' | 'other'; message: string; code?: string; status?: number }

export interface DiagramEditPaneProps {
  def: ProcessDefinition
  /** The Editor has unsaved changes: the diagram draft must not diverge from them. */
  editorDirty: boolean
  /** This pane was opened by the save of a version copy: show the "Saved." confirmation at once. */
  justSaved?: boolean
  onDirtyChange: (dirty: boolean) => void
  /** After a successful save. `id` is the id of the saved draft (a new id when a version copy was made). */
  onSaved: (saved: ProcessDefinition, copied: boolean) => void
  /** Refetch the definition (after a not_draft conflict or a stale warning). */
  onReload: () => void
  /** The number of open problems of the SAVED draft (0 while the draft has unsaved edits or no check has finished): the page disables Publish on it. */
  onProblemsChange?: (count: number) => void
  /** Screen harness only: a fixed starting state (selection, problems, a banner) for the screenshots. */
  demo?: { selected?: Sel; violations?: GraphValidationViolation[]; error?: NonNullable<SaveError>; saved?: boolean; stale?: boolean; versionTaken?: boolean; loading?: boolean }
  /** The tenant the platform function catalogue read is scoped to (T-2599); the page resolves it. */
  tenantId?: string | null
}

function classify(err: unknown): NonNullable<SaveError> {
  const x = err as { status?: number; message?: string; code?: string }
  const message = x?.message ?? ''
  if (x?.status === 409) {
    if (/DRAFT/.test(message)) return { kind: 'not_draft', message, code: 'http_409', status: 409 }
    if (/module-owned/.test(message)) return { kind: 'module', message, code: 'conflict_module_owned', status: 409 }
    if (/already exists/.test(message)) return { kind: 'duplicate', message, code: 'conflict_duplicate', status: 409 }
  }
  return { kind: 'other', message, code: x?.code, status: x?.status }
}

export function DiagramEditPane({ def, editorDirty, justSaved, onDirtyChange, onSaved, onReload, onProblemsChange, demo, tenantId = null }: DiagramEditPaneProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.edit.${id}` }, values)
  const friendly = (x: { code?: string; status?: number }) => intl.formatMessage({ id: DESIGNER_ERROR_PREFIX + designerErrorKey(x.code, x.status) })
  const seed = useMemo<DefinitionGraph>(() => withLayoutPositions(def.graph), [def.graph])
  const rawDraft = useDiagramDraft(seed, def.updated_at)
  const { reset } = rawDraft
  // T-2811 (D1): the declared variables of the process. `savedVariables` is what the server holds (the clean base);
  // `variables` adds what was declared on this screen. Undefined from the server = unknown: nothing is sent unless added.
  const storedVariables = def.variable_schemas
  const [savedVariables, setSavedVariables] = useState<DeclaredVariable[]>(storedVariables ?? [])
  const [variables, setVariables] = useState<DeclaredVariable[]>(storedVariables ?? [])
  const variablesKnown = storedVariables !== undefined
  const variablesDirty = !sameVariables(variables, savedVariables)
  const variablesRef = useRef(variables)
  variablesRef.current = variables
  const declared = useMemo<DeclaredVariables>(
    () => ({
      variables,
      add: (name, type) => {
        const r = addVariable(variablesRef.current, name, type)
        if (!r.ok) return r.reason
        variablesRef.current = r.list
        setVariables(r.list)
        return null
      },
    }),
    [variables],
  )
  const savedKeys = useMemo(() => new Set(savedVariables.map((v) => v.variable_key)), [savedVariables])
  const [saving, setSaving] = useState(false)
  // Editing is frozen for the WHOLE save (the preliminary read included): a success replaces the draft with the saved graph,
  // so an edit made meanwhile would be lost silently. The ref is set synchronously, before React re-renders.
  const savingRef = useRef(false)
  const startSaving = () => {
    savingRef.current = true
    setSaving(true)
  }
  const stopSaving = () => {
    savingRef.current = false
    setSaving(false)
  }
  const draft = useMemo<DiagramDraft>(
    () => ({
      ...rawDraft,
      dirty: rawDraft.dirty || variablesDirty,
      apply: (result, key) => (savingRef.current ? 'saving' : rawDraft.apply(result, key)),
      setGraph: (g, key) => {
        if (!savingRef.current) rawDraft.setGraph(g, key)
      },
      undo: () => {
        if (!savingRef.current) rawDraft.undo()
      },
      redo: () => {
        if (!savingRef.current) rawDraft.redo()
      },
    }),
    [rawDraft, variablesDirty],
  )
  const isDraftDef = def.status === 'DRAFT'
  const [error, setError] = useState<SaveError>(demo?.error ?? null)
  const [stale, setStale] = useState(demo?.stale === true)
  const [confirmDiscard, setConfirmDiscard] = useState(false)
  const [savedTick, setSavedTick] = useState(demo?.saved === true || justSaved === true)
  const [version, setVersion] = useState(() => nextDraftVersion(def.version))
  const [versionTaken, setVersionTaken] = useState(demo?.versionTaken === true)
  // Violations a failed save returned for the graph that was sent (kept until that graph changes).
  const [saveProblems, setSaveProblems] = useState<{ graph: DefinitionGraph; violations: GraphValidationViolation[] } | null>(null)

  useEffect(() => onDirtyChange(draft.dirty), [draft.dirty, onDirtyChange])
  // A reloaded definition (clean) brings its stored variables along.
  useEffect(() => {
    if (!dirtyRef.current) {
      setSavedVariables(storedVariables ?? [])
      setVariables(storedVariables ?? [])
    }
  }, [storedVariables, def.updated_at])
  // Leaving the pane (unmount) never leaves a stale lock behind.
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  // The definition was reloaded (after a save, a refetch, or "Reload"). A clean draft follows what is stored; a draft with
  // unsaved edits is NEVER replaced silently: it stays, and the stale warning offers Save anyway / Discard and reload.
  const dirtyRef = useRef(draft.dirty)
  dirtyRef.current = draft.dirty
  const firstSeed = useRef(true)
  useEffect(() => {
    if (firstSeed.current) {
      firstSeed.current = false
      return
    }
    if (dirtyRef.current) setStale(true)
    else reset(seed, def.updated_at)
  }, [seed, def.updated_at, reset])

  const live = useValidateDraft(def.id, draft.graph, !editorDirty && !demo?.violations, undefined, variablesKnown || variables.length > 0 ? variables : undefined)
  const demoViolations = demo?.violations
  const liveCheck = live.check
  const check: DraftCheck = useMemo(
    () => (demoViolations ? { phase: 'invalid', violations: demoViolations } : liveCheck),
    [demoViolations, liveCheck],
  )
  // Memoised: a fresh array on every render made the editor's node list new every render, and React Flow's store
  // answered each one with a state update: maximum update depth (React error 185, T-2738).
  const violations = useMemo(() => {
    const checked = check.phase === 'invalid' ? check.violations : []
    const fromSave = saveProblems && saveProblems.graph === draft.graph ? saveProblems.violations : []
    const all = [...checked, ...fromSave.filter((v) => !checked.some((c) => c.code === v.code && c.message === v.message))]
    // T-2811 (D1): the undeclared-variable error names the way out in words (the original text stays first, so the
    // node anchor still finds its step). Any other known server code is shown as its plain sentence; an unknown one
    // keeps the server's own text.
    return all.map((v) =>
      v.code === 'step_mapping_variable_undeclared'
        ? { ...v, message: `${v.message}. ${intl.formatMessage({ id: 'processDiagram.edit.vars.undeclaredFix' })}` }
        : designerErrorKey(v.code) === 'fallback'
          ? v
          : { ...v, message: friendly(v) },
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [check, saveProblems, draft.graph, intl])
  const blocking = violations.filter(isBlocking)
  // The saved draft's open problems (all of them: activation refuses what the live check only warns about). Counted for any
  // clean server-backed draft, also one opened without saving in this mount; savedTick only controls the banner.
  const savedProblems = isDraftDef && !editorDirty && !draft.dirty && !error ? violations.length : 0
  useEffect(() => onProblemsChange?.(savedProblems), [savedProblems, onProblemsChange])
  useEffect(() => () => onProblemsChange?.(0), [onProblemsChange])

  const blockedReason =
    editorDirty
      ? e('lock.editorDirty')
      : error?.kind === 'module'
        ? e('save.moduleOwned')
        : blocking.length > 0 && savedProblems === 0
          ? e('save.blocked', { count: blocking.length })
          : null

  const doSave = useCallback(async () => {
    startSaving()
    setError(null)
    setStale(false)
    setSaveProblems(null)
    const sent = draft.graph
    const sentVariables = variablesRef.current
    // The variable list is sent whole (it replaces the stored one) when the server told us the stored list or the user added
    // one; otherwise the old behaviour stands (a version copy keeps the declared variables of the source).
    const sendVariables = variablesKnown || sentVariables.length > 0
    try {
      let saved: ProcessDefinition
      if (isDraftDef) {
        saved = await definitionsApi.update(def.id, sendVariables ? { graph: draft.graph, variable_schemas: sentVariables } : { graph: draft.graph })
      } else {
        saved = await definitionsApi.create({
          name: def.name,
          version,
          description: def.description,
          graph: draft.graph,
          ...(sendVariables ? { variable_schemas: sentVariables } : { copy_variable_schemas_from: def.id }),
        })
      }
      setSavedVariables(sentVariables)
      // The server acknowledged the save: only now does the draft become the clean base.
      draft.reset(withLayoutPositions(saved.graph), saved.updated_at)
      setSavedTick(true)
      onSaved(saved, !isDraftDef)
    } catch (err) {
      const c = classify(err)
      const x = err as { status?: number; details?: unknown }
      if (x?.status === 422 && Array.isArray(x.details)) {
        setSaveProblems({ graph: sent, violations: (x.details as GraphValidationViolation[]).filter((v) => v && typeof v.code === 'string') })
      }
      if (c.kind === 'duplicate') setVersionTaken(true)
      setError(c)
    } finally {
      stopSaving()
    }
  }, [isDraftDef, def, draft, version, onSaved, variablesKnown])

  const save = useCallback(async () => {
    startSaving()
    if (isDraftDef) {
      // Best effort only: a window remains between this read and the PATCH (no server-side revision check exists).
      try {
        const fresh = await definitionsApi.get(def.id)
        if (draft.seededAt && fresh.updated_at !== draft.seededAt) {
          setStale(true)
          stopSaving()
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
            <Field label={e('versionLabel')} width="s">
              <input value={version} onChange={(ev) => setVersion(ev.target.value)} data-testid="edit-version-input" />
            </Field>
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
              <Button variant="ghost" size="sm" onClick={() => setConfirmDiscard(true)} data-testid="edit-stale-reload">{e('stale.reload')}</Button>
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
          <span data-testid={`edit-error-${error.kind}`}>{error.kind === 'other' ? e('save.failed', { message: friendly(error) }) : friendly(error)}</span>
          {(error.code || error.message) && (
            <details className="lf-hint" data-testid="edit-error-details">
              <summary>{intl.formatMessage({ id: `${DESIGNER_ERROR_PREFIX}details` })}</summary>
              <small>{[error.status, error.code].filter(Boolean).join(' ')} {error.message}</small>
            </details>
          )}
        </Banner>
      )}
      {savedTick && !draft.dirty && !error && (
        savedProblems > 0 ? (
          <div data-testid="edit-saved-with-problems"><Banner tone="warning">{e('savedWithProblems', { count: savedProblems })}</Banner></div>
        ) : (
          <div data-testid="edit-saved"><Banner tone="success">{e('saved')}</Banner></div>
        )
      )}
      {demo?.loading ? (
        <Skeleton />
      ) : (
      <DeclaredVariablesContext.Provider value={declared}>
      <VariablesPanel graph={draft.graph} savedKeys={savedKeys} />
      <Suspense fallback={<Skeleton />}>
        <DiagramEditor
          draft={draft}
          violations={violations}
          check={check}
          initialSelected={demo?.selected}
          tenantId={tenantId}
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
      </DeclaredVariablesContext.Provider>
      )}
      <ConfirmDialog
        open={confirmDiscard}
        title={e('discard')}
        body={e('discardConfirm')}
        confirmText={e('discard')}
        cancelText={e('panel.close')}
        confirmVariant="danger"
        onConfirm={() => {
          draft.reset(seed, def.updated_at)
          setVariables(savedVariables)
          setError(null)
          setStale(false)
          setSaveProblems(null)
          setConfirmDiscard(false)
          onReload()
        }}
        onCancel={() => setConfirmDiscard(false)}
      />
    </div>
  )
}
