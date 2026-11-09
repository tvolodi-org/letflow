// @vitest-environment jsdom
/** T-1563 DiagramEditPane: the save contract. S1 DRAFT → PATCH-shaped update(id, {graph}) only, S2 ACTIVE → create with the
 *  next version and copy_variable_schemas_from, S3 each 409 has its own handling, S4 stale updated_at asks first,
 *  S6 body keys, S7 blocking vs advisory violations and the fixture classification, S8 the Editor lock. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ProcessDefinition } from '@/types/api'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'
import { DiagramEditPane } from '../DiagramEditPane'
import { ADVISORY_CODES, isBlocking } from '@/hooks/useValidateDraft'
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
Object.defineProperties(window.HTMLElement.prototype, {
  offsetHeight: { configurable: true, get: () => 600 },
  offsetWidth: { configurable: true, get: () => 1000 },
})
beforeEach(() => {
  vi.stubGlobal('ResizeObserver', RO)
  vi.stubGlobal('DOMMatrixReadOnly', class { m22 = 1 })
  vi.mocked(definitionsApi.validate).mockResolvedValue({ status: 'valid', definition_id: 'd', findings: [] })
})
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.unstubAllGlobals()
})

const DEF: ProcessDefinition = {
  id: 'def-1',
  name: 'Order',
  version: '1.0.0',
  description: 'desc',
  status: 'DRAFT',
  created_by: 'u',
  created_at: '2026-11-01T00:00:00Z',
  updated_at: '2026-11-02T00:00:00Z',
  graph: {
    nodes: [
      { id: 'start', node_type: 'START', label: null, attributes: { position: { x: 0, y: 0 } } },
      { id: 'end', node_type: 'END', label: null, attributes: { position: { x: 0, y: 100 } } },
    ],
    edges: [{ id: 'e1', source: 'start', target: 'end' }],
  },
}

const onSaved = vi.fn()
const onReload = vi.fn()
const tree = (def: ProcessDefinition, editorDirty: boolean, qc: QueryClient) => (
  <QueryClientProvider client={qc}>
    <ProcessDiagramIntlProvider>
      <DiagramEditPane def={def} editorDirty={editorDirty} onDirtyChange={vi.fn()} onSaved={onSaved} onReload={onReload} />
    </ProcessDiagramIntlProvider>
  </QueryClientProvider>
)
function mount(def: ProcessDefinition = DEF, editorDirty = false) {
  const qc = new QueryClient()
  const r = render(tree(def, editorDirty, qc))
  return { ...r, rerenderDef: (next: ProcessDefinition) => r.rerender(tree(next, editorDirty, qc)) }
}
const addStep = async () => fireEvent.click(await screen.findByTestId('edit-add'))
const save = () => fireEvent.click(screen.getByTestId('edit-save'))

describe('T-1563 diagram edit: save', () => {
  it('S1/S6 a DRAFT is saved with update(id, {graph}) and nothing else', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    vi.mocked(definitionsApi.update).mockResolvedValue(DEF)
    mount()
    expect(await screen.findByTestId('edit-save')).toBeDisabled() // nothing changed yet
    await addStep()
    save()
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
    const [id, body] = vi.mocked(definitionsApi.update).mock.calls[0]
    expect(id).toBe('def-1')
    expect(Object.keys(body)).toEqual(['graph'])
    expect(JSON.stringify(body)).not.toMatch(/tenant_id|status|variable_schemas/)
    expect((body as { graph: { nodes: unknown[] } }).graph.nodes).toHaveLength(3)
    await waitFor(() => expect(onSaved).toHaveBeenCalledWith(DEF, false))
    expect(definitionsApi.create).not.toHaveBeenCalled()
  })

  it('P3 edits made while a PATCH is pending are refused, not lost; the saved graph becomes the clean base', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    let resolve!: (d: ProcessDefinition) => void
    vi.mocked(definitionsApi.update).mockReturnValue(new Promise<ProcessDefinition>((r) => (resolve = r)))
    mount()
    await addStep()
    save()
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
    const sentNodes = (vi.mocked(definitionsApi.update).mock.calls[0][1] as { graph: { nodes: unknown[] } }).graph.nodes.length
    fireEvent.click(screen.getByTestId('edit-add')) // pending: refused
    resolve({ ...DEF, graph: { ...DEF.graph, nodes: [...DEF.graph.nodes, { id: 'n3', node_type: 'HUMAN_TASK', label: null, attributes: null }] } })
    await waitFor(() => expect(onSaved).toHaveBeenCalled())
    expect(sentNodes).toBe(3)
    await waitFor(() => expect(screen.getByTestId('edit-save')).toBeDisabled()) // clean: nothing newer than the saved graph was dropped silently
    expect(screen.getByTestId('edit-undo')).toBeDisabled()
  })

  it('P4 edits are also refused during the preliminary read of a DRAFT save', async () => {
    let resolveGet!: (d: ProcessDefinition) => void
    vi.mocked(definitionsApi.get).mockReturnValue(new Promise<ProcessDefinition>((r) => (resolveGet = r)))
    vi.mocked(definitionsApi.update).mockResolvedValue(DEF)
    mount()
    await addStep()
    save()
    fireEvent.click(screen.getByTestId('edit-add')) // pending GET: refused
    resolveGet(DEF)
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
    const body = vi.mocked(definitionsApi.update).mock.calls[0][1] as { graph: { nodes: unknown[] } }
    expect(body.graph.nodes).toHaveLength(3) // start, end, ONE added step
  })

  it('P5 edits made while a new-version save is pending are refused', async () => {
    let resolve!: (d: ProcessDefinition) => void
    vi.mocked(definitionsApi.create).mockReturnValue(new Promise<ProcessDefinition>((r) => (resolve = r)))
    mount({ ...DEF, status: 'ACTIVE' })
    await addStep()
    save()
    await waitFor(() => expect(definitionsApi.create).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByTestId('edit-add'))
    resolve({ ...DEF, id: 'def-2', version: '1.0.1' })
    await waitFor(() => expect(onSaved).toHaveBeenCalled())
    expect((vi.mocked(definitionsApi.create).mock.calls[0][0] as { graph: { nodes: unknown[] } }).graph.nodes).toHaveLength(3)
  })

  it('S2/S6 an ACTIVE definition is saved as a new draft with the next version and the variable-schema copy', async () => {
    vi.mocked(definitionsApi.create).mockResolvedValue({ ...DEF, id: 'def-2', version: '1.0.1' })
    mount({ ...DEF, status: 'ACTIVE' })
    expect(screen.getByTestId('edit-copy-note')).toHaveTextContent('1.0.1')
    await addStep()
    expect(screen.getByTestId('edit-save')).toHaveTextContent('Save as draft 1.0.1')
    save()
    await waitFor(() => expect(definitionsApi.create).toHaveBeenCalledTimes(1))
    const body = vi.mocked(definitionsApi.create).mock.calls[0][0]
    expect(Object.keys(body).sort()).toEqual(['copy_variable_schemas_from', 'description', 'graph', 'name', 'version'])
    expect(body).toMatchObject({ name: 'Order', version: '1.0.1', copy_variable_schemas_from: 'def-1' })
    expect(definitionsApi.update).not.toHaveBeenCalled()
    await waitFor(() => expect(onSaved).toHaveBeenCalledWith(expect.objectContaining({ id: 'def-2' }), true))
  })

  it('S3 not_draft shows the server message with Reload; module-owned disables Save; a taken version asks for another', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    vi.mocked(definitionsApi.update).mockRejectedValueOnce({ status: 409, message: 'only a DRAFT definition can be modified', code: 'conflict' })
    mount()
    await addStep()
    save()
    await screen.findByTestId('edit-error-not_draft')
    fireEvent.click(screen.getByTestId('edit-error-reload'))
    expect(onReload).toHaveBeenCalled()
    // the draft is kept
    expect(screen.getByTestId('edit-save')).not.toBeDisabled()

    vi.mocked(definitionsApi.update).mockRejectedValueOnce({ status: 409, message: 'a module-owned definition version cannot be modified', code: 'conflict' })
    save()
    await screen.findByTestId('edit-error-module')
    expect(screen.getByTestId('edit-save')).toBeDisabled()
    expect(screen.getByTestId('edit-save-reason')).toHaveTextContent('module-owned')
  })

  it('S3 duplicate version: the version field appears and the corrected version is sent', async () => {
    vi.mocked(definitionsApi.create).mockRejectedValueOnce({ status: 409, message: 'a definition with this name and version already exists', code: 'conflict' })
    mount({ ...DEF, status: 'ACTIVE' })
    await addStep()
    save()
    await screen.findByTestId('edit-error-duplicate')
    fireEvent.change(screen.getByTestId('edit-version-input'), { target: { value: '1.0.5' } })
    vi.mocked(definitionsApi.create).mockResolvedValueOnce({ ...DEF, id: 'def-3', version: '1.0.5' })
    save()
    await waitFor(() => expect(definitionsApi.create).toHaveBeenCalledTimes(2))
    expect(vi.mocked(definitionsApi.create).mock.calls[1][0].version).toBe('1.0.5')
  })

  it('S4 a changed updated_at asks first; "Save anyway" saves', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue({ ...DEF, updated_at: '2026-11-03T00:00:00Z' })
    vi.mocked(definitionsApi.update).mockResolvedValue(DEF)
    mount()
    await addStep()
    save()
    await screen.findByTestId('edit-stale')
    expect(definitionsApi.update).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('edit-stale-anyway'))
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
  })

  it('S7 a blocking violation disables Save with the reason; an advisory one does not', async () => {
    vi.mocked(definitionsApi.validate).mockRejectedValue({ status: 422, message: 'invalid', code: 'x', details: [{ code: 'missing_role', message: "Node 'start' (HUMAN_TASK) is missing a non-empty 'role' attribute." }] })
    mount()
    await addStep()
    await waitFor(() => expect(screen.getByTestId('edit-save-reason')).toHaveTextContent('Fix 1 error before saving.'), { timeout: 3000 })
    expect(screen.getByTestId('edit-save')).toBeDisabled()
    cleanup()

    vi.mocked(definitionsApi.validate).mockRejectedValue({ status: 422, message: 'invalid', code: 'x', details: [{ code: 'undeclared_variable_reference', message: "Edge 'e1' (from EXCLUSIVE_GATEWAY node 'start') condition x" }] })
    mount()
    await addStep()
    await waitFor(() => expect(screen.getByTestId('edit-check-status')).toHaveTextContent('1 problem'), { timeout: 3000 })
    expect(screen.getByTestId('edit-save')).not.toBeDisabled()
  })

  it('R2 a refetch with unsaved edits keeps the draft and asks; a clean draft follows the refetch', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    vi.mocked(definitionsApi.update).mockResolvedValue(DEF)
    const r = mount()
    await addStep()
    const remote = {
      ...DEF,
      updated_at: '2026-11-05T00:00:00Z',
      graph: { ...DEF.graph, nodes: [...DEF.graph.nodes, { id: 'remote', node_type: 'END' as const, label: null, attributes: { position: { x: 0, y: 200 } } }] },
    }
    r.rerenderDef(remote)
    await screen.findByTestId('edit-stale')
    expect(screen.getByTestId('edit-save')).not.toBeDisabled() // still dirty: the local work was not replaced
    fireEvent.click(screen.getByTestId('edit-stale-anyway'))
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
    const sent = (vi.mocked(definitionsApi.update).mock.calls[0][1] as { graph: { nodes: { id: string }[] } }).graph.nodes
    expect(sent).toHaveLength(3) // 2 stored + the added local step; the remote node was not merged in
    expect(sent.some((n) => n.id === 'remote')).toBe(false)
  })

  it('R2b a clean draft follows a refetch without asking', async () => {
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    vi.mocked(definitionsApi.update).mockResolvedValue(DEF)
    const r = mount()
    await screen.findByTestId('edit-add')
    r.rerenderDef({ ...DEF, updated_at: '2026-11-05T00:00:00Z', graph: { ...DEF.graph, nodes: [...DEF.graph.nodes, { id: 'remote', node_type: 'END', label: null, attributes: { position: { x: 0, y: 200 } } }] } })
    expect(screen.queryByTestId('edit-stale')).toBeNull()
    await addStep()
    vi.mocked(definitionsApi.get).mockResolvedValue({ ...DEF, updated_at: '2026-11-05T00:00:00Z' })
    save()
    await waitFor(() => expect(definitionsApi.update).toHaveBeenCalledTimes(1))
    expect((vi.mocked(definitionsApi.update).mock.calls[0][1] as { graph: { nodes: unknown[] } }).graph.nodes).toHaveLength(4)
  })

  it('R3 a save refused with a structured 422 shows its violations and keeps the draft, although the live check failed', async () => {
    vi.mocked(definitionsApi.validate).mockRejectedValue({ status: 500, message: 'down', code: 'x' }) // live check unavailable
    vi.mocked(definitionsApi.get).mockResolvedValue(DEF)
    vi.mocked(definitionsApi.update).mockRejectedValueOnce({
      status: 422,
      message: 'Invalid graph',
      code: 'unprocessable',
      details: [{ code: 'missing_role', message: "Node 'start' (HUMAN_TASK) is missing a non-empty 'role' attribute." }],
    })
    mount()
    await addStep()
    save()
    const list = await screen.findByTestId('edit-violations')
    expect(list).toHaveTextContent("Node 'start' (HUMAN_TASK) is missing a non-empty 'role' attribute.")
    expect(screen.getByTestId('edit-save')).toBeDisabled() // blocking code: fix first
    expect(screen.getByTestId('edit-save-reason')).toBeInTheDocument()
  })

  it('S7 the advisory set agrees with the shared fixture classification (the backend test B1b checks the flags against Definitions.create)', () => {
    const fx = JSON.parse(readFileSync(resolve(__dirname, '../../../../../test/fixtures/process_designer/validation_cases.json'), 'utf8')) as {
      cases: { name: string; blocking: boolean; codes: string[] }[]
    }
    const advisoryInFixture = new Set<string>()
    for (const c of fx.cases) {
      for (const code of c.codes) {
        const v = { code, message: '' }
        if (c.blocking) expect(isBlocking(v), `${c.name}:${code}`).toBe(true)
        else {
          expect(isBlocking(v) && c.codes.length > 0 && !ADVISORY_CODES.has(code), `${c.name}:${code}`).toBe(false)
          advisoryInFixture.add(code)
        }
      }
    }
    for (const code of advisoryInFixture) expect(ADVISORY_CODES.has(code)).toBe(true)
    // The two semantic-only codes added after the first review are covered by fixture cases and are advisory.
    for (const code of ['required_output_without_variable_schema', 'variable_never_collected']) {
      expect(advisoryInFixture.has(code), code).toBe(true)
      expect(isBlocking({ code, message: '' })).toBe(false)
    }
    expect(fx.cases.some((c) => c.blocking)).toBe(true)
  })

  it('S8 while the Editor has unsaved changes Save is off with the reason', async () => {
    mount(DEF, true)
    await addStep()
    expect(screen.getByTestId('edit-save')).toBeDisabled()
    expect(screen.getByTestId('edit-lock-editor')).toHaveTextContent('Editor has unsaved changes')
  })

  it('S8 Discard (after a confirm) resets the draft', async () => {
    mount()
    await addStep()
    expect(screen.getByTestId('edit-save')).not.toBeDisabled()
    fireEvent.click(screen.getByTestId('edit-discard'))
    fireEvent.click(within(screen.getByTestId('confirm-dialog')).getByRole('button', { name: 'Discard changes' }))
    expect(screen.getByTestId('edit-save')).toBeDisabled()
    expect(screen.queryByTestId('edit-undo')).toBeDisabled()
  })
})
