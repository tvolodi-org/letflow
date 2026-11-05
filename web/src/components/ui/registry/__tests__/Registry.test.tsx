// @vitest-environment jsdom
/** A5 / A8 — T-1402: the generic registry: layouts registry, tabs layout, in-pane create / edit form. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { Registry, RegistryForm, RegistrySection, DEFAULT_REGISTRY_LAYOUT, REGISTRY_LAYOUTS, isRegistryLayout, type RegistryFormLabels } from '..'

expect.extend(jestDomMatchers)
afterEach(cleanup)

describe('A8 layouts registry', () => {
  it('split is the default and both layouts are registered', () => {
    expect(DEFAULT_REGISTRY_LAYOUT).toBe('split')
    expect(Object.keys(REGISTRY_LAYOUTS)).toEqual(['split', 'tabs'])
    expect(isRegistryLayout('tabs')).toBe(true)
    expect(isRegistryLayout('grid')).toBe(false)
  })

  it('split: no tablist; tabs: tablist with arrows, Home, End and data-tab selecting the section', () => {
    const sections = (
      <>
        <RegistrySection pane="overview" id="o" title="Overview">x</RegistrySection>
        <RegistrySection pane="related" id="r" title="Related">y</RegistrySection>
        <RegistrySection pane="history" id="h" title="History">z</RegistrySection>
      </>
    )
    const tabs = [{ id: 'overview', label: 'Overview' }, { id: 'related', label: 'Related' }, { id: 'history', label: 'History' }]
    const { rerender } = render(<Registry list={<div />} details={sections} detailOpen sectionTabs={tabs} />)
    expect(screen.queryByRole('tablist')).not.toBeInTheDocument()
    expect(screen.getByTestId('registry')).not.toHaveAttribute('data-tab')
    rerender(<Registry layout="tabs" list={<div />} details={sections} detailOpen sectionTabs={tabs} />)
    expect(screen.getByRole('tablist')).toBeInTheDocument()
    expect(screen.getByTestId('registry')).toHaveAttribute('data-tab', 'overview')
    const first = screen.getByRole('tab', { name: 'Overview' })
    fireEvent.keyDown(first, { key: 'ArrowRight' })
    expect(screen.getByTestId('registry')).toHaveAttribute('data-tab', 'related')
    fireEvent.keyDown(screen.getByRole('tab', { name: 'Related' }), { key: 'End' })
    expect(screen.getByTestId('registry')).toHaveAttribute('data-tab', 'history')
    fireEvent.keyDown(screen.getByRole('tab', { name: 'History' }), { key: 'Home' })
    expect(screen.getByTestId('registry')).toHaveAttribute('data-tab', 'overview')
  })

  it('Escape closes the open record', () => {
    const onClose = vi.fn()
    render(<Registry list={<button type="button">row</button>} details={<div />} detailOpen onClose={onClose} />)
    fireEvent.keyDown(screen.getByText('row'), { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

const LABELS: RegistryFormLabels = {
  save: 'Save', create: 'Create', cancel: 'Cancel', unsaved: 'Unsaved',
  summary: (n) => `${n} fields need attention`,
  required: (f) => `${f}: required`,
}
const FIELDS = [
  { key: 'code', label: 'Code', kind: 'mono' as const, required: true, readOnly: true },
  { key: 'name', label: 'Title', kind: 'text' as const, required: true },
  { key: 'kind', label: 'Kind', kind: 'select' as const, options: [{ value: 'a', label: 'A' }] },
  { key: 'from', label: 'Valid from', kind: 'date' as const },
]

function mount(inside: boolean, props: Partial<React.ComponentProps<typeof RegistryForm>> = {}) {
  const onSave = vi.fn(async () => undefined)
  const onCancel = vi.fn()
  render(
    <Registry
      list={<div />}
      detailOpen
      details={<RegistryForm fields={FIELDS} initial={{ code: 'X1', name: 'Old', kind: '', from: '' }} creating={inside} labels={LABELS} onSave={onSave} onCancel={onCancel} {...props} />}
    />,
  )
  return { onSave, onCancel }
}

describe('A5 in-pane form', () => {
  it('edit renders inside the details pane, not in a dialog; the code is read only', () => {
    mount(false)
    expect(screen.getByTestId('registry-details')).toContainElement(screen.getByTestId('registry-form'))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByLabelText(/Code/)).toHaveAttribute('readonly')
    expect(screen.getByTestId('registry-save')).toHaveTextContent('Save')
  })

  it('create shows Create and an editable code', () => {
    mount(true)
    expect(screen.getByTestId('registry-save')).toHaveTextContent('Create')
    expect(screen.getByLabelText(/Code/)).not.toHaveAttribute('readonly')
  })

  it('an empty required field blocks the save, names the field and counts in the banner', async () => {
    const { onSave } = mount(false)
    fireEvent.change(screen.getByLabelText(/Title/), { target: { value: '' } })
    fireEvent.click(screen.getByTestId('registry-save'))
    expect(await screen.findByText('Title: required')).toBeInTheDocument()
    expect(screen.getByText('1 fields need attention')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('saves the typed values and shows the server error next to its field', async () => {
    const onSave = vi.fn(async () => ({ name: 'Title: already used' }))
    mount(false, { onSave })
    fireEvent.change(screen.getByLabelText(/Title/), { target: { value: 'New' } })
    expect(screen.getByText('Unsaved')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('registry-save'))
    await waitFor(() => expect(onSave).toHaveBeenCalledWith({ code: 'X1', name: 'New', kind: '', from: '' }))
    expect(await screen.findByText('Title: already used')).toBeInTheDocument()
  })

  it('Cancel calls onCancel; the date field is the lf-date component', () => {
    const { onCancel } = mount(false)
    fireEvent.click(screen.getByTestId('registry-cancel'))
    expect(onCancel).toHaveBeenCalled()
    expect(document.querySelector('.lf-date')).not.toBeNull()
  })
})
