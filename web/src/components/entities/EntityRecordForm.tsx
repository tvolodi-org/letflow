/** EntityRecordForm — REQ-336
 *
 *  Generic create/edit form for one entity-definition record, generated
 *  from the definition's own field list. Field rendering is NOT
 *  reimplemented here: each field is bridged to a `TaskFormField`
 *  (`entityFieldToFormField`) and handed to
 *  `FieldFactory.renderFormField` — the exact function `DynamicFormRenderer`
 *  uses to render a form_schema field — so a `:string` entity field renders
 *  through the identical widget component a form_schema `:string` field
 *  would (proven by `EntityRecordForm.fieldReuse.test.tsx`).
 *
 *  Server-side errors (422 field violations, a 409 optimistic-concurrency
 *  conflict) are surfaced as-is, never guessed client-side: `apiError`'s
 *  `details.errors` (the router's own `violation_map/1` shape,
 *  `[{code, path, message}]`) is mapped to a per-field message when
 *  `path[0]` matches a rendered field name, and to a form-level banner
 *  otherwise (including the 409 conflict case, which client.ts's
 *  `request()` already turns into an `ApiError` carrying
 *  `details.xResourceVersion` — PD-08's existing mechanism, not a new one).
 */

import { useMemo } from 'react'
import { useForm } from 'react-hook-form'
import { useIntl } from 'react-intl'
import type { ApiError } from '@/types/api'
import type { EntityDefinition } from '@/types/api'
import type { DynamicFormValue } from '@/types/forms'
import { entityFieldToFormField } from '@/utils/entityFieldToFormField'
import { renderFormField } from '@/components/forms/FieldFactory'
import { Button } from '@/components/ui/Button'
// REQ-342 — registers the entity-localized-text/entity-fk-reference widgets
// into the shared fieldRegistry as a side effect. Imported here (rather than
// only from main.tsx) because these two widgets are entity-definition-driven
// and only ever reached through EntityRecordForm's own rendering path.
import '@/components/entities/entityWidgetRegistry'

export interface EntityRecordFormProps {
  definition: EntityDefinition
  /** i18n field titles, keyed by field name — supplied by the composing
   *  page from its own message catalog (this component holds no strings
   *  of its own besides the two button labels, both passed in as props). */
  fieldTitles: Record<string, string>
  initialValues?: Record<string, unknown>
  /** The record being edited, if any (REQ-586 part D: the category tree
   *  picker hides it and its descendants). */
  editingRecordId?: string
  onSubmit: (fieldValues: Record<string, unknown>) => Promise<void> | void
  onCancel: () => void
  isSubmitting?: boolean
  apiError?: ApiError | null
  submitLabel: string
  cancelLabel: string
  formTestId?: string
}

interface ViolationEntry {
  code?: string
  path?: string[]
  message?: string
}

function fieldErrorsFromApiError(apiError: ApiError | null | undefined): Record<string, string> {
  if (!apiError) return {}
  const rawErrors = apiError.details?.errors
  if (!Array.isArray(rawErrors)) return {}

  const byField: Record<string, string> = {}
  for (const entry of rawErrors as ViolationEntry[]) {
    const fieldName = Array.isArray(entry.path) ? entry.path[0] : undefined
    if (fieldName && entry.message) {
      byField[fieldName] = entry.message
    }
  }
  return byField
}

/** Whether apiError has already been fully attributed to a field (so no
 *  redundant form-level banner is needed) — true only when every violation
 *  named a field this form actually rendered. */
function isFullyFieldAttributed(apiError: ApiError | null | undefined, knownFields: Set<string>): boolean {
  if (!apiError) return true
  const rawErrors = apiError.details?.errors
  if (!Array.isArray(rawErrors) || rawErrors.length === 0) return false
  return (rawErrors as ViolationEntry[]).every(
    (entry) => Array.isArray(entry.path) && entry.path.length > 0 && knownFields.has(entry.path[0]),
  )
}

export function EntityRecordForm(props: EntityRecordFormProps) {
  const {
    definition,
    fieldTitles,
    initialValues,
    editingRecordId,
    onSubmit,
    onCancel,
    isSubmitting = false,
    apiError,
    submitLabel,
    cancelLabel,
    formTestId = 'entity-record-form',
  } = props

  const intl = useIntl()
  const form = useForm<DynamicFormValue>({ defaultValues: initialValues as DynamicFormValue })

  const fields = definition.definition.fields
  const fieldErrors = useMemo(() => fieldErrorsFromApiError(apiError), [apiError])
  const knownFieldNames = useMemo(() => new Set(fields.map((f) => f.name)), [fields])
  const showGenericBanner = Boolean(apiError) && !isFullyFieldAttributed(apiError, knownFieldNames)

  const handleFormSubmit = form.handleSubmit(async (values) => {
    await onSubmit(values as Record<string, unknown>)
  })

  return (
    <form data-testid={formTestId} onSubmit={handleFormSubmit}>
      {showGenericBanner && apiError && (
        <div
          role="alert"
          data-testid={apiError.status === 409 ? 'entity-form-conflict-banner' : 'entity-form-error-banner'}
          style={{
            background: 'var(--color-error-light)',
            border: '1px solid var(--color-error-border)',
            borderRadius: '6px',
            padding: '.75rem',
            marginBottom: '1rem',
          }}
        >
          <p style={{ color: 'var(--color-error-dark)', margin: 0, fontSize: '.9rem' }}>
            {apiError.status === 409
              ? intl.formatMessage({ id: 'entities.tag.form.conflictError' })
              : apiError.message || intl.formatMessage({ id: 'entities.tag.form.submitError' })}
          </p>
          {/* PD-08: the same X-Resource-Version stamp client.ts's request()
             already captures on a 409 into details.xResourceVersion — read
             here for the conflict-state test to assert against, not
             re-derived by a new mechanism. */}
          {apiError.status === 409 && apiError.details?.xResourceVersion != null && (
            <p
              data-testid="entity-form-conflict-version"
              style={{ margin: '.35rem 0 0', fontSize: '.75rem', color: 'var(--text-secondary)' }}
            >
              {String(apiError.details.xResourceVersion)}
            </p>
          )}
        </div>
      )}

      {fields.map((field) => {
        const fkDef = definition.definition.foreign_keys?.find((fk) => fk.field === field.name)
        const taskFormField = {
          ...entityFieldToFormField(field, fkDef, { entityType: definition.name, editingRecordId }),
          title: fieldTitles[field.name] ?? field.name,
        }
        const registerReturn = form.register(field.name, { required: taskFormField.required })
        return (
          <div key={field.name}>
            {renderFormField(
              field.name,
              taskFormField,
              undefined,
              undefined,
              registerReturn,
              fieldErrors[field.name],
            )}
          </div>
        )
      })}

      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem', marginTop: '1rem' }}>
        <Button variant="secondary" size="md" onClick={onCancel} disabled={isSubmitting}>
          {cancelLabel}
        </Button>
        <Button
          variant="primary"
          size="md"
          loading={isSubmitting}
          disabled={isSubmitting}
          data-testid="entity-form-submit"
          onClick={() => {
            void handleFormSubmit()
          }}
        >
          {submitLabel}
        </Button>
      </div>
    </form>
  )
}
