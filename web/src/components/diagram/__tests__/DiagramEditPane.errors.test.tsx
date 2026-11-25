// @vitest-environment jsdom
/** T-2813 (D3): the editor never shows a raw code or an HTTP status name; a known code reads as a plain sentence. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import type { ProcessDefinition } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { DiagramEditPane } from '../DiagramEditPane'
expect.extend(jestDomMatchers)

vi.mock('@/api/definitions', () => ({
  definitionsApi: { update: vi.fn(), create: vi.fn(), get: vi.fn(), validate: vi.fn() },
}))
import { definitionsApi } from '@/api/definitions'

class RO {
  constructor(private cb: ResizeObserverCallback) {}
  observe(el: Element) {
    this.cb([{ contentRect: { width: 1200, height: 600 }, target: el } as unknown as ResizeObserverEntry], this as unknown as ResizeObserver)
  }
  unobserve() {}
  disconnect() {}
}
beforeEach(() => {
  vi.stubGlobal('ResizeObserver', RO)
  vi.stubGlobal('DOMMatrixReadOnly', class { m22 = 1 })
  vi.mocked(definitionsApi.validate).mockResolvedValue({ status: 'valid', definition_id: 'd', findings: [] })
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  act(() => useUiLocaleStore.getState().setLocale('en'))
})

const DEF: ProcessDefinition = {
  id: 'def-1', name: 'Order', version: '1.0.0', description: 'd', status: 'DRAFT', created_by: 'u',
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-02T00:00:00Z',
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: { position: { x: 0, y: 0 } } },
      { id: 'end', node_type: 'END', label: null, attributes: { position: { x: 0, y: 100 } } },
    ],
    edges: [{ id: 'e1', source: 'start', target: 'end' }],
  },
}

function show(error: { code?: string; status?: number; message: string }) {
  const qc = new QueryClient()
  render(
    <QueryClientProvider client={qc}>
      <ProcessDiagramIntlProvider>
        <DiagramEditPane def={DEF} editorDirty={false} onDirtyChange={vi.fn()} onSaved={vi.fn()} onReload={vi.fn()} demo={{ error: { kind: 'other', ...error } }} />
      </ProcessDiagramIntlProvider>
    </QueryClientProvider>,
  )
  return screen.getByTestId('edit-error-other')
}

describe('DiagramEditPane error text', () => {
  it('E1 notify_malformed reads as a plain sentence, the raw code only under details', () => {
    const el = show({ code: 'notify_malformed', status: 422, message: 'Unprocessable Entity' })
    expect(el.textContent).toContain('notification step is not filled in correctly')
    expect(el.textContent).not.toContain('notify_malformed')
    expect(el.textContent).not.toContain('Unprocessable')
    expect(screen.getByTestId('edit-error-details').textContent).toContain('notify_malformed')
  })

  it('E2 platform_call_function_unknown is translated to Russian', () => {
    act(() => useUiLocaleStore.getState().setLocale('ru'))
    const el = show({ code: 'platform_call_function_unknown', status: 422, message: 'Unprocessable Content' })
    expect(el.textContent).toContain('Выбранной функции нет')
    expect(el.textContent).not.toContain('Unprocessable')
  })

  it('E3 an unknown code with a 409 gets the conflict sentence; any other gets the fallback, never the status name', () => {
    const el = show({ code: 'brand_new', status: 409, message: 'Conflict' })
    expect(el.textContent).toContain('no longer a draft')
    expect(el.textContent).not.toContain('Conflict')
    cleanup()
    const el2 = show({ code: undefined, status: 500, message: 'Internal Server Error' })
    expect(el2.textContent).toContain('Something went wrong')
    expect(el2.textContent).not.toContain('Internal Server Error')
  })
})
