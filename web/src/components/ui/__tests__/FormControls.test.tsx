// @vitest-environment jsdom
/** T-1165 — Field, Select, Checkbox, Radio, Switch, FormSection, FormActions: states and keyboard. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
expect.extend(jestDomMatchers)

import { Field } from '../Field'
import { Select } from '../Select'
import { Checkbox, Radio, Switch } from '../Checkbox'
import { FormSection, FormActions } from '../FormSection'

afterEach(cleanup)

describe('Field', () => {
  it('links the label to the input', () => {
    render(<Field label="Name"><input /></Field>)
    expect(screen.getByLabelText('Name')).toBeInTheDocument()
  })

  it('hint is described-by and shown', () => {
    render(<Field label="Code" hint="Set once"><input /></Field>)
    const input = screen.getByLabelText('Code')
    expect(input).toHaveAccessibleDescription('Set once')
    expect(input).not.toHaveAttribute('aria-invalid')
  })

  it('error sets aria-invalid, describedby and the error class; replaces the hint', () => {
    const { container } = render(<Field label="BIN" hint="h" error="Must be 12 digits"><input /></Field>)
    const input = screen.getByLabelText('BIN')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toHaveAccessibleDescription('Must be 12 digits')
    expect(container.querySelector('.lf-field')).toHaveClass('lf-field--error')
    expect(screen.queryByText('h')).toBeNull()
  })

  it('optional shows the localized word', () => {
    render(<Field label="Date" optional locale="ru"><input /></Field>)
    expect(screen.getByText('необязательно')).toHaveClass('lf-label__opt')
  })

  it('width, readOnly, mono, leadingIcon', () => {
    const { container } = render(
      <Field label="Code" width="s" readOnly mono leadingIcon={<svg data-testid="lead" />}><input /></Field>,
    )
    expect(container.querySelector('.lf-field')).toHaveClass('lf-field--s')
    const control = container.querySelector('.lf-control')!
    expect(control).toHaveClass('lf-control--readonly', 'lf-control--mono')
    expect(screen.getByLabelText('Code')).toHaveAttribute('readonly')
    expect(control.querySelector('.lf-control__lead')).toContainElement(screen.getByTestId('lead'))
  })

  it('disabled disables the control and marks the box', () => {
    const { container } = render(<Field label="X" disabled><input /></Field>)
    expect(screen.getByLabelText('X')).toBeDisabled()
    expect(container.querySelector('.lf-control')).toHaveAttribute('aria-disabled', 'true')
  })

  it('keyboard: typing reaches the input', async () => {
    const user = userEvent.setup()
    render(<Field label="Name"><input /></Field>)
    await user.tab()
    expect(screen.getByLabelText('Name')).toHaveFocus()
    await user.keyboard('abc')
    expect(screen.getByLabelText('Name')).toHaveValue('abc')
  })

  it('does not use inline styles', () => {
    const { container } = render(<Field label="X" error="e"><input /></Field>)
    expect(container.querySelector('[style]')).toBeNull()
  })
})

describe('Select', () => {
  const options = [
    { value: 'a', label: 'Alpha' },
    { value: 'b', label: 'Beta', disabled: true },
    { value: 'c', label: 'Gamma' },
  ]

  it('renders options, placeholder and chevron; reports change', () => {
    const onChange = vi.fn()
    const { container } = render(<Select label="Kind" options={options} value="" placeholder="Choose" onChange={onChange} />)
    const sel = screen.getByLabelText('Kind')
    expect(screen.getAllByRole('option')).toHaveLength(4)
    expect(container.querySelector('.lf-control__chev')).not.toBeNull()
    fireEvent.change(sel, { target: { value: 'c' } })
    expect(onChange).toHaveBeenCalledWith('c')
  })

  it('keyboard: selectOptions through the user API', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Select label="Kind" options={options} value="a" onChange={onChange} />)
    await user.tab()
    expect(screen.getByLabelText('Kind')).toHaveFocus()
    await user.selectOptions(screen.getByLabelText('Kind'), 'c')
    expect(onChange).toHaveBeenCalledWith('c')
  })

  it('error and disabled states', () => {
    render(<Select label="Kind" options={options} value="a" onChange={() => {}} error="Required" disabled />)
    const sel = screen.getByLabelText('Kind')
    expect(sel).toBeDisabled()
    expect(sel).toHaveAttribute('aria-invalid', 'true')
    expect(sel).toHaveAccessibleDescription('Required')
  })
})

describe('Checkbox, Radio, Switch', () => {
  it('Checkbox: checked state, space toggles, onChange value', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Checkbox label="Show retired" checked={false} onChange={onChange} />)
    const box = screen.getByRole('checkbox', { name: 'Show retired' })
    expect(box).not.toBeChecked()
    await user.tab()
    expect(box).toHaveFocus()
    await user.keyboard(' ')
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('Checkbox: checked and disabled', () => {
    render(<Checkbox label="A" checked onChange={() => {}} disabled />)
    const box = screen.getByRole('checkbox', { name: 'A' })
    expect(box).toBeChecked()
    expect(box).toBeDisabled()
  })

  it('Radio: shares a name, click selects, disabled blocks', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(
      <>
        <Radio label="By unit" name="r" checked onChange={() => {}} />
        <Radio label="By place" name="r" checked={false} onChange={onChange} />
        <Radio label="Off" name="r" checked={false} onChange={onChange} disabled />
      </>,
    )
    expect(screen.getByRole('radio', { name: 'By unit' })).toBeChecked()
    await user.click(screen.getByRole('radio', { name: 'By place' }))
    expect(onChange).toHaveBeenCalledWith(true)
    await user.click(screen.getByRole('radio', { name: 'Off' }))
    expect(onChange).toHaveBeenCalledTimes(1)
  })

  it('Switch: role switch, switch class, space toggles', async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    const { container } = render(<Switch label="Compact rows" checked={false} onChange={onChange} />)
    const sw = screen.getByRole('switch', { name: 'Compact rows' })
    expect(container.querySelector('label')).toHaveClass('lf-check', 'lf-check--switch')
    await user.tab()
    await user.keyboard(' ')
    expect(onChange).toHaveBeenCalledWith(true)
    expect(sw).not.toBeChecked()
  })

  it('Switch: checked and disabled', () => {
    render(<Switch label="S" checked onChange={() => {}} disabled />)
    const sw = screen.getByRole('switch', { name: 'S' })
    expect(sw).toBeChecked()
    expect(sw).toBeDisabled()
  })
})

describe('FormSection and FormActions', () => {
  it('FormSection renders its title and children', () => {
    render(<FormSection title="Identity"><p>body</p></FormSection>)
    expect(screen.getByRole('heading', { name: 'Identity' })).toHaveClass('lf-form__title')
    expect(screen.getByText('body')).toBeInTheDocument()
  })

  it('FormActions: dirty hint, clean hint, none, saving', () => {
    const { rerender } = render(<FormActions primary={<button>Save</button>} dirty locale="en" />)
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent('Unsaved changes')
    rerender(<FormActions primary={<button>Save</button>} dirty={false} locale="en" />)
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent('No unsaved changes')
    rerender(<FormActions primary={<button>Save</button>} dirty saving locale="kk" />)
    expect(screen.getByTestId('form-actions-hint')).toHaveTextContent('Сақталуда…')
    rerender(<FormActions primary={<button>Save</button>} locale="en" />)
    expect(screen.queryByTestId('form-actions-hint')).toBeNull()
  })

  it('FormActions: primary comes before secondary in tab order', async () => {
    const user = userEvent.setup()
    render(<FormActions primary={<button>Save</button>} secondary={<button>Cancel</button>} dirty />)
    await user.tab()
    expect(screen.getByText('Save')).toHaveFocus()
    await user.tab()
    expect(screen.getByText('Cancel')).toHaveFocus()
  })
})
