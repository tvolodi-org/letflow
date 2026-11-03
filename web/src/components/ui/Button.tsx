/** Button — design-system primitive (NOTES.md section 2; classes from styles/components.css)
 *
 *  variant: primary | secondary | danger | ghost
 *  size: sm | md | lg  (compatibility: sm maps to the design's "s"; md and lg to the default "m")
 *  icon: a node shown before the label; iconOnly + label: a square icon button named by `label`.
 *  loading keeps the text (the spinner is drawn by .is-loading::after) so the width does not jump.
 *  No colour or spacing literal appears here; everything comes from the class names.
 */

import React from 'react'

export interface ButtonProps {
  variant: 'primary' | 'secondary' | 'danger' | 'ghost'
  /** Compatibility size names: sm = design "s"; md and lg = design "m". */
  size?: 'sm' | 'md' | 'lg' | 's' | 'm'
  loading?: boolean
  disabled?: boolean
  onClick?: () => void
  children?: React.ReactNode
  'data-testid'?: string
  /** Native tooltip text, forwarded to the underlying <button title="...">. */
  title?: string
  /**
   * Marks the button as a toggle in its "on" state: sets aria-pressed and
   * the `is-pressed` class (see ISS-0559).
   */
  pressed?: boolean
  /** Icon node (a lucide icon with className "lf-icon") shown before the label. */
  icon?: React.ReactNode
  /** Square button that shows only `icon`; `label` is its accessible name. */
  iconOnly?: boolean
  label?: string
  type?: 'button' | 'submit' | 'reset'
}

export function Button(props: ButtonProps): React.ReactElement {
  const {
    variant,
    size = 'md',
    loading = false,
    disabled = false,
    onClick,
    children,
    title,
    pressed,
    icon,
    iconOnly = false,
    label,
    type = 'button',
  } = props
  const testId = props['data-testid'] ?? 'ds-button'
  const isDisabled = disabled || loading

  const classes = ['lf-btn', `lf-btn--${variant}`]
  if (size === 'sm' || size === 's') classes.push('lf-btn--s')
  if (iconOnly) classes.push('lf-btn--icon')
  if (loading) classes.push('is-loading')
  if (pressed) classes.push('is-pressed')

  return (
    <button
      type={type}
      className={classes.join(' ')}
      data-testid={testId}
      onClick={onClick}
      disabled={isDisabled}
      title={title}
      aria-pressed={pressed}
      aria-busy={loading || undefined}
      aria-label={iconOnly ? label : undefined}
    >
      {loading && <span data-testid="ds-button-spinner" aria-hidden="true" />}
      {icon}
      {iconOnly ? null : children}
    </button>
  )
}
