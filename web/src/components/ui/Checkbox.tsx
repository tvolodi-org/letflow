/** Checkbox, Radio, Switch — one native input in a .lf-check label (NOTES.md section 2).
 *  Switch is a checkbox with role="switch" and the .lf-check--switch class. */
import React from 'react'

export interface CheckProps {
  label: React.ReactNode
  checked: boolean
  onChange: (checked: boolean) => void
  disabled?: boolean
  name?: string
  value?: string
  'data-testid'?: string
}

function Check(props: CheckProps & { type: 'checkbox' | 'radio'; role?: string; extraClass?: string }) {
  const { label, checked, onChange, disabled, name, value, type, role, extraClass } = props
  return (
    <label className={extraClass ? `lf-check ${extraClass}` : 'lf-check'}>
      <input
        type={type}
        role={role}
        name={name}
        value={value}
        checked={checked}
        disabled={disabled}
        data-testid={props['data-testid']}
        onChange={e => onChange(e.target.checked)}
      />
      <span>{label}</span>
    </label>
  )
}

export function Checkbox(props: CheckProps): React.ReactElement {
  return <Check {...props} type="checkbox" />
}

export function Radio(props: CheckProps): React.ReactElement {
  return <Check {...props} type="radio" />
}

export function Switch(props: CheckProps): React.ReactElement {
  return <Check {...props} type="checkbox" role="switch" extraClass="lf-check--switch" />
}
