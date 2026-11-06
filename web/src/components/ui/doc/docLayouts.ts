/** docLayouts — the registry of document-form layouts (D-100/D-101; design repo LFDocLayout, NOTES.md "Layouts of the
 *  document form"). Adding a layout = one entry here + CSS under `.lf-doc[data-layout="<name>"]` + the value in the
 *  backend's `UserPreferences` / tenant-key validation (they change together). Generic: no module words. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export type DocLayoutName = 'row' | 'tabs'
export type DocPane = 'header' | 'lines'
export type DocState = 'new' | 'existing'

export interface DocLayoutDef {
  name: DocLayoutName
  /** CSS hook: the layout's rules live under `.lf-doc[data-layout="<name>"]`. */
  hook: string
  label: Record<UiLocale, string>
  hint: Record<UiLocale, string>
  /** Panes switched by a tab list; null = all panes visible at once. */
  tabs: readonly DocPane[] | null
  /** Tab that opens first: one tab, or one per document state. */
  defaultTab?: DocPane | { new: DocPane; existing: DocPane }
}

export const DOC_LAYOUTS: Record<DocLayoutName, DocLayoutDef> = {
  row: {
    name: 'row',
    hook: '.lf-doc[data-layout="row"]',
    label: { en: 'Row', ru: 'В ряд', kk: 'Қатар' },
    hint: {
      en: 'List, header and lines side by side.',
      ru: 'Список, шапка и строки рядом.',
      kk: 'Тізім, тақырып және жолдар қатар.',
    },
    tabs: null,
  },
  tabs: {
    name: 'tabs',
    hook: '.lf-doc[data-layout="tabs"]',
    label: { en: 'Tabs', ru: 'Вкладки', kk: 'Қойындылар' },
    hint: {
      en: 'Header and Lines on tabs; a new document opens on Header.',
      ru: 'Шапка и строки на вкладках; новый документ открывается на шапке.',
      kk: 'Тақырып пен жолдар қойындыларда; жаңа құжат тақырыптан ашылады.',
    },
    tabs: ['header', 'lines'],
    defaultTab: { new: 'header', existing: 'lines' },
  },
}

export const DEFAULT_DOC_LAYOUT: DocLayoutName = 'row'
export const DOC_LAYOUT_NAMES = Object.keys(DOC_LAYOUTS) as DocLayoutName[]

export function isDocLayoutName(v: unknown): v is DocLayoutName {
  return typeof v === 'string' && Object.prototype.hasOwnProperty.call(DOC_LAYOUTS, v)
}

/** The tab a document opens on, or null when the layout has no tabs. */
export function defaultTabFor(layout: DocLayoutName, state: DocState): DocPane | null {
  const def = DOC_LAYOUTS[layout]
  if (!def.tabs) return null
  const d = def.defaultTab
  if (!d) return def.tabs[0] ?? null
  return typeof d === 'string' ? d : d[state]
}

/** Problem count per pane from the form's error map: `lines` and `lines.<i>.*` belong to Lines, the rest (`header.*`,
 *  `side.*`, `sides`) to Header. */
export function problemsByPane(errors: Record<string, string>): Record<DocPane, number> {
  const out: Record<DocPane, number> = { header: 0, lines: 0 }
  for (const key of Object.keys(errors)) out[paneOfKey(key)] += 1
  return out
}

export function paneOfKey(key: string): DocPane {
  return key === 'lines' || key.startsWith('lines.') ? 'lines' : 'header'
}

/** First pane (in tab order) with a problem, or null. */
export function firstProblemTab(problems: Record<DocPane, number>, order: readonly DocPane[] = ['header', 'lines']): DocPane | null {
  return order.find((p) => problems[p] > 0) ?? null
}
