/** PlatformCallEditor — T-2599 (pilot gap G5a): the FUNCTION PICKER of a SERVICE_TASK and the TYPED var/const
 *  ARGUMENT MAPPING.
 *
 *  The picker is fed by the COMPILED catalogue (`GET /api/v1/platform-functions`): a new platform function appears
 *  here without a change to this file. Choosing one shows its typed arguments; every argument is mapped to a
 *  VARIABLE of the process (`var`) or to a FIXED value (`const`), and the two mapping sides the server reads
 *  (`reads`, `writes`) are derived from that mapping — the designer never types a type by hand.
 *
 *  The type of a row is the DECLARED one — the JSON-Schema name the server reads, never the catalogue's own name
 *  (a uuid is declared as a string). A variable name that breaks the rule (a dot, the reserved namespace, an empty
 *  name) is refused in the field, with the field's own error, and never reaches the graph.
 *
 *  The component owns no graph: every change is a `PlatformCall` handed to `onChange`, and the caller writes it
 *  into the node's `platform_call` attribute through the usual graph edit.
 */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { Checkbox } from '@/components/ui/Checkbox'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import { useDeclaredVariables } from './DeclaredVariablesContext'
import { VariablePicker } from './VariablePicker'
import type { ApiError, PlatformFunctionEntry, PlatformFunctionInput } from '@/types/api'
import {
  argSource,
  argText,
  declaredTypeName,
  emptyPlatformCall,
  isPlainVariableName,
  isReservedVariableName,
  parseConst,
  readConflicts,
  withArg,
  withDerivedMapping,
  type ConstError,
  type PlatformCall,
} from '@/utils/canvas/platformCall'

/** The catalogue as the page hands it down: the entries the caller's tenant may use, the load state and the retry.
 *  The page owns the read (the diagram components are pure views over the graph); this is the one object that
 *  travels down to the picker. */
export interface PlatformCatalogueState {
  entries: PlatformFunctionEntry[]
  loading: boolean
  error: ApiError | null
  onRetry: () => void
}

export interface PlatformCallEditorProps {
  /** The node's call, or null when the node carries none. */
  call: PlatformCall | null
  /** The catalogue the picker offers. */
  catalogue: PlatformCatalogueState
  /** The new call; the caller writes it into the graph. */
  onChange: (call: PlatformCall) => void
}

const SOURCE_OPTIONS: { value: string; labelKey: string }[] = [
  { value: '', labelKey: 'processDiagram.edit.platform.source.unset' },
  { value: 'var', labelKey: 'processDiagram.edit.platform.source.var' },
  { value: 'const', labelKey: 'processDiagram.edit.platform.source.const' },
]

export function PlatformCallEditor({ call, catalogue, onChange }: PlatformCallEditorProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { entries, loading, error, onRetry } = catalogue
  const entry = entries.find((x) => x.name === call?.function) ?? null

  // The mapping sides are derived: the caller always receives the shape the server reads.
  const commit = (next: PlatformCall) => {
    const target = entries.find((x) => x.name === next.function)
    onChange(target ? withDerivedMapping(next, target) : next)
  }

  if (loading) {
    return (
      <p className="lf-hint" data-testid="platform-call-loading">
        {e('processDiagram.edit.platform.loading')}
      </p>
    )
  }

  if (error) {
    // A caller without the platform atom gets 403: the catalogue is not readable here, and an empty palette would
    // read as "this tenant has no platform functions" (INV-10).
    const forbidden = error.status === 403
    return (
      <div className="lf-pd-edit__platform" data-testid="platform-call-error">
        <p className="lf-hint">{forbidden ? e('processDiagram.edit.platform.forbidden') : e('processDiagram.edit.platform.error')}</p>
        {!forbidden && (
          <Button variant="secondary" size="sm" onClick={onRetry} data-testid="platform-call-retry">
            {e('processDiagram.edit.platform.retry')}
          </Button>
        )}
      </div>
    )
  }

  if (entries.length === 0) {
    return (
      <p className="lf-hint" data-testid="platform-call-empty">
        {e('processDiagram.edit.platform.empty')}
      </p>
    )
  }

  const conflicts = entry && call ? readConflicts(call, entry) : []

  return (
    <div className="lf-pd-edit__platform" data-testid="platform-call-editor">
      <Select
        label={e('processDiagram.edit.platform.function')}
        value={call?.function ?? ''}
        placeholder={e('processDiagram.edit.platform.functionPlaceholder')}
        options={entries.map((x) => ({ value: x.name, label: x.name }))}
        onChange={(name) => commit(call?.function === name ? (call as PlatformCall) : emptyPlatformCall(name))}
        data-testid="platform-call-function"
      />
      {entry && call && (
        <>
          <section aria-label={e('processDiagram.edit.platform.arguments')} data-testid="platform-call-arguments">
            <h4 className="lf-pd-edit__platform-head">{e('processDiagram.edit.platform.arguments')}</h4>
            {entry.inputs.length === 0 && <p className="lf-hint">{e('processDiagram.edit.platform.noArguments')}</p>}
            {entry.inputs.map((input) => (
              <PlatformArgRow key={`${entry.name}:${input.name}`} input={input} call={call} onChange={commit} />
            ))}
          </section>
          {entry.outputs.length > 0 && (
            <section aria-label={e('processDiagram.edit.platform.outputs')} data-testid="platform-call-outputs">
              <h4 className="lf-pd-edit__platform-head">{e('processDiagram.edit.platform.outputs')}</h4>
              {entry.outputs.map((output) => (
                <Checkbox
                  key={output.name}
                  label={
                    <span className="lf-pd__mono">
                      {output.name}: {declaredTypeName(output.type)}
                    </span>
                  }
                  checked={output.name in call.writes}
                  onChange={(checked) => {
                    const writes = { ...call.writes }
                    if (checked) writes[output.name] = declaredTypeName(output.type)
                    else delete writes[output.name]
                    commit({ ...call, writes })
                  }}
                  data-testid={`platform-call-output-${output.name}`}
                />
              ))}
            </section>
          )}
          {conflicts.length > 0 && (
            <p className="lf-pd-edit__problems" data-testid="platform-call-conflict">
              {e('processDiagram.edit.platform.conflict')}
            </p>
          )}
        </>
      )}
    </div>
  )
}

interface ArgRowProps {
  input: PlatformFunctionInput
  call: PlatformCall
  onChange: (call: PlatformCall) => void
}

/** The name a variable argument may carry: plain (not empty, no dot, within the bound) and outside the system's
 *  reserved namespace. The server refuses both (`platform_call_arg_source_invalid`,
 *  `platform_call_arg_sys_reference`); the field refuses them before the name reaches the graph. */
function isUsableVariableName(name: string): boolean {
  return isPlainVariableName(name) && !isReservedVariableName(name)
}

/** One argument of the chosen function: where its value comes from (a variable or a fixed value) and what it is.
 *  The constant's TEXT is local state, so a half-typed number stays in the field; only a value that fits the
 *  declared type reaches the graph. The variable NAME has a rule of its own, so it is local state too: a name that
 *  breaks the rule stays in the field with its error and never reaches the graph. */
function PlatformArgRow({ input, call, onChange }: ArgRowProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const source = argSource(call, input.name)
  const declared = useDeclaredVariables()
  // The type of the row is the DECLARED one: the JSON-Schema name the server reads (a uuid is declared as a string).
  const type = declaredTypeName(input.type)
  const [text, setText] = useState(() => (source === 'const' ? argText(call, input.name, type) : ''))
  const [error, setError] = useState<ConstError | null>(null)
  const initialVarText = source === 'var' ? argText(call, input.name, type) : ''
  const [varText, setVarText] = useState(initialVarText)
  // A name that is already broken when the panel opens (a hand-authored definition) shows its error at once; an
  // empty field shows nothing until it is written in.
  const [varTouched, setVarTouched] = useState(() => initialVarText !== '' && !isUsableVariableName(initialVarText))
  const varError = varTouched && !isUsableVariableName(varText)

  const changeSource = (next: string) => {
    setText('')
    setError(null)
    setVarText('')
    setVarTouched(false)
    if (next === '') onChange(withArg(call, input.name, null, null))
    else if (next === 'var') onChange(withArg(call, input.name, 'var', ''))
    else onChange(withArg(call, input.name, 'const', ''))
  }

  const changeVarText = (next: string) => {
    setVarText(next)
    setVarTouched(true)
    if (!isUsableVariableName(next)) return
    onChange(withArg(call, input.name, 'var', next))
  }

  const changeConstText = (next: string) => {
    setText(next)
    const parsed = parseConst(type, next)
    if (parsed.ok) {
      setError(null)
      onChange(withArg(call, input.name, 'const', parsed.value))
    } else {
      setError(parsed.error)
    }
  }

  const value = source === 'const' ? text : varText
  const constError = error ? e(`processDiagram.edit.platform.constError.${error}`) : undefined

  return (
    <div className="lf-pd-edit__arg" data-testid={`platform-arg-${input.name}`}>
      <p className="lf-pd-edit__arg-head">
        <span className="lf-pd__mono">{input.name}</span>
        <span className="lf-pd__mono">{type}</span>
        <span className="lf-hint">
          {input.required ? e('processDiagram.edit.platform.required') : e('processDiagram.edit.platform.optional')}
          {' · '}
          {e(`processDiagram.edit.platform.class.${input.source_class}`)}
        </span>
      </p>
      <Select
        label={e('processDiagram.edit.platform.source')}
        width="m"
        value={source ?? ''}
        options={SOURCE_OPTIONS.map((o) => ({ value: o.value, label: e(o.labelKey) }))}
        onChange={changeSource}
        data-testid={`platform-arg-source-${input.name}`}
      />
      {source === 'var' && declared && (
        <VariablePicker
          label={e('processDiagram.edit.platform.variableName')}
          hint={e('processDiagram.edit.platform.variableHint')}
          value={value}
          onPick={(picked) => {
            setVarText(picked)
            onChange(withArg(call, input.name, 'var', picked))
          }}
          testId={`platform-arg-var-${input.name}`}
        />
      )}
      {source === 'var' && !declared && (
        <Field
          label={e('processDiagram.edit.platform.variableName')}
          width="m"
          hint={e('processDiagram.edit.platform.variableHint')}
          error={varError ? e('processDiagram.edit.platform.variableError') : undefined}
        >
          <input
            value={value}
            onChange={(ev) => changeVarText(ev.target.value)}
            data-testid={`platform-arg-var-${input.name}`}
          />
        </Field>
      )}
      {source === 'const' && (
        <Field label={e('processDiagram.edit.platform.value')} width="m" error={constError}>
          <input
            value={value}
            onChange={(ev) => changeConstText(ev.target.value)}
            data-testid={`platform-arg-const-${input.name}`}
          />
        </Field>
      )}
    </div>
  )
}
