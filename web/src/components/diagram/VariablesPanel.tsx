/** VariablesPanel — T-2811 (designer D1). The process variables on the Edit-diagram screen: name, type, where it comes
 *  from (start form / earlier step / added here and not saved yet), and a form to add one. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import type { DefinitionGraph } from '@/types/api'
import { VARIABLE_TYPES, variableSource, variableType, type VariableType } from '@/utils/canvas/declaredVariables'
import { useDeclaredVariables } from './DeclaredVariablesContext'

export function VariablesPanel({ graph, savedKeys }: { graph: DefinitionGraph; savedKeys: ReadonlySet<string> }) {
  const intl = useIntl()
  const e = (id: string) => intl.formatMessage({ id })
  const ctx = useDeclaredVariables()
  const [name, setName] = useState('')
  const [type, setType] = useState<VariableType>('string')
  const [refusal, setRefusal] = useState<string | null>(null)
  if (!ctx) return null

  const submit = () => {
    const r = ctx.add(name, type)
    if (r) setRefusal(e(`processDiagram.edit.vars.refusal.${r}`))
    else {
      setName('')
      setRefusal(null)
    }
  }

  return (
    <details className="lf-pd-edit__vars" open data-testid="variables-panel">
      <summary>{e('processDiagram.edit.vars.title')}</summary>
      <p className="lf-hint">{e('processDiagram.edit.vars.lede')}</p>
      {ctx.variables.length === 0 ? (
        <p className="lf-hint" data-testid="variables-empty">{e('processDiagram.edit.vars.empty')}</p>
      ) : (
        <table className="lf-table" data-testid="variables-table">
          <thead>
            <tr>
              <th>{e('processDiagram.edit.vars.name')}</th>
              <th>{e('processDiagram.edit.vars.type')}</th>
              <th>{e('processDiagram.edit.vars.source')}</th>
            </tr>
          </thead>
          <tbody>
            {ctx.variables.map((v) => (
              <tr key={v.variable_key} data-testid={`variable-row-${v.variable_key}`}>
                <td className="lf-pd__mono">{v.variable_key}</td>
                <td className="lf-pd__mono">{variableType(v) || '—'}</td>
                <td>
                  {savedKeys.has(v.variable_key)
                    ? e(`processDiagram.edit.vars.source.${variableSource(graph, v.variable_key)}`)
                    : e('processDiagram.edit.vars.source.added')}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <div className="lf-pd-edit__addvar">
        <Field label={e('processDiagram.edit.vars.name')} width="m" error={refusal ?? undefined}>
          <input value={name} onChange={(ev) => setName(ev.target.value)} data-testid="variables-add-name" />
        </Field>
        <Select label={e('processDiagram.edit.vars.type')} width="s" value={type} options={VARIABLE_TYPES.map((t) => ({ value: t, label: t }))} onChange={(v) => setType(v as VariableType)} data-testid="variables-add-type" />
        <Button variant="secondary" size="sm" onClick={submit} data-testid="variables-add-submit">
          {e('processDiagram.edit.vars.add')}
        </Button>
      </div>
    </details>
  )
}
