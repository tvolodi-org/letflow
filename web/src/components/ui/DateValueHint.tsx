/** DateValueHint -- T-1381. A native date / datetime-local input shows the browser's own format. In ru, kk and uz
 *  the value is also written next to it as `DD-MM-YYYY[ HH:mm]` (the shared formatter), so the UI language decides
 *  what the user reads. In en and when the value is empty or malformed it renders nothing. */
import { formatLocalInput, usesDayFirstDashes } from '@/i18n/format'
import { useUiLocale } from '@/i18n/uiLocaleStore'

export interface DateValueHintProps {
  /** The raw input value: `YYYY-MM-DD` or `YYYY-MM-DDTHH:mm`. */
  value: string | null | undefined
  kind: 'date' | 'datetime'
}

export function DateValueHint({ value, kind }: DateValueHintProps): React.ReactElement | null {
  const lang = useUiLocale()
  if (!usesDayFirstDashes(lang)) return null
  const text = formatLocalInput(value, kind, lang)
  if (text === '') return null
  return (
    <span className="lf-hint mono" data-testid="date-value-hint" aria-live="polite">
      {text}
    </span>
  )
}
