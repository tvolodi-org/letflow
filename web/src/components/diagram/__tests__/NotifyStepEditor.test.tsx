// @vitest-environment jsdom
/** NotifyStepEditor — T-2600 (pilot gap G5b): the notification step's form: the channel, the template picker,
 *  the recipient and the values. F1 the template picker offers the registered templates, F2 the mail channel
 *  asks for the variable the address is read from (a fixed address is never offered), F3 the file channel asks
 *  for a plain file name and refuses a path, F4 a value is filled with a variable or with a fixed value, F5 the
 *  problems of a step are shown, F6 the load states (loading, forbidden, failed, empty). */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { ApiError, NotificationTemplateEntry } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { NotifyStepEditor, type NotifyCatalogueState } from '../NotifyStepEditor'
import { emptyNotifyStep, type NotifyStep } from '@/utils/canvas/notifyStep'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

const ENTRY: NotificationTemplateEntry = {
  template_key: 'tenant_registered',
  placeholders: ['tenant_name', 'tenant_slug', 'registered_by'],
}

const OTHER: NotificationTemplateEntry = { template_key: 'task_assigned', placeholders: ['task_name'] }

const CATALOGUE: NotifyCatalogueState = { entries: [ENTRY, OTHER], loading: false, error: null, onRetry: () => {} }

/** The `data-testid` of a Select sits on the Field wrapper: the control is the `select` inside it. */
const selectIn = (testid: string) => screen.getByTestId(testid).querySelector('select') as HTMLSelectElement

function Harness({
  initial,
  catalogue = CATALOGUE,
  onStep,
}: {
  initial: NotifyStep
  catalogue?: NotifyCatalogueState
  onStep?: (step: NotifyStep) => void
}) {
  const [step, setStep] = useState<NotifyStep>(initial)
  return (
    <ProcessDiagramIntlProvider>
      <NotifyStepEditor
        step={step}
        catalogue={catalogue}
        onChange={(next) => {
          setStep(next)
          onStep?.(next)
        }}
      />
    </ProcessDiagramIntlProvider>
  )
}

const mailStep = (): NotifyStep => ({
  ...emptyNotifyStep(),
  templateKey: 'tenant_registered',
  recipientVar: 'admin_email',
})

describe('NotifyStepEditor — the notification step', () => {
  it('F1 the template picker offers the registered templates', () => {
    render(<Harness initial={mailStep()} />)
    const select = selectIn('notify-step-template')
    const values = Array.from(select.options).map((o) => o.value)
    expect(values).toEqual(['', 'tenant_registered', 'task_assigned'])
  })

  it('F2 the mail channel asks for the variable the address is read from', () => {
    render(<Harness initial={mailStep()} />)
    expect(screen.getByTestId('notify-step-recipient')).toBeInTheDocument()
    expect((screen.getByTestId('notify-step-recipient') as HTMLInputElement).value).toBe('admin_email')
    // The file name belongs to the other channel.
    expect(screen.queryByTestId('notify-step-file-name')).not.toBeInTheDocument()
  })

  it('F3 the file channel asks for a plain file name and refuses a path', () => {
    render(<Harness initial={{ ...emptyNotifyStep('file'), templateKey: 'tenant_registered', fileName: 'notice' }} />)
    const input = screen.getByTestId('notify-step-file-name') as HTMLInputElement
    expect(input.value).toBe('notice')

    fireEvent.change(input, { target: { value: '../x' } })
    expect(screen.getByText('A plain name only: no separator, no "..", no drive letter.')).toBeInTheDocument()
    // The path never reaches the step: the field keeps the text, the step keeps the old name.
    expect(input.value).toBe('../x')
  })

  it('F4 a value is filled with a variable or with a fixed value', () => {
    const seen: NotifyStep[] = []
    render(<Harness initial={mailStep()} onStep={(s) => seen.push(s)} />)

    // The placeholders of the chosen template are the rows of the form.
    expect(screen.getByTestId('notify-value-tenant_name')).toBeInTheDocument()
    expect(screen.getByTestId('notify-value-tenant_slug')).toBeInTheDocument()
    expect(screen.getByTestId('notify-value-registered_by')).toBeInTheDocument()

    fireEvent.change(selectIn('notify-value-source-tenant_name'), { target: { value: 'var' } })
    fireEvent.change(screen.getByTestId('notify-value-var-tenant_name'), { target: { value: 'tenant_name' } })
    expect(seen[seen.length - 1]?.values.tenant_name).toEqual({ var: 'tenant_name' })

    fireEvent.change(selectIn('notify-value-source-tenant_slug'), { target: { value: 'const' } })
    fireEvent.change(screen.getByTestId('notify-value-const-tenant_slug'), { target: { value: 'known-co' } })
    expect(seen[seen.length - 1]?.values.tenant_slug).toEqual({ const: 'known-co' })
  })

  it('F5 the problems of a step are shown next to the field that carries them', () => {
    render(<Harness initial={{ ...emptyNotifyStep(), templateKey: 'tenant_registered' }} />)
    // The missing recipient is shown in the recipient field, not repeated in a list under it.
    expect(screen.getByText('Name the variable the address is read from.')).toBeInTheDocument()
    expect(screen.queryByTestId('notify-step-problems')).not.toBeInTheDocument()
  })

  it('F5b a problem no field can show is listed', () => {
    render(
      <Harness
        initial={{
          ...emptyNotifyStep(),
          templateKey: 'tenant_registered',
          recipientVar: 'admin_email',
          values: { other: { var: 'x' } },
        }}
      />,
    )
    const problems = screen.getByTestId('notify-step-problems')
    expect(problems.textContent).toContain('A value names a placeholder this template does not allow.')
  })

  it('F6 the load states', () => {
    const { unmount } = render(
      <Harness initial={mailStep()} catalogue={{ entries: [], loading: true, error: null, onRetry: () => {} }} />,
    )
    expect(screen.getByTestId('notify-step-loading')).toBeInTheDocument()
    unmount()

    const forbidden = { status: 403, message: 'forbidden' } as unknown as ApiError
    const r2 = render(<Harness initial={mailStep()} catalogue={{ entries: [], loading: false, error: forbidden, onRetry: () => {} }} />)
    expect(screen.getByTestId('notify-step-error').textContent).toContain('not available in this tenant')
    r2.unmount()

    const failed = { status: 500, message: 'boom' } as unknown as ApiError
    const retry = vi.fn()
    const r3 = render(<Harness initial={mailStep()} catalogue={{ entries: [], loading: false, error: failed, onRetry: retry }} />)
    fireEvent.click(screen.getByTestId('notify-step-retry'))
    expect(retry).toHaveBeenCalled()
    r3.unmount()

    render(<Harness initial={mailStep()} catalogue={{ entries: [], loading: false, error: null, onRetry: () => {} }} />)
    expect(screen.getByTestId('notify-step-empty')).toBeInTheDocument()
  })
})
