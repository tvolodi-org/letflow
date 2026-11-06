/** LayoutPicker — a radio group with one card per registered document layout, each with a live preview thumbnail.
 *  Rendered from the registry (docLayouts.ts), so a new layout appears here with its entry. Generic. */
import './layoutThumb.css'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { DOC_LAYOUTS, DOC_LAYOUT_NAMES, type DocLayoutName } from './docLayouts'

export interface LayoutPickerProps {
  value: DocLayoutName
  onChange: (layout: DocLayoutName) => void
  legend: string
  name: string
  disabled?: boolean
  'data-testid'?: string
}

/** The drawn preview of one layout (decorative: the card text names it). */
export function LayoutThumb({ layout }: { layout: DocLayoutName }) {
  return (
    <span className="lf-layout-thumb" data-layout={layout} aria-hidden="true" data-testid={`layout-thumb-${layout}`}>
      {layout === 'tabs' ? (
        <>
          <span />
          <span className="is-strip is-accent" />
          <span />
        </>
      ) : (
        <>
          <span />
          <span className="is-accent" />
          <span />
        </>
      )}
    </span>
  )
}

export function LayoutPicker({ value, onChange, legend, name, disabled, ...rest }: LayoutPickerProps) {
  const locale = useUiLocale()
  return (
    <fieldset className="lf-layout-picker" disabled={disabled} data-testid={rest['data-testid']}>
      <legend>{legend}</legend>
      <div className="lf-types" role="radiogroup" aria-label={legend}>
        {DOC_LAYOUT_NAMES.map((layout) => {
          const def = DOC_LAYOUTS[layout]
          return (
            <label key={layout} className="lf-type" data-testid={`layout-option-${layout}`}>
              <input type="radio" name={name} value={layout} checked={value === layout} onChange={() => onChange(layout)} />
              <LayoutThumb layout={layout} />
              <span className="lf-type__name">{def.label[locale]}</span>
              <span className="lf-type__hint">{def.hint[locale]}</span>
            </label>
          )
        })}
      </div>
    </fieldset>
  )
}
