// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { OnNodesChange, OnEdgesChange } from '@xyflow/react'
import ProcessCanvas from './ProcessCanvas'

vi.mock('@xyflow/react', async () => {
  const actual = await vi.importActual<typeof import('@xyflow/react')>('@xyflow/react')
  return {
    ...actual,
    useReactFlow: () => ({ fitView: vi.fn() }),
    ReactFlow: ({ onNodesChange, onEdgesChange }: { onNodesChange: OnNodesChange; onEdgesChange: OnEdgesChange }) => (
      <>
        <button onClick={() => onNodesChange([{ id: 'start', type: 'dimensions', dimensions: { width: 48, height: 48 } }])}>measure</button>
        <button onClick={() => onNodesChange([{ id: 'start', type: 'select', selected: true }])}>select node</button>
        <button onClick={() => onNodesChange([{ id: 'start', type: 'position', position: { x: 20, y: 30 } }])}>move</button>
        <button onClick={() => onNodesChange([{ id: 'start', type: 'remove' }])}>remove node</button>
        <button onClick={() => onEdgesChange([{ id: 'e1', type: 'select', selected: true }])}>select edge</button>
        <button onClick={() => onEdgesChange([{ id: 'e1', type: 'remove' }])}>remove edge</button>
      </>
    ),
  }
})

afterEach(cleanup)

function setup() {
  const dirty = vi.fn()
  render(<ProcessCanvas
    definitionId="test" initialNodes={[{ id: 'start', position: { x: 0, y: 0 }, data: { nodeType: 'START', name: 'Start', attributes: {} } }]}
    initialEdges={[{ id: 'e1', source: 'start', target: 'end' }]}
    isReadOnly={false} onDirtyChange={dirty} canvasStateRef={{ current: null }}
    onSelectedNodeChange={() => {}} onSelectedEdgeChange={() => {}}
  />)
  return dirty
}

describe('T2012 canvas changes', () => {
  it('measurement and selection leave a pristine draft clean', () => {
    const dirty = setup()
    for (const name of ['measure', 'select node', 'select edge']) fireEvent.click(screen.getByText(name))
    expect(dirty).not.toHaveBeenCalled()
  })
  it.each(['move', 'remove node', 'remove edge'])('%s marks a real edit dirty', name => {
    const dirty = setup()
    fireEvent.click(screen.getByText(name))
    expect(dirty).toHaveBeenCalledWith(true)
  })
})
