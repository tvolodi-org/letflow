/** HelpLink — T-1560, reworked in T-1872. A ghost button in a page header that opens the help of the screen in a side
 *  panel. It never navigates: a route change unmounts the screen and its form state (the entered data was lost), a
 *  panel in the same tree does not. The label comes from the caller's message catalogue; `children` is the help body
 *  and `title` its panel heading. `defaultOpen` exists only for the screen harness. */
import { useState, type ReactNode } from 'react'
import { HelpSidePanel } from './HelpSidePanel'

export interface HelpLinkProps {
  label: string
  closeLabel: string
  title: string
  children: ReactNode
  defaultOpen?: boolean
}

export function HelpLink({ label, closeLabel, title, children, defaultOpen = false }: HelpLinkProps) {
  const [open, setOpen] = useState(defaultOpen)
  return (
    <>
      <button type="button" className="lf-btn lf-btn--ghost" data-testid="help-link" aria-haspopup="dialog" onClick={() => setOpen(true)}>
        {label}
      </button>
      {open && (
        <HelpSidePanel title={title} closeLabel={closeLabel} onClose={() => setOpen(false)}>
          {children}
        </HelpSidePanel>
      )}
    </>
  )
}
