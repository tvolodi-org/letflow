/** ExamBuilderFields — GH 3355 / REQ-602
 *
 *  The small controlled inputs of the exam builder screen. Each one renders its label, the control
 *  and (when given) the error text under it with `aria-invalid` / `role="alert"`. No text of its own:
 *  every string is passed in from the page, which takes it from examMessages.
 */

import type { ReactNode } from 'react'
import { useIntl } from 'react-intl'
import { BUILDER_LOCALES, type LocalizedInput } from './examBuilderModel'

const labelStyle = { display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-secondary)' } as const
const inputStyle = {
  display: 'block',
  padding: 'var(--space-1) var(--space-2)',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-md)',
  background: 'var(--surface-card)',
  color: 'var(--text-primary)',
} as const
const errorStyle = { color: 'var(--interactive-danger)', fontSize: 'var(--text-sm)' } as const

function ErrorText({ id, testId, error }: { id: string; testId: string; error?: string }) {
  if (!error) return null
  return (
    <span id={`${id}-error`} role="alert" data-testid={`${testId}-error`} style={errorStyle}>
      {error}
    </span>
  )
}

interface BaseProps {
  id: string
  testId: string
  label: string
  error?: string
}

export function TextField(
  props: BaseProps & { value: string; onChange: (value: string) => void; type?: string },
) {
  const { id, testId, label, error, value, onChange, type = 'text' } = props
  return (
    <div>
      <label htmlFor={id} style={labelStyle}>
        {label}
      </label>
      <input
        id={id}
        data-testid={testId}
        type={type}
        value={value}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        onChange={(event) => onChange(event.target.value)}
        style={inputStyle}
      />
      <ErrorText id={id} testId={testId} error={error} />
    </div>
  )
}

export function SelectField(
  props: BaseProps & {
    value: string
    onChange: (value: string) => void
    options: { value: string; label: string }[]
    placeholder: string
  },
) {
  const { id, testId, label, error, value, onChange, options, placeholder } = props
  return (
    <div>
      <label htmlFor={id} style={labelStyle}>
        {label}
      </label>
      <select
        id={id}
        data-testid={testId}
        value={value}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-error` : undefined}
        onChange={(event) => onChange(event.target.value)}
        style={inputStyle}
      >
        {!options.some((o) => o.value === value) && <option value={value}>{placeholder}</option>}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      <ErrorText id={id} testId={testId} error={error} />
    </div>
  )
}

export function CheckField(props: Omit<BaseProps, 'error'> & { checked: boolean; onChange: (value: boolean) => void }) {
  const { id, testId, label, checked, onChange } = props
  return (
    <div>
      <label htmlFor={id}>
        <input
          id={id}
          data-testid={testId}
          type="checkbox"
          checked={checked}
          onChange={(event) => onChange(event.target.checked)}
        />{' '}
        {label}
      </label>
    </div>
  )
}

/** One text input per locale (kk, ru, en) under a shared label; the error belongs to the group. */
export function LocalizedField(
  props: BaseProps & { value: LocalizedInput; onChange: (locale: keyof LocalizedInput, text: string) => void },
) {
  const intl = useIntl()
  const { id, testId, label, error, value, onChange } = props
  return (
    <fieldset style={{ border: 'none', padding: 0, margin: 0 }}>
      <legend style={labelStyle}>{label}</legend>
      {BUILDER_LOCALES.map((locale) => (
        <input
          key={locale}
          id={`${id}-${locale}`}
          data-testid={`${testId}-${locale}`}
          aria-label={`${label}: ${intl.formatMessage({ id: `exam.builder.locale.${locale}` })}`}
          placeholder={intl.formatMessage({ id: `exam.builder.locale.${locale}` })}
          value={value[locale]}
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? `${id}-error` : undefined}
          onChange={(event) => onChange(locale, event.target.value)}
          style={{ ...inputStyle, marginBottom: 'var(--space-1)' }}
        />
      ))}
      <ErrorText id={id} testId={testId} error={error} />
    </fieldset>
  )
}

export function Panel({ testId, heading, children }: { testId: string; heading: string; children: ReactNode }) {
  return (
    <section
      data-testid={testId}
      style={{
        border: '1px solid var(--border-default)',
        borderRadius: 'var(--radius-md)',
        background: 'var(--surface-card)',
        padding: 'var(--space-4)',
        marginBottom: 'var(--space-4)',
        display: 'grid',
        gap: 'var(--space-3)',
      }}
    >
      <h2 style={{ margin: 0, fontSize: 'var(--text-lg)' }}>{heading}</h2>
      {children}
    </section>
  )
}
