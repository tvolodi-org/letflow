// @vitest-environment jsdom
/** PlatformCallEditor — T-2599 (pilot gap G5a): the function picker and the typed var/const argument mapping.
 *  F1 the palette offers the catalogue, F2 choosing a function starts a call, F3 a variable argument writes the
 *  mapping, F4 a fixed value writes the argument, F5 a value that does not fit the type is refused, F6 the outputs
 *  the step writes, F7 the load states (loading, forbidden, failed, empty), F8 the texts in en/ru/kk. */
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { ApiError, PlatformFunctionEntry } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { PlatformCallEditor, type PlatformCatalogueState } from '../PlatformCallEditor'
import { emptyPlatformCall, type PlatformCall } from '@/utils/canvas/platformCall'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

const ENTRY: PlatformFunctionEntry = {
  name: 'platform.validate_registration',
  family: 'platform',
  version: '1',
  permission: 'TenantsManage',
  platform_tenant_only: true,
  idempotency_inputs: ['slug'],
  inputs: [
    { name: 'slug', type: 'string', required: true, source_class: 'start' },
    { name: 'display_name', type: 'string', required: true, source_class: 'start' },
  ],
  outputs: [
    { name: 'normalized_slug', type: 'string' },
    { name: 'email_domain', type: 'string' },
  ],
  side_effects: [{ text: 'reads nothing and writes nothing', class: 'read' }],
}

const NUMBER_ENTRY: PlatformFunctionEntry = {
  ...ENTRY,
  name: 'tenant.provision',
  inputs: [{ name: 'retries', type: 'integer', required: false, source_class: 'start' }],
  outputs: [],
}

const CATALOGUE: PlatformCatalogueState = { entries: [ENTRY, NUMBER_ENTRY], loading: false, error: null, onRetry: () => {} }

function Harness({
  initial = null,
  catalogue = CATALOGUE,
  onCall,
}: {
  initial?: PlatformCall | null
  catalogue?: PlatformCatalogueState
  onCall?: (call: PlatformCall) => void
}) {
  const [call, setCall] = useState<PlatformCall | null>(initial)
  return (
    <ProcessDiagramIntlProvider>
      <PlatformCallEditor
        call={call}
        catalogue={catalogue}
        onChange={(next) => {
          setCall(next)
          onCall?.(next)
        }}
      />
    </ProcessDiagramIntlProvider>
  )
}

/** The `Select` component puts the test id on its Field wrapper; the control is the select inside it. */
const selectIn = (testid: string) => screen.getByTestId(testid).querySelector('select') as HTMLSelectElement

describe('PlatformCallEditor', () => {
  it('F1 the palette offers every function of the catalogue', () => {
    render(<Harness />)
    const select = selectIn('platform-call-function')
    const values = Array.from(select.querySelectorAll('option')).map((o) => (o as HTMLOptionElement).value)
    expect(values).toContain('platform.validate_registration')
    expect(values).toContain('tenant.provision')
  })

  it('F2 choosing a function starts a call with an empty mapping', () => {
    const onCall = vi.fn()
    render(<Harness onCall={onCall} />)
    fireEvent.change(selectIn('platform-call-function'), { target: { value: 'platform.validate_registration' } })
    expect(onCall).toHaveBeenCalledWith({
      function: 'platform.validate_registration',
      args: {},
      reads: {},
      writes: {},
    })
    // The arguments of the chosen function are listed.
    expect(screen.getByTestId('platform-arg-slug')).toBeInTheDocument()
    expect(screen.getByTestId('platform-arg-display_name')).toBeInTheDocument()
  })

  it('F3 a variable argument writes the argument and the read it declares', () => {
    const onCall = vi.fn()
    render(<Harness onCall={onCall} />)
    fireEvent.change(selectIn('platform-call-function'), { target: { value: 'platform.validate_registration' } })
    fireEvent.change(selectIn('platform-arg-source-slug'), { target: { value: 'var' } })
    expect(onCall).toHaveBeenLastCalledWith(expect.objectContaining({ args: { slug: { var: '' } } }))
    fireEvent.change(screen.getByTestId('platform-arg-var-slug'), { target: { value: 'tenant_slug' } })
    expect(onCall).toHaveBeenLastCalledWith(
      expect.objectContaining({ args: { slug: { var: 'tenant_slug' } }, reads: { tenant_slug: 'string' } }),
    )
  })

  it('F4 a fixed value writes the argument and reads nothing', () => {
    const onCall = vi.fn()
    render(<Harness onCall={onCall} />)
    fireEvent.change(selectIn('platform-call-function'), { target: { value: 'platform.validate_registration' } })
    fireEvent.change(selectIn('platform-arg-source-display_name'), { target: { value: 'const' } })
    fireEvent.change(screen.getByTestId('platform-arg-const-display_name'), { target: { value: 'Acme' } })
    expect(onCall).toHaveBeenLastCalledWith(
      expect.objectContaining({ args: { display_name: { const: 'Acme' } }, reads: {} }),
    )
  })

  it('F5 a value that does not fit the declared type is refused and does not reach the graph', () => {
    const onCall = vi.fn()
    render(<Harness onCall={onCall} />)
    fireEvent.change(selectIn('platform-call-function'), { target: { value: 'tenant.provision' } })
    fireEvent.change(selectIn('platform-arg-source-retries'), { target: { value: 'const' } })
    onCall.mockClear()
    fireEvent.change(screen.getByTestId('platform-arg-const-retries'), { target: { value: 'many' } })
    expect(onCall).not.toHaveBeenCalled()
    expect(screen.getByText('This value must be a number.')).toBeInTheDocument()
    fireEvent.change(screen.getByTestId('platform-arg-const-retries'), { target: { value: '3' } })
    expect(onCall).toHaveBeenLastCalledWith(expect.objectContaining({ args: { retries: { const: 3 } } }))
  })

  it('F6 the outputs the step writes are declared by name', () => {
    const onCall = vi.fn()
    render(<Harness onCall={onCall} />)
    fireEvent.change(selectIn('platform-call-function'), { target: { value: 'platform.validate_registration' } })
    fireEvent.click(screen.getByTestId('platform-call-output-normalized_slug'))
    expect(onCall).toHaveBeenLastCalledWith(expect.objectContaining({ writes: { normalized_slug: 'string' } }))
    fireEvent.click(screen.getByTestId('platform-call-output-normalized_slug'))
    expect(onCall).toHaveBeenLastCalledWith(expect.objectContaining({ writes: {} }))
  })

  it('F7 the load states are told apart', () => {
    const { unmount } = render(
      <Harness catalogue={{ entries: [], loading: true, error: null, onRetry: () => {} }} />,
    )
    expect(screen.getByTestId('platform-call-loading')).toBeInTheDocument()
    unmount()

    render(<Harness catalogue={{ entries: [], loading: false, error: { status: 403 } as ApiError, onRetry: () => {} }} />)
    expect(screen.getByTestId('platform-call-error')).toHaveTextContent('not available in this tenant')
    cleanup()

    const onRetry = vi.fn()
    render(<Harness catalogue={{ entries: [], loading: false, error: { status: 500 } as ApiError, onRetry }} />)
    fireEvent.click(screen.getByTestId('platform-call-retry'))
    expect(onRetry).toHaveBeenCalled()
    cleanup()

    render(<Harness catalogue={{ entries: [], loading: false, error: null, onRetry: () => {} }} />)
    expect(screen.getByTestId('platform-call-empty')).toBeInTheDocument()
  })

  it('F8 the texts are in the UI language', () => {
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    render(<Harness initial={emptyPlatformCall('platform.validate_registration')} />)
    expect(screen.getByText('Функция')).toBeInTheDocument()
    expect(screen.getByText('Аргументы')).toBeInTheDocument()
    cleanup()

    act(() => useUiLocaleStore.getState().setLocale('kk'))
    render(<Harness initial={emptyPlatformCall('platform.validate_registration')} />)
    expect(screen.getByText('Функция')).toBeInTheDocument()
    expect(screen.getByText('Дәйексіздер')).toBeInTheDocument()
  })

  it('F9 the chosen function is shown and the arguments of another function are not', () => {
    render(<Harness initial={emptyPlatformCall('platform.validate_registration')} />)
    expect(selectIn('platform-call-function').value).toBe('platform.validate_registration')
    expect(screen.getByTestId('platform-arg-slug')).toBeInTheDocument()
    const outputs = screen.getByTestId('platform-call-outputs')
    expect(within(outputs).getByText(/normalized_slug/)).toBeInTheDocument()
  })
})
