// @vitest-environment jsdom
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { PrintLayoutEditor } from '../PrintLayoutEditor'
expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

function fill(typeKey: string, layoutText?: string) {
  fireEvent.change(screen.getByTestId('editor-type-key'), { target: { value: typeKey } })
  if (layoutText !== undefined) fireEvent.change(screen.getByTestId('editor-layout'), { target: { value: layoutText } })
}

describe('REQ-614 editor', () => {
  it('E1 invalid JSON shows an alert and does not save', () => {
    const onSave = vi.fn()
    const fetchSpy = vi.spyOn(window, 'fetch')
    render(<PrintLayoutEditor onSave={onSave} />)
    fill('invoice', '{"blocks": [oops')
    expect(screen.getByTestId('editor-json-error').textContent).toBe('Layout is not valid JSON')
    fireEvent.click(screen.getByTestId('editor-save'))
    expect(onSave).not.toHaveBeenCalled()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('E1 a non-object layout is refused', () => {
    const onSave = vi.fn()
    render(<PrintLayoutEditor onSave={onSave} />)
    fill('invoice', '[1]')
    expect(screen.getByTestId('editor-json-error').textContent).toBe('Layout must be a JSON object')
    fireEvent.click(screen.getByTestId('editor-save'))
    expect(onSave).not.toHaveBeenCalled()
  })

  it.each(['ru', 'kk', 'default'])('E2 saves exactly three keys for locale %s', (locale) => {
    const onSave = vi.fn()
    render(<PrintLayoutEditor onSave={onSave} />)
    fill('invoice', '{"layout_schema_version":1,"blocks":[]}')
    fireEvent.change(screen.getByTestId('editor-locale'), { target: { value: locale } })
    fireEvent.click(screen.getByTestId('editor-save'))
    expect(onSave).toHaveBeenCalledWith({ type_key: 'invoice', locale, layout: { layout_schema_version: 1, blocks: [] } })
    expect(Object.keys(onSave.mock.calls[0][0]).sort()).toEqual(['layout', 'locale', 'type_key'])
  })

  it('E3 locale options are ru, kk, default', () => {
    render(<PrintLayoutEditor onSave={vi.fn()} />)
    const opts = within(screen.getByTestId('editor-locale')).getAllByRole('option').map((o) => o.textContent)
    expect(opts).toEqual(['ru', 'kk', 'default'])
  })

  it('empty type key sends nothing', () => {
    const onSave = vi.fn()
    render(<PrintLayoutEditor onSave={onSave} />)
    fireEvent.click(screen.getByTestId('editor-save'))
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Type key is required')).toBeInTheDocument()
  })

  it('preview keeps the last valid layout while the text is invalid', () => {
    render(<PrintLayoutEditor onSave={vi.fn()} />)
    fill('t', '{"blocks":[{"type":"text","text":"Hello"}]}')
    expect(screen.getByText('Hello')).toBeInTheDocument()
    fill('t', '{"blocks":')
    expect(screen.getByText('Hello')).toBeInTheDocument()
  })
})
