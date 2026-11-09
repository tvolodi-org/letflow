/** A process definition's name for people: the friendly display name in the user's language (catalog of
 *  `pages/dashboard/definitionLabels.ts`) with the technical key and version as a small second line and tooltip.
 *  A name without a catalog entry (a tenant's own definition) is shown unchanged, as before. */
import { definitionLabel } from '@/pages/dashboard/definitionLabels'
import { useUiLocale, type UiLocale } from '@/i18n/uiLocaleStore'

function technical(name: string, version?: string): string {
  return version ? `${name} v${version}` : name
}

/** Plain-string form for places that take a string (dialog sentences). */
export function definitionDisplayText(name: string, version: string | undefined, locale: UiLocale): string {
  const label = definitionLabel(name, locale)
  if (label === name) return technical(name, version)
  return version ? `${label} v${version}` : label
}

export function DefinitionName({ name, version }: { name: string; version?: string }) {
  const locale = useUiLocale()
  const label = definitionLabel(name, locale)
  if (label === name) return <>{technical(name, version)}</>
  const tech = technical(name, version)
  return (
    <span title={tech} style={{ display: 'inline-flex', flexDirection: 'column', overflowWrap: 'anywhere' }}>
      <span>{label}</span>
      <span
        data-testid="definition-technical-id"
        style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-xs)', fontFamily: 'var(--font-mono)' }}
      >
        {tech}
      </span>
    </span>
  )
}
