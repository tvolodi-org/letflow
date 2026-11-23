// @vitest-environment jsdom
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import PropertyPanel from './PropertyPanel'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'
import type { NodeType } from '@/types/api'

expect.extend(jestDomMatchers)

afterEach(cleanup)

function nodeData(nodeType: NodeType, attributes: Record<string, unknown> = {}): CanvasNodeData {
  return { nodeType, name: '', attributes }
}

function setup(nodeType: NodeType, attributes: Record<string, unknown> = {}) {
  const onUpdate = vi.fn()
  const view = render(
    <PropertyPanel
      selectedNodeId="n1"
      selectedNodeData={nodeData(nodeType, attributes)}
      selectedEdgeId={null}
      onUpdateNode={onUpdate}
      onDeleteEdge={() => {}}
      onClose={() => {}}
      isReadOnly={false}
      nodeNames={new Map()}
    />,
  )
  return { onUpdate, view }
}

/** The attributes of the node as the panel handed them back. */
function writtenAttributes(onUpdate: ReturnType<typeof vi.fn>): Record<string, unknown> {
  const call = onUpdate.mock.calls.at(-1)
  expect(call, 'the panel wrote nothing').toBeDefined()
  return (call?.[1] as { attributes?: Record<string, unknown> }).attributes ?? {}
}

describe('T-2601 the old canvas property panel has no dead field', () => {
  it.each<NodeType>(['HUMAN_TASK', 'SERVICE_TASK', 'TIMER', 'SUB_PROCESS'])(
    '%s: every control of the panel saves something',
    (nodeType) => {
      // A service node with a script key, so its version field is enabled (the
      // version belongs to the key).
      const { onUpdate, view } = setup(
        nodeType,
        nodeType === 'SERVICE_TASK' ? { script_key: 'tenant.register', script_version: 1 } : {},
      )
      const controls = Array.from(view.container.querySelectorAll('input, select, textarea'))
      expect(controls.length, 'the panel rendered no control at all').toBeGreaterThan(0)
      for (const control of controls) {
        onUpdate.mockClear()
        const testid = control.getAttribute('data-testid') ?? control.tagName
        // A select only reports a change when its value really changes, so it
        // gets an option of its own; the other controls get a JSON object, which
        // every field of the panel accepts (the two JSON fields parse it).
        const value = control.tagName === 'SELECT' ? 'ROLE' : '{"probe":true}'
        fireEvent.change(control, { target: { value } })
        expect(onUpdate, `the control "${testid}" saved nothing`).toHaveBeenCalled()
      }
    },
  )

  it('has no field for an attribute the graph model does not have', () => {
    const { view: service } = setup('SERVICE_TASK')
    expect(service.container.querySelector('[data-testid="prop-service-type"]')).toBeNull()
    expect(service.container.querySelector('[data-testid="prop-service-config"]')).toBeNull()
    const { view: timer } = setup('TIMER')
    expect(timer.container.querySelector('[data-testid="prop-timer-type"]')).toBeNull()
  })

  it('TIMER: the duration writes the duration_iso8601 attribute', () => {
    const { onUpdate } = setup('TIMER')
    fireEvent.change(document.querySelector('[data-testid="prop-timer-duration"]')!, {
      target: { value: 'PT15M' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ duration_iso8601: 'PT15M' })
  })

  it('TIMER: the duration of the node is shown', () => {
    const { view } = setup('TIMER', { duration_iso8601: 'PT2H' })
    expect(view.container.querySelector('[data-testid="prop-timer-duration"]')).toHaveValue('PT2H')
  })

  it('SERVICE_TASK: the script key writes the script_key attribute with its version', () => {
    const { onUpdate } = setup('SERVICE_TASK')
    fireEvent.change(document.querySelector('[data-testid="prop-service-script-key"]')!, {
      target: { value: 'tenant.register' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ script_key: 'tenant.register', script_version: 1 })
  })

  it('SERVICE_TASK: the script version writes the script_version attribute', () => {
    const { onUpdate } = setup('SERVICE_TASK', { script_key: 'tenant.register', script_version: 1 })
    fireEvent.change(document.querySelector('[data-testid="prop-service-script-version"]')!, {
      target: { value: '3' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ script_key: 'tenant.register', script_version: 3 })
  })

  it('SERVICE_TASK: a bound service is shown, not edited', () => {
    const { view } = setup('SERVICE_TASK', { service_id: 'budget-api' })
    expect(view.container.querySelector('[data-testid="prop-service-bound"]')).toHaveTextContent('budget-api')
    expect(view.container.querySelector('[data-testid="prop-service-script-key"]')).toHaveValue('')
  })

  it('HUMAN_TASK: the assignee type writes the assignee_type attribute', () => {
    const { onUpdate } = setup('HUMAN_TASK')
    fireEvent.change(document.querySelector('[data-testid="prop-assignee-type"]')!, {
      target: { value: 'USER' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ assignee_type: 'USER' })
  })

  it('HUMAN_TASK: the assignee reference writes the role attribute', () => {
    const { onUpdate } = setup('HUMAN_TASK')
    fireEvent.change(document.querySelector('[data-testid="prop-assignee-ref"]')!, {
      target: { value: 'HEAD_OF_UNIT' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ role: 'HEAD_OF_UNIT' })
  })

  it('HUMAN_TASK: the form schema writes the parsed JSON object', () => {
    const { onUpdate } = setup('HUMAN_TASK')
    fireEvent.change(document.querySelector('[data-testid="prop-form-schema"]')!, {
      target: { value: '{"properties":{"item":{"title":"Item"}}}' },
    })
    expect(writtenAttributes(onUpdate)).toEqual({ form_schema: { properties: { item: { title: 'Item' } } } })
  })

  it('HUMAN_TASK: a malformed form schema is not written', () => {
    const { onUpdate } = setup('HUMAN_TASK')
    fireEvent.change(document.querySelector('[data-testid="prop-form-schema"]')!, {
      target: { value: '{not json' },
    })
    expect(onUpdate).not.toHaveBeenCalled()
    expect(document.querySelector('[data-testid="prop-form-schema-status"]')).toHaveTextContent(
      'Form schema is not valid JSON',
    )
  })
})
