/** T-1874 — display name of a saved report. Views have one `name` column, so a shipped report's name is localized on
 *  the client through the message catalog (same ids as the view picker, T-1868); any other name is shown as stored. */
import type { IntlShape } from 'react-intl'

const SHIPPED_REPORT_NAMES: Record<string, string> = {
  'Asset list': 'entities.views.shipped.assetList',
}

export function reportDisplayName(name: string, intl: IntlShape): string {
  const id = SHIPPED_REPORT_NAMES[name]
  return id ? intl.formatMessage({ id }) : name
}
