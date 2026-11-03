/** TypePicker — radio group of cards (checked, hover, focus come from .lf-type). */
import type { LucideIcon } from 'lucide-react'

export interface TypeOption {
  id: string
  label: string
  icon?: LucideIcon
}

export interface TypePickerProps {
  types: TypeOption[]
  value: string | null
  onChange: (id: string) => void
  /** Accessible name of the group. */
  label: string
  name?: string
}

export function TypePicker({ types, value, onChange, label, name = 'type-picker' }: TypePickerProps) {
  return (
    <div className="lf-types" role="radiogroup" aria-label={label} data-testid="type-picker">
      {types.map((t) => {
        const Icon = t.icon
        return (
          <label key={t.id} className="lf-type">
            <input
              type="radio"
              name={name}
              value={t.id}
              checked={value === t.id}
              onChange={() => onChange(t.id)}
            />
            {Icon != null && <Icon className="lf-icon" aria-hidden="true" />}
            <span className="lf-type__name">{t.label}</span>
            <span className="lf-type__id">{t.id}</span>
          </label>
        )
      })}
    </div>
  )
}
