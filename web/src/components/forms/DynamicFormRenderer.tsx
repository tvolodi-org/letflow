/** Dynamic form renderer from JSON Schema (TK-UI-03) */

import { useEffect, useMemo, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import type { ApiError } from '@/types/api'
import type { DynamicFormValue, TaskFormField } from '@/types/forms'
import { parseFormSchema } from '@/utils/formSchemaParser'
import { compileFormSchemaToZod } from '@/utils/jsonSchemaToZod'
import type { ZodSchema } from 'zod'
import manifest from 'virtual:expr-manifest'
import { useFormExpressions } from './useFormExpressions'
import { ExpressionUnavailableBanner } from './ExpressionUnavailableBanner'
import { DateValueHint } from '@/components/ui/DateValueHint'

export interface DynamicFormRendererProps {
  formSchema: Record<string, unknown> | null
  onSubmit: (values: DynamicFormValue) => Promise<void>
  submitLabel?: string
  isSubmitting?: boolean
  submitError?: ApiError
  isRequired?: boolean
  requirementsContext?: {
    instanceId: string
    variables: Record<string, unknown>
  }
}

export function DynamicFormRenderer(props: DynamicFormRendererProps) {
  const {
    formSchema,
    onSubmit,
    submitLabel = 'Complete Task',
    isSubmitting = false,
    submitError,
  } = props

  const [parseError, setParseError] = useState<string | null>(null)
  const [validationSchema, setValidationSchema] = useState<ZodSchema | null>(null)
  const [formFields, setFormFields] = useState<Record<string, TaskFormField>>({})
  const [localSubmitting, setLocalSubmitting] = useState<boolean>(false)

  const form = useForm<DynamicFormValue>({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolver: validationSchema ? (zodResolver(validationSchema as any) as any) : undefined,
    mode: 'onChange',
  })

  // Parse and compile form schema on mount or change
  useEffect(() => {
    setParseError(null)
    try {
      if (!formSchema || typeof formSchema !== 'object') {
        setValidationSchema(null)
        setFormFields({})
        return
      }

      const parsed = parseFormSchema(formSchema)
      const compiled = compileFormSchemaToZod(parsed)
      setValidationSchema(compiled)
      // REQ-293 — use the parser's own TaskFormField tree (parsed.properties),
      // which carries visibleWhen/computed/crossFieldValidation, rather than
      // casting the raw schema properties object directly.
      setFormFields(parsed.properties ?? {})
      form.reset({})
    } catch (err) {
      setParseError(err instanceof Error ? err.message : 'Failed to parse form schema')
      setValidationSchema(null)
    }
  }, [formSchema, form])

  // REQ-293 — one evaluation context per render, built from the form's own live
  // watch()-observed values of every top-level field (design doc §8.2). Scoped
  // to top-level `properties` keys only — nested object/array fields are never
  // inputs to visible_when/computed/cross_field_validation.
  const watchedValues = form.watch()
  const expressionVariables = useMemo(
    () => watchedValues as unknown as Record<string, unknown>,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [JSON.stringify(watchedValues)],
  )

  const { visibility, computedValues, crossFieldErrors } = useFormExpressions(
    formFields,
    expressionVariables,
    manifest,
  )

  // Computed fields are read-only and server-authoritative on submit — this
  // effect only keeps the on-screen value in sync with the client's own
  // (advisory, non-authoritative) evaluation, per design doc §8.5.
  useEffect(() => {
    for (const [fieldName, state] of Object.entries(computedValues)) {
      if (state.kind === 'evaluated') {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const current = (form.getValues as any)(fieldName)
        if (current !== state.value) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const setValue = form.setValue as any
          setValue(fieldName, state.value, { shouldValidate: false, shouldDirty: false })
        }
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [computedValues])

  if (parseError) {
    return (
      <div style={{ background: 'var(--color-error-light)', border: '1px solid var(--color-error-border)', borderRadius: '6px', padding: '1rem', marginBottom: '1.5rem' }}>
        <p style={{ color: 'var(--color-error-dark)', fontWeight: 600, margin: '0 0 0.5rem 0' }}>Unable to render form schema</p>
        <p style={{ color: 'var(--color-error-dark)', fontSize: '.9rem', margin: 0 }}>
          {parseError}
        </p>
      </div>
    )
  }

  // REQ-293 AC8 — a client-side cross-field pass (or an unevaluable result) is
  // informational UI feedback only. `handleFormSubmit` still calls `onSubmit`
  // whenever react-hook-form's own Zod-driven validation passes, regardless of
  // `crossFieldErrors`'s contents — this is never wired into `form.setError`
  // or the Zod resolver, and never blocks the submit button. Server authority:
  // `Letflow.Engine.FormExpressionReevaluation.reevaluate/3` at task completion
  // is the actual, unconditional gate (design doc §8.5).
  const handleFormSubmit = async (values: DynamicFormValue) => {
    setLocalSubmitting(true)
    try {
      await onSubmit(values)
    } catch {
      // Error handling done by parent
    } finally {
      // §4.2 / §12.4 mode 3 — aria-busy cleared in finally regardless of outcome.
      setLocalSubmitting(false)
    }
  }

  const formBusy = isSubmitting || localSubmitting

  const commonInputStyles = {
    width: '100%',
    padding: '.5rem .75rem',
    border: '1px solid var(--color-neutral-400)',
    borderRadius: '4px',
    fontSize: '.9rem',
    fontFamily: 'inherit',
    boxSizing: 'border-box' as const,
  }

  const evaluatedCrossFieldMessages = Object.entries(crossFieldErrors).filter(
    ([, state]) => state.kind === 'evaluated' && state.value !== null,
  ) as [string, { kind: 'evaluated'; value: string }][]

  const unevaluableCrossField = Object.entries(crossFieldErrors).filter(
    ([, state]) => state.kind === 'unevaluable',
  ) as [string, { kind: 'unevaluable'; reason: string }][]

  return (
    <form
      onSubmit={form.handleSubmit(handleFormSubmit)}
      data-testid="task-form"
      aria-busy={formBusy ? 'true' : 'false'}
      style={{ overflow: 'hidden' }}
    >
      {submitError && (
        <div style={{ background: 'var(--color-error-light)', border: '1px solid var(--color-error-border)', borderRadius: '6px', padding: '1rem', marginBottom: '1rem' }}>
          <p style={{ color: 'var(--color-error-dark)', margin: 0, fontSize: '.9rem' }}>
            {submitError.message}
          </p>
        </div>
      )}

      {/* REQ-293 — cross-field validation feedback, advisory only (AC8). */}
      {evaluatedCrossFieldMessages.map(([fieldName, state]) => (
        <div
          key={`cross-field-${fieldName}`}
          data-testid={`cross-field-error-${fieldName}`}
          role="alert"
          style={{ background: 'var(--color-error-light)', border: '1px solid var(--color-error-border)', borderRadius: '6px', padding: '.75rem', marginBottom: '1rem' }}
        >
          <p style={{ color: 'var(--color-error-dark)', margin: 0, fontSize: '.9rem' }}>{state.value}</p>
        </div>
      ))}
      {unevaluableCrossField.map(([fieldName, state]) => (
        <div key={`cross-field-unevaluable-${fieldName}`} style={{ marginBottom: '1rem' }}>
          <ExpressionUnavailableBanner field={fieldName} kind="cross_field_validation" reason={state.reason} />
        </div>
      ))}

      {/* Render form fields from schema */}
      {Object.entries(formFields).map(([fieldName, fieldDef]: [string, TaskFormField]) => {
        const isRequired = fieldDef.required || false
        const title = fieldDef.title || fieldName
        const description = fieldDef.description
        const fieldType = fieldDef.type || 'string'
        const fieldError = form.formState.errors[fieldName]

        // REQ-293 — visible_when (design doc §8.2/§8.3/§8.4 table).
        const visState = fieldDef.visibleWhen ? visibility[fieldName] : undefined
        if (visState?.kind === 'evaluated' && visState.value === false) {
          return null // omitted from the DOM — not "unevaluable", just false
        }

        const compState = fieldDef.computed ? computedValues[fieldName] : undefined

        return (
          <div key={fieldName} style={{ marginBottom: '1rem' }}>
            <label
              htmlFor={fieldName}
              style={{
                display: 'block',
                marginBottom: '.5rem',
                fontWeight: 500,
                fontSize: '.9rem',
                color: 'var(--text-primary)',
              }}
            >
              {title}
              {isRequired && <span style={{ color: 'var(--color-error)', marginLeft: '.25rem' }}>*</span>}
            </label>

            {description && (
              <p style={{ margin: '0.25rem 0 0.5rem 0', fontSize: '.85rem', color: 'var(--text-secondary)' }}>
                {description}
              </p>
            )}

            {visState?.kind === 'unevaluable' ? (
              <ExpressionUnavailableBanner field={fieldName} kind="visible_when" reason={visState.reason} />
            ) : fieldDef.computed && compState?.kind === 'unevaluable' ? (
              <ExpressionUnavailableBanner field={fieldName} kind="computed" reason={compState.reason} />
            ) : fieldDef.computed ? (
              <input
                id={fieldName}
                data-testid={`computed-field-${fieldName}`}
                readOnly
                value={compState?.kind === 'evaluated' ? String(compState.value ?? '') : ''}
                style={{ ...commonInputStyles, background: 'var(--color-neutral-100)' } as React.CSSProperties}
              />
            ) : (
              <>
                {fieldType === 'string' && !fieldDef.widget && !fieldDef.enum && (
                  <input
                    {...form.register(fieldName)}
                    id={fieldName}
                    type={fieldDef.format === 'email' ? 'email' : fieldDef.format === 'date' ? 'date' : 'text'}
                    placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                    style={{
                      ...commonInputStyles,
                      borderColor: fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)',
                    } as React.CSSProperties}
                  />
                )}

                {fieldType === 'string' && fieldDef.widget === 'textarea' && (
                  <textarea
                    {...form.register(fieldName)}
                    id={fieldName}
                    placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                    rows={4}
                    style={{
                      ...commonInputStyles,
                      borderColor: fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)',
                      resize: 'vertical',
                    } as React.CSSProperties}
                  />
                )}

                {fieldType === 'string' && fieldDef.enum && (
                  <select
                    {...form.register(fieldName)}
                    id={fieldName}
                    style={{
                      ...commonInputStyles,
                      borderColor: fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)',
                    } as React.CSSProperties}
                  >
                    <option value="">Select {title.toLowerCase()}</option>
                    {fieldDef.enum.map((option: string | number) => (
                      <option key={option} value={option}>
                        {option}
                      </option>
                    ))}
                  </select>
                )}

                {fieldType === 'number' && (
                  <input
                    {...form.register(fieldName, { valueAsNumber: true })}
                    id={fieldName}
                    type="number"
                    placeholder={fieldDef.placeholder || `Enter ${title.toLowerCase()}`}
                    style={{
                      ...commonInputStyles,
                      borderColor: fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)',
                    } as React.CSSProperties}
                  />
                )}

                {fieldType === 'boolean' && (
                  <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem' }}>
                    <input
                      {...form.register(fieldName)}
                      id={fieldName}
                      type="checkbox"
                      style={{
                        width: '1rem',
                        height: '1rem',
                        cursor: 'pointer',
                      }}
                    />
                    <label htmlFor={fieldName} style={{ cursor: 'pointer', margin: 0, fontWeight: 'normal' }}>
                      {title}
                    </label>
                  </div>
                )}

                {fieldType === 'date' && (
                  <input
                    {...form.register(fieldName)}
                    id={fieldName}
                    type="date"
                    style={{
                      ...commonInputStyles,
                      borderColor: fieldError ? 'var(--border-error)' : 'var(--color-neutral-400)',
                    } as React.CSSProperties}
                  />
                )}
                {fieldType === 'date' && (
                  <DateValueHint value={String((watchedValues as Record<string, unknown>)[fieldName] ?? '')} kind="date" />
                )}
              </>
            )}

            {fieldError && (
              <p
                style={{
                  marginTop: '.25rem',
                  fontSize: '.85rem',
                  color: 'var(--color-error)',
                }}
              >
                {typeof fieldError.message === 'string' ? fieldError.message : 'Invalid field'}
              </p>
            )}
          </div>
        )
      })}

      <button
        type="submit"
        data-testid="task-submit-btn"
        disabled={formBusy}
        style={{
          width: '100%',
          padding: '.75rem 1rem',
          background: 'var(--interactive-primary)',
          color: 'var(--text-inverse)',
          border: 'none',
          borderRadius: '4px',
          cursor: formBusy ? 'not-allowed' : 'pointer',
          opacity: formBusy ? 0.7 : 1,
          fontSize: '.9rem',
          fontWeight: 500,
        }}
      >
        {formBusy ? 'Submitting…' : submitLabel}
      </button>
    </form>
  )
}
