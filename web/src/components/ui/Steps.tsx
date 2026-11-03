/** Steps — wizard progress (README "Import wizard"). Done steps show a check,
 *  the current one its number with a ring, later ones their number. On phones
 *  CSS shows only the current label.
 */

import React from 'react'
import { Check } from 'lucide-react'

export interface StepItem {
  label: string
}

export interface StepsProps {
  steps: StepItem[]
  /** Zero-based index of the current step. */
  current: number
  'aria-label'?: string
}

export function Steps({ steps, current, 'aria-label': ariaLabel }: StepsProps): React.ReactElement {
  return (
    <ol className="lf-steps" aria-label={ariaLabel} data-testid="steps">
      {steps.map((step, index) => {
        const state = index < current ? 'is-done' : index === current ? 'is-current' : ''
        return (
          <li
            key={`${index}-${step.label}`}
            className={`lf-step ${state}`.trim()}
            aria-current={index === current ? 'step' : undefined}
            data-testid="step"
          >
            <span className="lf-step__dot">
              {index < current ? <Check className="lf-icon" aria-hidden="true" /> : index + 1}
            </span>
            <span className="lf-step__label">{step.label}</span>
          </li>
        )
      })}
    </ol>
  )
}
