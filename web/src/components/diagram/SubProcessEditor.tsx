/** SubProcessEditor — T-2847 (PILOT-SUB-4): the CHILD PICKER of a SUB_PROCESS step and its VARIABLE MAPPING.
 *
 *  The author picks the child from the ACTIVE definitions the parent may call (name and version), sees the variables
 *  the child declares, and ticks the ones to pass in and to take back. The mapping model is the node's `interface`
 *  attribute: a ticked name is copied into the child (`inputs`) or merged back (`outputs`) under the SAME name.
 *
 *  A process that writes into a module is started by that module only (`Letflow.Engine.SubProcess`): a tenant-made
 *  parent does not get it in the list, and says so in plain words; a module parent sees the processes of its own
 *  module. If the list cannot be read the step keeps the plain name field, so a definition is never locked.
 *  The component owns no graph: it hands `onChange(name, interface)` to the caller. */
import { useIntl } from 'react-intl'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { Checkbox } from '@/components/ui/Checkbox'
import { useActiveDefinitions, useChildDefinition } from '@/hooks/useSubProcessChildren'
import { buildInterface, isModuleOnly, mappedNames, splitChildren } from '@/utils/canvas/subProcessChildren'

export interface SubProcessEditorProps {
  tenantId: string | null
  /** The `owner_module` stamp of the definition being edited (null for a tenant-made one). */
  parentOwnerModule: string | null
  /** The node's current `definition_name` and `interface` attributes. */
  definitionName: string
  iface: unknown
  onChange: (definitionName: string, iface?: { inputs: unknown[]; outputs: unknown[] }) => void
}

export function SubProcessEditor({ tenantId, parentOwnerModule, definitionName, iface, onChange }: SubProcessEditorProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `processDiagram.edit.sub.${id}` }, values)
  const list = useActiveDefinitions(tenantId, true)
  const items = list.data?.items ?? []
  const { callable, moduleOnly } = splitChildren(items, parentOwnerModule)
  const chosen = items.find((d) => d.name === definitionName) ?? null
  const chosenCallable = callable.find((d) => d.name === definitionName) ?? null
  const detail = useChildDefinition(tenantId, chosenCallable?.id ?? null)
  const declared = detail.data?.variable_schemas ?? []
  const mapped = mappedNames(iface)

  if (list.isPending) {
    return (
      <p className="lf-hint" data-testid="sub-loading">
        {e('loading')}
      </p>
    )
  }
  if (list.error) {
    return (
      <>
        <Field label={intl.formatMessage({ id: 'processDiagram.edit.field.subDefinition' })}>
          <input value={definitionName} onChange={(ev) => onChange(ev.target.value, undefined)} data-testid="edit-field-sub-definition" />
        </Field>
        <p className="lf-hint" data-testid="sub-error">
          {e('error')}
        </p>
      </>
    )
  }

  const options = callable.map((d) => ({ value: d.name, label: e('option', { name: d.name, version: d.version }) }))
  const toggle = (name: string, dir: 'inputs' | 'outputs', on: boolean) => {
    const next = { inputs: new Set(mapped.inputs), outputs: new Set(mapped.outputs) }
    if (on) next[dir].add(name)
    else next[dir].delete(name)
    onChange(definitionName, buildInterface(declared, next.inputs, next.outputs))
  }

  return (
    <div className="lf-pd-edit__sub" data-testid="sub-process-editor">
      <Select
        label={intl.formatMessage({ id: 'processDiagram.edit.field.subDefinition' })}
        value={chosenCallable ? definitionName : ''}
        placeholder={e('placeholder')}
        options={options}
        onChange={(v) => onChange(v, undefined)}
        data-testid="edit-field-sub-definition"
      />
      {callable.length === 0 && (
        <p className="lf-hint" data-testid="sub-none">
          {e('none')}
        </p>
      )}
      {moduleOnly > 0 && (
        <p className="lf-hint" data-testid="sub-module-only">
          {e('moduleOnly', { count: moduleOnly })}
        </p>
      )}
      {definitionName !== '' && !chosenCallable && (
        <p className="lf-hint" role="alert" data-testid="sub-chosen-refused">
          {chosen && isModuleOnly(chosen) ? e('chosenModuleOnly', { name: definitionName }) : e('chosenMissing', { name: definitionName })}
        </p>
      )}
      {chosenCallable && detail.isPending && <p className="lf-hint">{e('variablesLoading')}</p>}
      {chosenCallable && detail.error && <p className="lf-hint" data-testid="sub-variables-error">{e('variablesError')}</p>}
      {chosenCallable && detail.data && (
        <section aria-label={e('variables')} data-testid="sub-variables">
          <h4>{e('variables')}</h4>
          {declared.length === 0 ? (
            <p className="lf-hint" data-testid="sub-no-variables">
              {e('noVariables')}
            </p>
          ) : (
            <>
              <p className="lf-hint">{e('variablesHint')}</p>
              <ul className="lf-pd-edit__conns">
                {declared.map((v) => (
                  <li key={v.variable_key} data-testid={`sub-var-${v.variable_key}`}>
                    <div>
                      <code>{v.variable_key}</code>
                    </div>
                    <div>
                      <Checkbox
                        label={e('passIn', { name: v.variable_key })}
                        checked={mapped.inputs.has(v.variable_key)}
                        onChange={(on) => toggle(v.variable_key, 'inputs', on)}
                        data-testid={`sub-in-${v.variable_key}`}
                      />
                    </div>
                    <div>
                      <Checkbox
                        label={e('takeBack', { name: v.variable_key })}
                        checked={mapped.outputs.has(v.variable_key)}
                        onChange={(on) => toggle(v.variable_key, 'outputs', on)}
                        data-testid={`sub-out-${v.variable_key}`}
                      />
                    </div>
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>
      )}
    </div>
  )
}
