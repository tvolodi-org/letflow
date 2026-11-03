/** Tally — count boxes for an import check or result (README "Import wizard").
 *  A `danger` item (refused) gets the danger box; with a `glyph` the label
 *  carries the shape as well, so the state is never colour alone.
 */

import React from 'react'
import { glyphClass, type StatusGlyph, type StatusTone } from './StatusPill'

export interface TallyItem {
  label: string
  value: number | string
  tone?: StatusTone
  glyph?: StatusGlyph
}

export interface TallyProps {
  items: TallyItem[]
  'aria-label'?: string
}

export function Tally(props: TallyProps): React.ReactElement {
  return (
    <div className="lf-tally" role="group" aria-label={props['aria-label']} data-testid="tally">
      {props.items.map((item) => (
        <div
          key={item.label}
          className={`lf-tally__item${item.tone === 'danger' ? ' lf-tally__item--danger' : ''}`}
          data-testid="tally-item"
        >
          <span className="lf-tally__num">{item.value}</span>
          <span className="lf-tally__label">
            {item.glyph && <span className={glyphClass(item.glyph)} aria-hidden="true" />}
            {item.label}
          </span>
        </div>
      ))}
    </div>
  )
}
