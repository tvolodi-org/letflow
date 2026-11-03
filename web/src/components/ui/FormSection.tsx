/** FormSection and FormActions (NOTES.md section 2; markup of style-guide "lf-form").
 *  FormSection: titled group of rows. FormActions: primary and secondary actions plus a hint
 *  that says whether there are unsaved changes; `saving` replaces the hint with the saving text. */
import React from 'react'
import type { EntitiesUiLocale } from '@/i18n/entitiesMessages'
import { useFormMessages } from './uiMessages'

export function FormSection(props: { title?: string; children: React.ReactNode }): React.ReactElement {
  return (
    <section className="lf-form__section">
      {props.title && <h3 className="lf-form__title">{props.title}</h3>}
      {props.children}
    </section>
  )
}

export function FormRow(props: { children: React.ReactNode }): React.ReactElement {
  return <div className="lf-form__row">{props.children}</div>
}

export interface FormActionsProps {
  primary?: React.ReactNode
  secondary?: React.ReactNode
  /** Undefined hides the hint; true shows the unsaved-changes text, false the clean text. */
  dirty?: boolean
  saving?: boolean
  locale?: EntitiesUiLocale
}

export function FormActions(props: FormActionsProps): React.ReactElement {
  const { primary, secondary, dirty, saving, locale } = props
  const msgs = useFormMessages(locale)
  const hint = saving ? msgs.saving : dirty === undefined ? null : dirty ? msgs.dirty : msgs.clean
  return (
    <div className="lf-form__actions">
      {primary}
      {secondary}
      {hint && (
        <span className="lf-hint" role="status" data-testid="form-actions-hint">
          {hint}
        </span>
      )}
    </div>
  )
}
