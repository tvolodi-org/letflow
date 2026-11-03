/** Field — label + control + hint/error (NOTES.md section 2; markup of style-guide "lf-field").
 *
 *  children: one input/select/textarea element. Field gives it `id`, `aria-invalid`,
 *  `aria-describedby`, `readOnly` and `disabled` (a child's own props win for id).
 *  width s/m/l sets the field width; omitted = fills the row.
 */
import React, { useId } from 'react'
import { AlertCircle } from 'lucide-react'
import type { EntitiesUiLocale } from '@/i18n/entitiesMessages'
import { useFormMessages } from './formMessages'

export interface FieldProps {
  label: string
  hint?: string
  error?: string
  optional?: boolean
  width?: 's' | 'm' | 'l'
  readOnly?: boolean
  disabled?: boolean
  leadingIcon?: React.ReactNode
  mono?: boolean
  /** Hide the label visually (it stays in the accessibility tree). */
  hideLabel?: boolean
  /** Extra node after the control inside the box (used by Select for its chevron). */
  trailing?: React.ReactNode
  locale?: EntitiesUiLocale
  'data-testid'?: string
  children: React.ReactElement
}

export function Field(props: FieldProps): React.ReactElement {
  const { label, hint, error, optional, width, readOnly, disabled, leadingIcon, mono, hideLabel, trailing, children } = props
  const msgs = useFormMessages(props.locale)
  const autoId = useId()
  const childProps = children.props as { id?: string; 'aria-describedby'?: string }
  const id = childProps.id ?? autoId
  const hintId = `${id}-hint`
  const errorId = `${id}-error`
  const describedBy = [childProps['aria-describedby'], error ? errorId : hint ? hintId : undefined]
    .filter(Boolean)
    .join(' ')

  const fieldClasses = ['lf-field']
  if (width) fieldClasses.push(`lf-field--${width}`)
  if (error) fieldClasses.push('lf-field--error')
  const controlClasses = ['lf-control']
  if (readOnly) controlClasses.push('lf-control--readonly')
  if (mono) controlClasses.push('lf-control--mono')

  const control = React.cloneElement(children, {
    id,
    'aria-invalid': error ? true : undefined,
    'aria-describedby': describedBy || undefined,
    ...(readOnly ? { readOnly: true } : {}),
    ...(disabled ? { disabled: true } : {}),
  } as Record<string, unknown>)

  return (
    <div className={fieldClasses.join(' ')} data-testid={props['data-testid']}>
      <label className={hideLabel ? 'lf-label sr-only' : 'lf-label'} htmlFor={id}>
        {label}
        {optional && (
          <>
            {' '}
            <span className="lf-label__opt">{msgs.optional}</span>
          </>
        )}
      </label>
      <div className={controlClasses.join(' ')} aria-disabled={disabled ? 'true' : undefined}>
        {leadingIcon && <span className="lf-control__lead">{leadingIcon}</span>}
        {control}
        {trailing}
      </div>
      {error ? (
        <span className="lf-error" id={errorId}>
          <AlertCircle className="lf-icon" aria-hidden="true" />
          {error}
        </span>
      ) : hint ? (
        <span className="lf-hint" id={hintId}>
          {hint}
        </span>
      ) : null}
    </div>
  )
}
