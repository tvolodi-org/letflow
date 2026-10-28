// @vitest-environment jsdom
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { PrintLayoutPreview } from '../PrintLayoutPreview'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

const LAYOUT = {
  layout_schema_version: 1,
  blocks: [
    { type: 'page', size: 'A4' },
    { type: 'text', text: 'Invoice header' },
    { type: 'field', entity_type: 'invoice', field_name: 'total', label: 'Total' },
    { type: 'field', entity_type: 'invoice', field_name: 'note', label: 'Note', show_if_nonempty: true },
    {
      type: 'table',
      entity_type: 'line',
      columns: [
        { field_name: 'sku', header: 'SKU', width: 10 },
        { field_name: 'qty', header: 'Qty', width: 5 },
      ],
    },
    { type: 'spacer', height_mm: 10 },
  ],
}

describe('REQ-614 V1/V2 preview rendering', () => {
  it('V1 draws every block type', () => {
    render(<PrintLayoutPreview layout={LAYOUT} />)
    expect(screen.getByText('Invoice header')).toBeInTheDocument()
    expect(screen.getByText(/Total: \[invoice\.total\]/)).toBeInTheDocument()
    expect(screen.getAllByTestId('preview-hidden-marker')).toHaveLength(1)
    const table = screen.getByTestId('preview-table')
    expect(within(table).getAllByRole('columnheader').map((h) => h.textContent)).toEqual(['SKU', 'Qty'])
    expect(within(table).getAllByRole('row')).toHaveLength(4)
    expect(within(table).getAllByText('[line.sku]')).toHaveLength(3)
    expect(screen.getByTestId('preview-spacer')).toBeInTheDocument()
  })

  it('V2 shows script text as text', () => {
    const { container } = render(
      <PrintLayoutPreview layout={{ blocks: [{ type: 'text', text: '<script>alert(1)</script>' }] }} />,
    )
    expect(screen.getByText('<script>alert(1)</script>')).toBeInTheDocument()
    expect(container.querySelector('script')).toBeNull()
  })
})

describe('REQ-614 V3/V4 no data, no throw', () => {
  it('V3 makes no request', () => {
    const fetchSpy = vi.spyOn(window, 'fetch').mockImplementation(() => {
      throw new Error('fetch called')
    })
    render(<PrintLayoutPreview layout={LAYOUT} />)
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it.each([
    ['unknown type', { blocks: [{ type: 'image' }] }, /Unsupported block \(index 0\)/],
    ['no blocks', { foo: 1 }, /cannot be previewed/],
    ['null', null, /cannot be previewed/],
    ['number', 5, /cannot be previewed/],
    ['string', 'x', /cannot be previewed/],
    ['array', [], /cannot be previewed/],
    ['malformed block', { blocks: [null, 3, { type: 'text', text: 7 }] }, /Unsupported block \(index 0\)/],
  ])('V4 %s renders a notice', (_n, layout, re) => {
    render(<PrintLayoutPreview layout={layout} />)
    expect(screen.getAllByTestId('preview-notice')[0].textContent).toMatch(re)
  })
})
