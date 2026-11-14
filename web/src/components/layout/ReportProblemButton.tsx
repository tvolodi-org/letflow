/** The "Report a problem" button (T-1950): an icon in the top bar of every signed-in screen, or a text button in the
 *  crash panel (then `crash` pre-fills the dialog). It owns the open flag; the dialog mounts only while open, so
 *  nothing else runs until the user clicks. Not permission-gated: every role may report. */
import { useState } from 'react'
import { MessageSquareWarning } from 'lucide-react'
import { Button } from '@/components/ui/Button'
import { ReportProblemDialog } from './ReportProblemDialog'
import { useReportProblemMessages } from './reportProblemMessages'

export function ReportProblemButton({ crash, variant = 'icon' }: { crash?: Error; variant?: 'icon' | 'text' }) {
  const m = useReportProblemMessages()
  const [open, setOpen] = useState(false)
  return (
    <>
      {variant === 'icon' ? (
        <button
          type="button"
          className="lf-btn lf-btn--ghost lf-btn--icon"
          data-testid="topbar-report-problem"
          aria-label={m.button}
          title={m.button}
          onClick={() => setOpen(true)}
        >
          <MessageSquareWarning className="lf-icon" aria-hidden="true" />
        </button>
      ) : (
        <Button variant="secondary" data-testid="error-boundary-report" onClick={() => setOpen(true)}>
          {m.crashButton}
        </Button>
      )}
      {open && <ReportProblemDialog crash={crash ?? null} onClose={() => setOpen(false)} />}
    </>
  )
}
