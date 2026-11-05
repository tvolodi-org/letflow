/** RegistryForm — create / edit form inside the details pane (rule 2a: no modal). Fields come from a small
 *  definition list; each error names its field; a failed save shows a count banner (caller draws it through
 *  `summary`) and the messages next to the fields. Dates use DateField (lf-date). The form keeps no server
 *  knowledge: `onSave(values)` returns an error text per field, or nothing. */
import { useState, type FormEvent } from 'react'
import { AlertCircle } from 'lucide-react'
import { Banner } from '../Banner'
import { Button } from '../Button'
import { DateField } from '../DateField'
import { Field } from '../Field'
import { Select, type SelectOption } from '../Select'

export type RegistryFormFieldDef = {
  key: string
  label: string
  kind: 'text' | 'mono' | 'area' | 'select' | 'date'
  required?: boolean
  full?: boolean
  readOnly?: boolean
  options?: SelectOption[]
  placeholder?: string
}

export type RegistryFormValues = Record<string, string>
export type RegistryFormErrors = Record<string, string>

export interface RegistryFormLabels {
  save: string
  create: string
  cancel: string
  unsaved: string
  /** "2 fields need attention" */
  summary: (n: number) => string
  /** The message for an empty required field; names the field. */
  required: (field: string) => string
}

export interface RegistryFormProps {
  fields: RegistryFormFieldDef[]
  initial: RegistryFormValues
  creating: boolean
  labels: RegistryFormLabels
  /** Resolves to errors by field key (server answer), or nothing when the save worked. */
  onSave: (values: RegistryFormValues) => Promise<RegistryFormErrors | void> | RegistryFormErrors | void
  onCancel: () => void
}

export function RegistryForm(props: RegistryFormProps) {
  const { fields, labels: L } = props
  const [values, setValues] = useState<RegistryFormValues>(props.initial)
  const [shown, setShown] = useState(false)
  const [serverErrors, setServerErrors] = useState<RegistryFormErrors>({})
  const [busy, setBusy] = useState(false)
  const dirty = fields.some((f) => (values[f.key] ?? '') !== (props.initial[f.key] ?? ''))

  const local: RegistryFormErrors = {}
  for (const f of fields) {
    if (f.required && !f.readOnly && (values[f.key] ?? '').trim() === '') local[f.key] = L.required(f.label)
  }
  const errors = { ...local, ...serverErrors }
  const count = Object.keys(errors).length

  const set = (key: string) => (v: string) => {
    setValues((s) => ({ ...s, [key]: v }))
    setServerErrors((s) => {
      if (!(key in s)) return s
      const rest = { ...s }
      delete rest[key]
      return rest
    })
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    setShown(true)
    if (Object.keys(local).length > 0) return
    setBusy(true)
    try {
      const res = await props.onSave(values)
      if (res && Object.keys(res).length > 0) setServerErrors(res)
    } finally {
      setBusy(false)
    }
  }

  return (
    <form className="lf-reg__form" noValidate onSubmit={(e) => void submit(e)} data-testid="registry-form" data-dirty={dirty ? 'true' : 'false'}>
      {(shown || Object.keys(serverErrors).length > 0) && count > 0 && (
        <Banner tone="danger" title={L.summary(count)} />
      )}
      <div className="lf-reg__fields">
        {fields.map((f) => {
          const err = shown || serverErrors[f.key] ? errors[f.key] : undefined
          const cls = f.full ? 'lf-reg__field lf-reg__field--full' : 'lf-reg__field'
          const readOnly = f.readOnly && !props.creating
          if (f.kind === 'date') {
            return (
              <div className={cls} key={f.key}>
                <DateField
                  label={f.label}
                  value={values[f.key] ?? ''}
                  onChange={set(f.key)}
                  optional={!f.required}
                  error={err}
                  showErrors={shown}
                  readOnly={readOnly}
                />
              </div>
            )
          }
          if (f.kind === 'select') {
            return (
              <div className={cls} key={f.key}>
                <Select
                  label={f.label}
                  optional={!f.required}
                  error={err}
                  readOnly={readOnly}
                  options={f.options ?? []}
                  value={values[f.key] ?? ''}
                  onChange={set(f.key)}
                  placeholder={f.placeholder}
                />
              </div>
            )
          }
          return (
            <div className={cls} key={f.key}>
              <Field label={f.label} optional={!f.required} error={err} readOnly={readOnly} mono={f.kind === 'mono'}>
                {f.kind === 'area' ? (
                  <textarea rows={3} value={values[f.key] ?? ''} onChange={(e) => set(f.key)(e.target.value)} />
                ) : (
                  <input autoComplete="off" value={values[f.key] ?? ''} onChange={(e) => set(f.key)(e.target.value)} />
                )}
              </Field>
            </div>
          )
        })}
      </div>
      <div className="lf-form__actions">
        <Button variant="primary" type="submit" loading={busy} data-testid="registry-save">
          {props.creating ? L.create : L.save}
        </Button>
        <Button variant="ghost" onClick={props.onCancel} data-testid="registry-cancel">
          {L.cancel}
        </Button>
        {dirty && (
          <span className="lf-hint">
            <AlertCircle className="lf-icon" aria-hidden="true" /> {L.unsaved}
          </span>
        )}
      </div>
    </form>
  )
}
