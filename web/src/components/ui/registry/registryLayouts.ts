/** registryLayouts — the layouts of the registry (platform NOTES.md "Layouts of the registry", rule 11 analogue).
 *  A layout is one entry here plus CSS under `.lf-reg[data-layout="<name>"]` in components.css; a screen names a
 *  layout and never arranges the panes itself. `split` shows the sections of the details pane one below the other;
 *  `tabs` puts them in a tab block (one visible at a time, chosen through `data-tab`). */
export const REGISTRY_LAYOUTS = {
  split: { name: 'split', sectionsAsTabs: false },
  tabs: { name: 'tabs', sectionsAsTabs: true },
} as const

export type RegistryLayout = keyof typeof REGISTRY_LAYOUTS

export const DEFAULT_REGISTRY_LAYOUT: RegistryLayout = 'split'

export function isRegistryLayout(v: unknown): v is RegistryLayout {
  return typeof v === 'string' && Object.prototype.hasOwnProperty.call(REGISTRY_LAYOUTS, v)
}
