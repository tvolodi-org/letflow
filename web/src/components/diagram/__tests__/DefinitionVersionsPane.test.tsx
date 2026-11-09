// @vitest-environment jsdom
/** T-1588 versions pane: V1 list, V2 compare on one diagram, V5 read only, V6 loading, V7 error + retry, V8 one
 *  version, V9 truncation banner, V10 same version selected, V11 no foreign definitions. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import fs from 'node:fs'
import path from 'node:path'
import type { DefinitionGraph, ProcessDefinition } from '@/types/api'
expect.extend(jestDomMatchers)

vi.mock('../ProcessDiagramLazy', () => ({
  ProcessDiagramLazy: ({ graph, diff }: { graph: DefinitionGraph; diff?: { nodes: Map<string, { kind: string }> } }) => (
    <div data-testid="process-diagram">
      {graph.nodes.map((n) => (
        <span key={n.id} data-testid="stub-node" data-kind={diff?.nodes.get(n.id)?.kind}>
          {n.id}
        </span>
      ))}
    </div>
  ),
}))
vi.mock('@/hooks/useDefinitions', () => ({ useDefinitionVersions: vi.fn() }))

import { useDefinitionVersions } from '@/hooks/useDefinitions'
import { DefinitionVersionsPane } from '../DefinitionVersionsPane'
import { ProcessDiagramIntlProvider } from '../ProcessDiagramIntlProvider'

const graph = (...ids: string[]): DefinitionGraph => ({
  nodes: ids.map((id) => ({ id, node_type: 'HUMAN_TASK', label: id, attributes: null })),
  edges: [],
})
const ver = (id: string, version: string, ids: string[], name = 'approval'): ProcessDefinition =>
  ({
    id,
    name,
    version,
    status: 'ACTIVE',
    graph: graph(...ids),
    created_by: '12345678-aaaa-bbbb-cccc-1234567890ab',
    created_at: '2026-11-01T10:00:00Z',
    updated_at: '2026-11-01T10:00:00Z',
  }) as ProcessDefinition

const V3 = ver('d3', '3', ['a', 'c'])
const V2 = ver('d2', '2', ['a', 'b'])
const V1 = ver('d1', '1', ['a'])

function arrange(partial: Record<string, unknown>) {
  vi.mocked(useDefinitionVersions).mockReturnValue({ isLoading: false, isError: false, error: null, refetch: vi.fn(), data: undefined, ...partial } as unknown as ReturnType<typeof useDefinitionVersions>)
}
function show(def = V3) {
  return render(
    <ProcessDiagramIntlProvider>
      <DefinitionVersionsPane def={def} />
    </ProcessDiagramIntlProvider>,
  )
}
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('DefinitionVersionsPane', () => {
  it('V1 lists version, status, who and when, newest first, with the viewed version marked', () => {
    arrange({ data: { items: [V3, V2, V1], next_cursor: null } })
    show()
    const rows = screen.getAllByTestId('versions-row')
    expect(rows.map((r) => r.getAttribute('data-definition-id'))).toEqual(['d3', 'd2', 'd1'])
    expect(within(rows[0]).getByTestId('versions-current')).toHaveTextContent('Current')
    expect(within(rows[1]).queryByTestId('versions-current')).toBeNull()
    expect(rows[0]).toHaveTextContent('12345678')
    expect(rows[0]).toHaveTextContent('ACTIVE')
    expect(screen.getAllByRole('columnheader').map((c) => c.textContent)).toEqual(['Version', 'Status', 'Created by', 'Created', ''])
  })

  it('V2 compares the viewed version with the next older one on ONE diagram and follows the selects', async () => {
    const user = userEvent.setup()
    arrange({ data: { items: [V3, V2, V1], next_cursor: null } })
    show()
    expect(screen.getAllByTestId('process-diagram')).toHaveLength(1)
    const kinds = () => Object.fromEntries(screen.getAllByTestId('stub-node').map((n) => [n.textContent, n.getAttribute('data-kind')]))
    expect(kinds()).toEqual({ a: 'unchanged', c: 'added', b: 'removed' })
    expect(screen.getByTestId('versions-summary')).toHaveTextContent('Steps: 1 added, 1 removed, 0 changed')
    await user.selectOptions(screen.getByLabelText('Base version'), 'd1')
    expect(kinds()).toEqual({ a: 'unchanged', c: 'added' })
    await user.click(within(screen.getAllByTestId('versions-row')[1]).getByTestId('versions-set-base'))
    expect(kinds()).toEqual({ a: 'unchanged', c: 'added', b: 'removed' })
    expect(screen.getByTestId('versions-legend')).toHaveTextContent('AddedRemovedChanged')
  })

  it('V2 identical versions give a message, not a changed picture', () => {
    arrange({ data: { items: [V3, ver('d2', '2', ['a', 'c'])], next_cursor: null } })
    show()
    expect(screen.getByTestId('versions-summary')).toHaveTextContent('No differences between 2 and 3')
  })

  it('V5 is read only: no restore or rollback control and no mutation import', () => {
    arrange({ data: { items: [V3, V2], next_cursor: null } })
    show()
    expect(screen.queryByRole('button', { name: /restore|rollback|roll back/i })).toBeNull()
    const src = fs.readFileSync(path.resolve(process.cwd(), 'src/components/diagram/DefinitionVersionsPane.tsx'), 'utf8')
    expect(src).not.toMatch(/useRollback|useActivate|useMutation|useCreateDefinition|definitionsApi/)
  })

  it('V6 shows a loading state', () => {
    arrange({ isLoading: true })
    show()
    expect(screen.queryByTestId('versions-table')).toBeNull()
  })

  it('V7 shows the error with a retry that refetches', async () => {
    const refetch = vi.fn()
    arrange({ isError: true, error: new Error('boom'), refetch })
    show()
    await userEvent.setup().click(screen.getByRole('button', { name: /retry/i }))
    expect(refetch).toHaveBeenCalled()
  })

  it('V8 a single version says there is nothing to compare', () => {
    arrange({ data: { items: [V1], next_cursor: null } })
    show(V1)
    expect(screen.getByTestId('versions-only-one')).toBeInTheDocument()
    expect(screen.queryByTestId('process-diagram')).toBeNull()
  })

  it('V9 a cursor left over shows the truncation banner', () => {
    arrange({ data: { items: [V3, V2], next_cursor: 'more' } })
    show()
    expect(screen.getByText(/latest versions only/i)).toBeInTheDocument()
  })

  it('V10 choosing the same version twice asks for two different ones', async () => {
    arrange({ data: { items: [V3, V2], next_cursor: null } })
    show()
    await userEvent.setup().selectOptions(screen.getByLabelText('Base version'), 'd3')
    expect(screen.getByText('Choose two different versions.')).toBeInTheDocument()
    expect(screen.queryByTestId('process-diagram')).toBeNull()
  })

  it('V11 only this definition appears in the table and the selects', () => {
    arrange({ data: { items: [V3, V2], next_cursor: null } })
    show()
    expect(screen.queryByText(/purchase-approval/)).toBeNull()
    expect(within(screen.getByLabelText('Compare version')).getAllByRole('option')).toHaveLength(2)
  })
})
