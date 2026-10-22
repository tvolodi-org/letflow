/** EntityCrudPage — REQ-343
 *
 *  Generic list/create/edit/delete screen for ONE entity_type, parameterized
 *  by the `entityType` prop rather than hand-copied per BilimBaga entity
 *  type. This is REQ-336's `TagListPage.tsx` pilot generalized: identical
 *  data flow (POST /entities/query for list, GET
 *  /entities/definitions/active/:name for field metadata,
 *  POST/PUT/DELETE /entities/records/:entity_type for writes; cursor
 *  pagination via `PaginationControls`), with the pilot's hard-coded
 *  `ENTITY_TYPE = 'tag'` and its one hard-coded `name` column replaced by:
 *
 *   - `entityType` — supplied by the caller (BilimBagaEntityRoute reads it
 *     from the URL's `:entityType` segment against
 *     `web/src/config/bilimbagaEntities.ts`'s known list).
 *   - list columns — generated from the fetched EntityDefinition's own
 *     `fields`, in declaration order, rather than a hand-written column
 *     array. A `:localized_text` value renders its own-locale (falling back
 *     to any populated locale) string; every other type renders via
 *     `String(value)`, `Boolean` as Yes/No, matching this catalog's
 *     `entities.crud.*` ids.
 *   - field titles — one shared label per field NAME
 *     (`entities.field.<name>`, in `web/src/i18n/entitiesMessages.ts`),
 *     not per entity type, since the same field name means the same thing
 *     across every BilimBaga entity that carries it.
 *
 *  IS_CORRECT FIELD-GRANT NOTE (REQ-343 gap note 1). `answer_option`'s
 *  `is_correct` field renders and is editable through this SAME generic
 *  path, with no special-casing — this screen is the authoring surface a
 *  question-bank editor uses to set the answer key, not the candidate-facing
 *  exam UI. Letflow.Entities.Query.FieldGrants' redaction (REQ-231) is a
 *  candidate-facing concern (REQ-338's exam-session reads); it does not
 *  apply here, and "admin CRUD shows is_correct" is correct behaviour, not a
 *  redaction bug. See this requirement's close-out for the same statement.
 */

import { useMemo, useRef, useState } from 'react'
import { P, useAccess } from '@/auth/access'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl, type IntlShape } from 'react-intl'
import { entitiesApi } from '@/api/entities'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiError, EntityFieldDef, EntityQueryFilterClause, EntityRecord } from '@/types/api'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { deferClickState } from '@/utils/deferClickState'
import { EntityRecordForm } from '@/components/entities/EntityRecordForm'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'
import { entitiesMessages, resolveUiLocale } from '@/i18n/entitiesMessages'

const PAGE_SIZE = 25

/** ISS-0663: the default list view must exclude soft-deleted records --
 *  `POST /entities/query` injects no implicit `deleted:false` predicate (by
 *  design, per `lib/letflow/entities/query/compiler.ex`'s own moduledoc), so
 *  every caller that wants "live records only" states it explicitly. This is
 *  a compile-time constant, not caller-configurable, matching this codebase's
 *  existing convention of each screen declaring the filters it needs (e.g.
 *  `ExamListPage.tsx`'s explicit `status: 'active'` filter). */
const EXCLUDE_DELETED_FILTERS: EntityQueryFilterClause[] = [{ field: 'deleted', op: 'eq', value: false }]

type ModalState = { kind: 'create' } | { kind: 'edit'; record: EntityRecord } | null

function isApiError(err: unknown): err is ApiError {
  return typeof err === 'object' && err !== null && 'status' in err
}

/** Renders one field's value for the list table. `:localized_text` values
 *  are `{locale: string}` objects (REQ-301) — shown in the viewer's own
 *  locale, falling back to the first populated locale. `:boolean` values
 *  render through this catalog's `entities.crud.boolean.yes`/`.no` ids, not
 *  a hard-coded English literal (REQ-343 gap note — see this file's
 *  header). Everything else is a scalar, stringified directly. */
function formatCellValue(field: EntityFieldDef, value: unknown, uiLocale: string, intl: IntlShape): string {
  if (value == null) return ''
  if (field.type === 'localized_text' && typeof value === 'object') {
    const byLocale = value as Record<string, unknown>
    const own = byLocale[uiLocale]
    if (typeof own === 'string' && own.length > 0) return own
    const firstPopulated = Object.values(byLocale).find((v) => typeof v === 'string' && v.length > 0)
    return typeof firstPopulated === 'string' ? firstPopulated : ''
  }
  if (field.type === 'boolean') {
    return intl.formatMessage({ id: value ? 'entities.crud.boolean.yes' : 'entities.crud.boolean.no' })
  }
  return String(value)
}

export interface EntityCrudPageProps {
  entityType: string
}

function EntityCrudPageInner({ entityType }: EntityCrudPageProps) {
  const intl = useIntl()
  const canWrite = useAccess().can(P.EntitiesRecordsWrite)
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const uiLocale = resolveUiLocale([intl.locale])

  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [modal, setModal] = useState<ModalState>(null)
  const [deleteTarget, setDeleteTarget] = useState<EntityRecord | null>(null)
  const [formError, setFormError] = useState<ApiError | null>(null)
  const [deleteError, setDeleteError] = useState<string | null>(null)
  // ISS-0662 follow-up (double-submit race): confirmDelete's deleteMutation.mutate()
  // call is deferred by one macrotask (deferClickState, see that helper's moduledoc)
  // to avoid the native-click-turn setState freeze. That widened the window between
  // "confirm clicked" and "mutate() actually called" to a full macrotask, in which a
  // second click/Enter on the still-enabled confirm button (isLoading only flips once
  // deleteMutation.isPending updates, which can't happen until the deferred call
  // fires) would schedule a second delete for the same record. A plain ref, set
  // synchronously in the same event turn as the click — not a setState — closes that
  // window without reintroducing the freeze, since the freeze was specifically about
  // React state updates during the native event-dispatch turn, not synchronous code
  // in general. Reset once the delete mutation settles (success or error), or when a
  // fresh delete confirmation is opened for a different record.
  const deleteInFlightRef = useRef(false)

  const cursor = cursorStack.length > 0 ? cursorStack[cursorStack.length - 1] : undefined

  const definitionQuery = useQuery({
    queryKey: tenantKeys.entities.definition(entityType),
    queryFn: () => entitiesApi.getActiveDefinition(entityType),
  })

  const recordsQuery = useQuery({
    queryKey: tenantKeys.entities.records(entityType, { cursor, page_size: PAGE_SIZE, filters: EXCLUDE_DELETED_FILTERS }),
    queryFn: () => entitiesApi.queryRecords(entityType, { cursor, page_size: PAGE_SIZE, filters: EXCLUDE_DELETED_FILTERS }),
  })

  const rows = useMemo(() => recordsQuery.data?.items ?? [], [recordsQuery.data])
  const definition = definitionQuery.data
  const fields = useMemo(() => definition?.definition.fields ?? [], [definition])

  const fieldTitles = useMemo(() => {
    const titles: Record<string, string> = {}
    for (const field of fields) {
      const messageId = `entities.field.${field.name}`
      titles[field.name] = Object.prototype.hasOwnProperty.call(entitiesMessages[uiLocale], messageId)
        ? intl.formatMessage({ id: messageId })
        : field.name
    }
    return titles
  }, [fields, intl, uiLocale])

  const invalidateList = () => {
    void qc.invalidateQueries({ queryKey: tenantKeys.entities.all() })
  }

  const createMutation = useMutation({
    mutationFn: (fieldValues: Record<string, unknown>) => entitiesApi.createRecord(entityType, fieldValues),
    onSuccess: () => {
      setModal(null)
      setFormError(null)
      invalidateList()
    },
    onError: (err: unknown) => {
      setFormError(isApiError(err) ? err : null)
    },
  })

  const updateMutation = useMutation({
    mutationFn: ({ recordId, fieldValues, ifMatch }: { recordId: string; fieldValues: Record<string, unknown>; ifMatch?: string }) =>
      entitiesApi.updateRecord(entityType, recordId, fieldValues, ifMatch),
    onSuccess: () => {
      setModal(null)
      setFormError(null)
      invalidateList()
    },
    onError: (err: unknown) => {
      setFormError(isApiError(err) ? err : null)
    },
  })

  const deleteMutation = useMutation({
    mutationFn: (recordId: string) => entitiesApi.deleteRecord(entityType, recordId),
    onSuccess: () => {
      deleteInFlightRef.current = false
      setDeleteTarget(null)
      setDeleteError(null)
      invalidateList()
    },
    onError: () => {
      deleteInFlightRef.current = false
      setDeleteError(intl.formatMessage({ id: 'entities.crud.delete.error' }))
    },
  })

  const goNext = () => {
    if (!recordsQuery.data?.next_cursor) return
    setCursorStack((prev) => [...prev, recordsQuery.data!.next_cursor as string])
  }
  const goPrev = () => setCursorStack((prev) => prev.slice(0, -1))
  const page = cursorStack.length + 1
  const hasNextPage = recordsQuery.data?.next_cursor != null

  const openCreate = () => {
    deferClickState(() => {
      setFormError(null)
      setModal({ kind: 'create' })
    })
  }
  const openEdit = (record: EntityRecord) => {
    deferClickState(() => {
      setFormError(null)
      setModal({ kind: 'edit', record })
    })
  }
  const closeModal = () => {
    deferClickState(() => {
      setModal(null)
      setFormError(null)
    })
  }
  const openDeleteConfirm = (record: EntityRecord) => {
    deleteInFlightRef.current = false
    deferClickState(() => {
      setDeleteTarget(record)
    })
  }

  const handleSubmit = (fieldValues: Record<string, unknown>) => {
    if (modal?.kind === 'create') {
      createMutation.mutate(fieldValues)
    } else if (modal?.kind === 'edit') {
      updateMutation.mutate({
        recordId: modal.record.record_id,
        fieldValues,
        ifMatch: modal.record.entity_def_version,
      })
    }
  }

  const confirmDelete = () => {
    if (!deleteTarget) return
    // Synchronous re-entrancy guard (not a setState) — see deleteInFlightRef's
    // declaration comment. Must run before scheduling the deferred mutate() call so
    // a second click/Enter within the same macrotask window no-ops instead of
    // scheduling a duplicate delete for the same record.
    if (deleteInFlightRef.current) return
    deleteInFlightRef.current = true
    const recordId = deleteTarget.record_id
    deferClickState(() => {
      deleteMutation.mutate(recordId)
    })
  }

  const columns: DataTableColumn<EntityRecord>[] = useMemo(() => {
    const fieldColumns: DataTableColumn<EntityRecord>[] = fields.map((field) => ({
      id: field.name,
      header: fieldTitles[field.name] ?? field.name,
      accessor: (row) => formatCellValue(field, row.field_values[field.name], intl.locale, intl),
      sortable: true,
      sortValue: (row) => formatCellValue(field, row.field_values[field.name], intl.locale, intl),
    }))
    return [
      ...fieldColumns,
      {
        id: 'actions',
        header: intl.formatMessage({ id: 'entities.crud.list.column.actions' }),
        accessor: (row) => (
          canWrite ? (
          <div style={{ display: 'flex', gap: '.4rem' }} onClick={(e) => e.stopPropagation()}>
            <Button
              variant="secondary"
              size="sm"
              data-testid={`entity-edit-${row.record_id}`}
              onClick={() => openEdit(row)}
            >
              {intl.formatMessage({ id: 'entities.crud.list.editAction' })}
            </Button>
            <Button
              variant="danger"
              size="sm"
              data-testid={`entity-delete-${row.record_id}`}
              onClick={() => openDeleteConfirm(row)}
            >
              {intl.formatMessage({ id: 'entities.crud.list.deleteAction' })}
            </Button>
          </div>
          ) : null
        ),
      },
    ]
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fields, fieldTitles, intl.locale, canWrite])

  return (
    <div data-testid="entity-crud-page" data-entity-type={entityType}>
      <PageLayout
        title={definition?.display_name ?? entityType}
        actions={
          canWrite ? (
            <Button variant="primary" size="md" data-testid="entity-create-action" onClick={openCreate}>
              {intl.formatMessage({ id: 'entities.crud.list.createAction' })}
            </Button>
          ) : undefined
        }
      >
        <QueryStateBoundary
          state={
            (recordsQuery.isLoading
              ? 'loading'
              : recordsQuery.isError
                ? classifyError(recordsQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void recordsQuery.refetch()
          }}
          columns={columns.map(() => ({ widthPercent: Math.floor(100 / Math.max(columns.length, 1)) }))}
        >
          {recordsQuery.isError && (
            <p style={{ color: 'var(--color-error-dark)' }}>
              {intl.formatMessage({ id: 'entities.crud.list.loadError' })}
            </p>
          )}

          <DataTable<EntityRecord>
            columns={columns}
            data={rows}
            emptyMessage={intl.formatMessage({ id: 'entities.crud.list.emptyMessage' })}
          />

          <div style={{ marginTop: '.85rem' }}>
            <PaginationControls
              page={page}
              pageSize={PAGE_SIZE}
              totalItems={null}
              hasNextPage={hasNextPage}
              onPageChange={(nextPage) => (nextPage > page ? goNext() : goPrev())}
            />
          </div>
        </QueryStateBoundary>

        {modal && definition && (
          <div
            data-testid="entity-form-modal"
            role="dialog"
            aria-modal="true"
            style={{
              position: 'fixed',
              inset: 0,
              background: 'var(--surface-overlay)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              zIndex: 40,
            }}
          >
            <div style={{ background: 'var(--surface-card)', borderRadius: '8px', padding: '1.5rem', width: '90vw', maxWidth: '560px', maxHeight: '85vh', overflowY: 'auto' }}>
              <h3 style={{ marginTop: 0 }}>
                {intl.formatMessage({ id: modal.kind === 'create' ? 'entities.crud.form.createTitle' : 'entities.crud.form.editTitle' })}
              </h3>
              <EntityRecordForm
                definition={definition}
                fieldTitles={fieldTitles}
                initialValues={modal.kind === 'edit' ? modal.record.field_values : undefined}
                onSubmit={(values) => handleSubmit(values)}
                onCancel={closeModal}
                isSubmitting={createMutation.isPending || updateMutation.isPending}
                apiError={formError}
                submitLabel={intl.formatMessage({
                  id: modal.kind === 'create' ? 'entities.crud.form.submitCreate' : 'entities.crud.form.submitUpdate',
                })}
                cancelLabel={intl.formatMessage({ id: 'entities.crud.form.cancel' })}
              />
            </div>
          </div>
        )}

        {deleteError && <p style={{ color: 'var(--color-error-dark)' }}>{deleteError}</p>}

        <ConfirmDialog
          open={deleteTarget != null}
          title={intl.formatMessage({ id: 'entities.crud.delete.confirmTitle' })}
          body={intl.formatMessage({ id: 'entities.crud.delete.confirmBody' })}
          confirmText={intl.formatMessage({ id: 'entities.crud.delete.confirmAction' })}
          cancelText={intl.formatMessage({ id: 'entities.crud.delete.cancelAction' })}
          confirmVariant="danger"
          isLoading={deleteMutation.isPending}
          onConfirm={confirmDelete}
          onCancel={() => deferClickState(() => setDeleteTarget(null))}
        />
      </PageLayout>
    </div>
  )
}

export function EntityCrudPage(props: EntityCrudPageProps) {
  return (
    <EntitiesIntlProvider>
      <EntityCrudPageInner {...props} />
    </EntitiesIntlProvider>
  )
}
