/** Banner — four tones, optional action (wraps under the text on phones). */
import type { ReactNode } from 'react'
import { AlertTriangle, CheckCircle2, Info, OctagonAlert } from 'lucide-react'

export type BannerTone = 'info' | 'success' | 'warning' | 'danger'

export interface BannerProps {
  tone: BannerTone
  title?: string
  children?: ReactNode
  action?: ReactNode
}

const ICONS = { info: Info, success: CheckCircle2, warning: AlertTriangle, danger: OctagonAlert } as const

export function Banner({ tone, title, children, action }: BannerProps) {
  const Icon = ICONS[tone]
  return (
    <div
      className={`lf-banner lf-banner--${tone}`}
      role={tone === 'danger' ? 'alert' : 'status'}
      data-testid="banner"
      data-tone={tone}
    >
      <Icon className="lf-icon" aria-hidden="true" />
      <div>
        {title != null && <strong>{title}</strong>}
        {title != null && children != null && ' '}
        {children}
      </div>
      {action}
    </div>
  )
}
