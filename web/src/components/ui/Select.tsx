/** Select — native <select> inside Field (NOTES.md section 2). Long option text is cut with an
 *  ellipsis by components.css. Same props and states as Field. */
import React from 'react'
import { ChevronDown } from 'lucide-react'
import { Field, type FieldProps } from './Field'

export interface SelectOption {
  value: string
  label: string
  disabled?: boolean
}

export interface SelectProps extends Omit<FieldProps, 'children' | 'trailing' | 'leadingIcon' | 'mono'> {
  options: SelectOption[]
  value: string
  onChange: (value: string) => void
  /** Shown as a first, empty-valued option. */
  placeholder?: string
  name?: string
}

export function Select(props: SelectProps): React.ReactElement {
  const { options, value, onChange, placeholder, name, ...field } = props
  return (
    <Field {...field} trailing={<ChevronDown className="lf-icon lf-control__chev" aria-hidden="true" />}>
      <select name={name} value={value} onChange={e => onChange(e.target.value)}>
        {placeholder !== undefined && <option value="">{placeholder}</option>}
        {options.map(o => (
          <option key={o.value} value={o.value} disabled={o.disabled}>
            {o.label}
          </option>
        ))}
      </select>
    </Field>
  )
}
