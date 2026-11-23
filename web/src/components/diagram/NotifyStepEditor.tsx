/** NotifyStepEditor — T-2600 (pilot gap G5b): the NOTIFICATION STEP form of a SERVICE_TASK: the CHANNEL
 *  (e-mail or file), the TEMPLATE picker, the RECIPIENT and the VALUES.
 *
 *  The form is fed by the COMPILED catalogue (`GET /api/v1/notification-templates/catalogue`): a new registered
 *  template appears here without a change to this file. Choosing one shows the placeholders it accepts; every
 *  placeholder is filled with a VARIABLE of the process (`var`) or with a FIXED value (`const`).
 *
 *  The RECIPIENT is a variable, never a fixed address: a constant address would sit in the stored definition of
 *  the tenant, and the address of a person is personal data the platform does not store (INV-4). The server
 *  refuses a constant recipient with `notify_recipient_invalid`, so the form does not offer one.
 *
 *  The FILE NAME is a plain name: a name that carries a separator, a `..`, a drive letter or a home directory is
 *  refused here, with the same code the server uses (`notify_file_name_invalid`), so a definition that names a
 *  path never reaches the version that is switched on.
 *
 *  The component owns no graph: every change is a `NotifyStep` handed to `onChange`, and the caller writes it
 *  into the node's `notify` attribute through the usual graph edit.
 */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { Select } from '@/components/ui/Select'
import type { ApiError, NotificationTemplateEntry } from '@/types/api'
import {
  fileNameProblem,
  isUsableVariableName,
  notifyProblems,
  valueSource,
  withChannel,
  withValue,
  type NotifyChannel,
  type NotifyProblem,
  type NotifyStep,
} from '@/utils/canvas/notifyStep'

/** The catalogue as the page hands it down: the registered templates, the load state and the retry. The page owns
 *  the read (the diagram components are pure views over the graph); this is the one object that travels down to
 *  the picker. */
export interface NotifyCatalogueState {
  entries: NotificationTemplateEntry[]
  loading: boolean
  error: ApiError | null
  onRetry: () => void
}

export interface NotifyStepEditorProps {
  /** The node's notification step. */
  step: NotifyStep
  /** The catalogue the picker offers. */
  catalogue: NotifyCatalogueState
  /** The new step; the caller writes it into the graph. */
  onChange: (step: NotifyStep) => void
}

const CHANNEL_OPTIONS: { value: NotifyChannel; labelKey: string }[] = [
  { value: 'email', labelKey: 'processDiagram.edit.notify.channel.email' },
  { value: 'file', labelKey: 'processDiagram.edit.notify.channel.file' },
]

const SOURCE_OPTIONS: { value: string; labelKey: string }[] = [
  { value: '', labelKey: 'processDiagram.edit.notify.source.unset' },
  { value: 'var', labelKey: 'processDiagram.edit.notify.source.var' },
  { value: 'const', labelKey: 'processDiagram.edit.notify.source.const' },
]

export function NotifyStepEditor({ step, catalogue, onChange }: NotifyStepEditorProps) {
  const intl = useIntl()
  const e = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const { entries, loading, error, onRetry } = catalogue
  const entry = entries.find((x) => x.template_key === step.templateKey) ?? null
  const placeholders = entry ? entry.placeholders : null
  const problems = notifyProblems(
    step,
    placeholders,
    entries.map((x) => x.template_key),
  )

  if (loading) {
    return (
      <p className="lf-hint" data-testid="notify-step-loading">
        {e('processDiagram.edit.notify.loading')}
      </p>
    )
  }

  if (error) {
    // A caller without the definition read gets 403: the catalogue is not readable here, and an empty list would
    // read as "this tenant has no templates".
    const forbidden = error.status === 403
    return (
      <div className="lf-pd-edit__notify" data-testid="notify-step-error">
        <p className="lf-hint">{forbidden ? e('processDiagram.edit.notify.forbidden') : e('processDiagram.edit.notify.error')}</p>
        {!forbidden && (
          <Button variant="secondary" size="sm" onClick={onRetry} data-testid="notify-step-retry">
            {e('processDiagram.edit.notify.retry')}
          </Button>
        )}
      </div>
    )
  }

  if (entries.length === 0) {
    return (
      <p className="lf-hint" data-testid="notify-step-empty">
        {e('processDiagram.edit.notify.empty')}
      </p>
    )
  }

  const problem = (code: NotifyProblem) => (problems.includes(code) ? e(`processDiagram.edit.notify.problem.${code}`) : undefined)
  // A problem that a FIELD already shows is not repeated in the list under it: the list names the problems no
  // field of the form can show (a value that names a placeholder the template does not allow).
  const inField: NotifyProblem[] = [
    'template_missing',
    'template_unknown',
    'recipient_missing',
    'recipient_invalid',
    'file_name_missing',
    'file_name_invalid',
  ]
  const listed = problems.filter((code) => !inField.includes(code))

  return (
    <div className="lf-pd-edit__notify" data-testid="notify-step-editor">
      <Select
        label={e('processDiagram.edit.notify.channel')}
        value={step.channel}
        options={CHANNEL_OPTIONS.map((o) => ({ value: o.value, label: e(o.labelKey) }))}
        onChange={(value) => onChange(withChannel(step, value as NotifyChannel))}
        data-testid="notify-step-channel"
      />
      <Select
        label={e('processDiagram.edit.notify.template')}
        value={step.templateKey}
        placeholder={e('processDiagram.edit.notify.templatePlaceholder')}
        error={problem('template_missing') ?? problem('template_unknown')}
        options={entries.map((x) => ({ value: x.template_key, label: x.template_key }))}
        onChange={(value) => onChange({ ...step, templateKey: value })}
        data-testid="notify-step-template"
      />
      {step.channel === 'email' ? (
        <NotifyRecipientField step={step} onChange={onChange} problem={problem} />
      ) : (
        <NotifyFileNameField step={step} onChange={onChange} problem={problem} />
      )}
      {entry && (
        <section aria-label={e('processDiagram.edit.notify.values')} data-testid="notify-step-values">
          <h4 className="lf-pd-edit__notify-head">{e('processDiagram.edit.notify.values')}</h4>
          {entry.placeholders.length === 0 && (
            <p className="lf-hint">{e('processDiagram.edit.notify.noValues')}</p>
          )}
          {entry.placeholders.map((name) => (
            <NotifyValueRow key={name} name={name} step={step} onChange={onChange} problem={problem} />
          ))}
        </section>
      )}
      {listed.length > 0 && (
        <ul className="lf-pd-edit__problems" data-testid="notify-step-problems">
          {listed.map((code) => (
            <li key={code}>{e(`processDiagram.edit.notify.problem.${code}`)}</li>
          ))}
        </ul>
      )}
    </div>
  )
}

interface NotifyFieldProps {
  step: NotifyStep
  onChange: (step: NotifyStep) => void
  problem: (code: NotifyProblem) => string | undefined
}

/** The RECIPIENT of the mail channel: the variable the address is read from. The name is local state, so a name
 *  that breaks the rule stays in the field with its error and never reaches the graph. */
function NotifyRecipientField({ step, onChange, problem }: NotifyFieldProps) {
  const intl = useIntl()
  const e = (id: string) => intl.formatMessage({ id })
  const [text, setText] = useState(step.recipientVar)
  const [touched, setTouched] = useState(false)
  const nameError = touched && text !== '' && !isUsableVariableName(text)
  const error = nameError
    ? e('processDiagram.edit.notify.variableError')
    : (problem('recipient_invalid') ?? problem('recipient_missing'))

  return (
    <Field
      label={e('processDiagram.edit.notify.recipient')}
      width="m"
      hint={e('processDiagram.edit.notify.recipientHint')}
      error={error}
    >
      <input
        value={text}
        onChange={(ev) => {
          setText(ev.target.value)
          setTouched(true)
          if (isUsableVariableName(ev.target.value)) onChange({ ...step, recipientVar: ev.target.value })
        }}
        data-testid="notify-step-recipient"
      />
    </Field>
  )
}

/** The FILE NAME of the file channel: a plain name, never a path. The text stays in the field until it is a plain
 *  name, so a path never reaches the graph. */
function NotifyFileNameField({ step, onChange, problem }: NotifyFieldProps) {
  const intl = useIntl()
  const e = (id: string) => intl.formatMessage({ id })
  const [text, setText] = useState(step.fileName)
  const [touched, setTouched] = useState(false)
  const bad = touched && fileNameProblem(text) !== null
  const error = bad
    ? e('processDiagram.edit.notify.fileNameError')
    : (problem('file_name_invalid') ?? problem('file_name_missing'))

  return (
    <Field
      label={e('processDiagram.edit.notify.fileName')}
      width="m"
      hint={e('processDiagram.edit.notify.fileNameHint')}
      error={error}
    >
      <input
        value={text}
        onChange={(ev) => {
          setText(ev.target.value)
          setTouched(true)
          if (fileNameProblem(ev.target.value) === null) onChange({ ...step, fileName: ev.target.value })
        }}
        data-testid="notify-step-file-name"
      />
    </Field>
  )
}

/** One placeholder of the chosen template: where its value comes from (a variable of the process or a fixed
 *  value) and what it is. */
function NotifyValueRow({ name, step, onChange }: NotifyFieldProps & { name: string }) {
  const intl = useIntl()
  const e = (id: string) => intl.formatMessage({ id })
  const source = valueSource(step, name)
  const [varText, setVarText] = useState(source && 'var' in source ? source.var : '')
  const [constText, setConstText] = useState(source && 'const' in source ? source.const : '')
  const [varTouched, setVarTouched] = useState(false)
  const varError = varTouched && varText !== '' && !isUsableVariableName(varText)

  const changeSource = (next: string) => {
    setVarText('')
    setConstText('')
    setVarTouched(false)
    if (next === '') onChange(withValue(step, name, null))
    else if (next === 'var') onChange(withValue(step, name, { var: '' }))
    else onChange(withValue(step, name, { const: '' }))
  }

  return (
    <div className="lf-pd-edit__notify-arg" data-testid={`notify-value-${name}`}>
      <p className="lf-pd-edit__notify-arg-head">
        <span className="lf-pd__mono">{name}</span>
      </p>
      <Select
        label={e('processDiagram.edit.notify.source')}
        width="m"
        value={source === null ? '' : 'var' in source ? 'var' : 'const'}
        options={SOURCE_OPTIONS.map((o) => ({ value: o.value, label: e(o.labelKey) }))}
        onChange={changeSource}
        data-testid={`notify-value-source-${name}`}
      />
      {source && 'var' in source && (
        <Field
          label={e('processDiagram.edit.notify.variableName')}
          width="m"
          error={varError ? e('processDiagram.edit.notify.variableError') : undefined}
        >
          <input
            value={varText}
            onChange={(ev) => {
              setVarText(ev.target.value)
              setVarTouched(true)
              if (isUsableVariableName(ev.target.value)) onChange(withValue(step, name, { var: ev.target.value }))
            }}
            data-testid={`notify-value-var-${name}`}
          />
        </Field>
      )}
      {source && 'const' in source && (
        <Field label={e('processDiagram.edit.notify.value')} width="m">
          <input
            value={constText}
            onChange={(ev) => {
              setConstText(ev.target.value)
              onChange(withValue(step, name, { const: ev.target.value }))
            }}
            data-testid={`notify-value-const-${name}`}
          />
        </Field>
      )}
    </div>
  )
}
