/**
 * Platform-default branding values and the closed CSS custom-property allowlist.
 *
 * REQ-283 (0020 D1c, theming half). See lib/letflow/design/req283-branding-css-theming.md
 * section 3 for the full rationale on why this allowlist exists and why it must be
 * iterated by ITS OWN keys, never the tenant-supplied object's keys.
 *
 * No colour literal appears in this file: the allowlist maps a brand_colors sub-key
 * name to a CSS custom-property NAME, never to a colour value. The colour value
 * itself always comes from tokens.css's own cascade (default) or the tenant's
 * response body (override) — never hard-coded here.
 */

/** The frontend's own fallback product name when no tenant branding is available. */
export const PLATFORM_DEFAULT_APP_NAME = 'Letflow'

/**
 * Closed allowlist of settable CSS custom properties, keyed by the `brand_colors`
 * sub-key the server may send. Two entries: `primary` (REQ-281's response shape) and
 * `secondary` (REQ-585). Extending this table is a change that requires the
 * server-side allowlist to move first — see design doc section 3's closing paragraph.
 */
export const BRAND_COLOR_CSS_PROPERTY: Readonly<Record<'primary' | 'secondary', string>> =
  Object.freeze({
    primary: '--color-brand-600',
    secondary: '--color-brand-secondary',
  })

/** The shape published via BrandingContext to consumers (e.g. AppShell). */
export interface BrandingContextValue {
  appName: string
  logoUrl: string | null
}

export const DEFAULT_BRANDING_CONTEXT_VALUE: BrandingContextValue = Object.freeze({
  appName: PLATFORM_DEFAULT_APP_NAME,
  logoUrl: null,
})
