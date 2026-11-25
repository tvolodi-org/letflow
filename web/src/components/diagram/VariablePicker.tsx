/** VariablePicker — T-2811 (designer D1). Picks a variable of the process from the declared ones, with an "Add a variable"
 *  entry that opens a small name + type form in place; the new variable is declared and picked at once. A value that is
 *  not declared (a hand-written definition) stays in the list, marked, so it is never hidden. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { VARIABLE_TYPES, variableType, type VariableType } from '@/utils/canvas/declaredVariables'
import { useDeclaredVariables } from './DeclaredVariablesContext'

const ADD = '__add_variable__'

export interface VariablePickerProps {
  label: string
  value: string
  hint?: string
  error?: string
  onPick: (name: string) => void
  testId: string
}

export function VariablePicker({ label, value, hint, error, onPick, testId }: VariablePickerProps) {
  const intl = useIntl()
  const e = (id: string) => intl.formatMessage({ id })
  const ctx = useDeclaredVariables()
  const [adding, setAdding] = useState(false)
  const [name, setName] = useState('')
  const [type, setType] = useState<VariableType>('string')
  const [refusal, setRefusal] = useState<string | null>(null)
  if (!ctx) return null

  const declared = ctx.variables.map((v) => ({ value: v.variable_key, label: `${v.variable_key} (${variableType(v) || '—'})` }))
  const known = value === '' || ctx.variables.some((v) => v.variable_key === value)
  const options = [
    ...declared,
    ...(known ? [] : [{ value, label: `${value} — ${e('processDiagram.edit.vars.notDeclared')}` }]),
    { value: ADD, label: e('processDiagram.edit.vars.addEntry') },
  ]

  const submit = () => {
    const r = ctx.add(name, type)
    if (r) {
      setRefusal(e(`processDiagram.edit.vars.refusal.${r}`))
      return
    }
    onPick(name.trim())
    setAdding(false)
    setName('')
    setRefusal(null)
  }

  return (
    <>
      <Select
        label={label}
        width="m"
        hint={hint}
        error={error}
        value={value}
        placeholder={e('processDiagram.edit.vars.choose')}
        options={options}
        onChange={(v) => {
          if (v === ADD) setAdding(true)
          else onPick(v)
        }}
        data-testid={testId}
      />
      {adding && (
        <div className="lf-pd-edit__addvar" data-testid={`${testId}-add`}>
          <Field label={e('processDiagram.edit.vars.name')} width="m" error={refusal ?? undefined}>
            <input value={name} onChange={(ev) => setName(ev.target.value)} data-testid={`${testId}-add-name`} />
          </Field>
          <Select
            label={e('processDiagram.edit.vars.type')}
            width="s"
            value={type}
            options={VARIABLE_TYPES.map((t) => ({ value: t, label: t }))}
            onChange={(v) => setType(v as VariableType)}
            data-testid={`${testId}-add-type`}
          />
          <div className="lf-pd-edit__addvar-actions">
            <Button variant="primary" size="sm" onClick={submit} data-testid={`${testId}-add-submit`}>
              {e('processDiagram.edit.vars.add')}
            </Button>
            <Button variant="ghost" size="sm" onClick={() => setAdding(false)}>
              {e('processDiagram.edit.vars.cancel')}
            </Button>
          </div>
        </div>
      )}
    </>
  )
}
