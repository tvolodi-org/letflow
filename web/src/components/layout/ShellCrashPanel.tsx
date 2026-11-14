/** The shell's crash screen (T-1950), passed as the `fallback` of the shell's ErrorBoundary. Localised (en/ru/kk),
 *  token-styled, with "Report this problem" pre-filled with the crash. The root and the DEV details keep the testids
 *  of the old default panel: the e2e helpers (`assertNoErrorBoundary`) detect a crash by them. The boundary wraps
 *  AppShell, so this panel renders its own ToastContainer (the success toast of the report would not show otherwise). */
import { ToastContainer } from '@/components/ui/Toast'
import { Button } from '@/components/ui/Button'
import { ReportProblemButton } from './ReportProblemButton'
import { useReportProblemMessages } from './reportProblemMessages'

export function ShellCrashPanel({ error, reset }: { error: Error; reset: () => void }) {
  const m = useReportProblemMessages()
  return (
    <div className="lf-report__crash" data-testid="error-boundary-panel">
      <div className="lf-card lf-report__card" role="alert">
        <h2 className="lf-card__title">{m.crashTitle}</h2>
        <p>{m.crashText}</p>
        {import.meta.env.DEV && (
          <details data-testid="error-boundary-details">
            <summary>{m.crashDetails}</summary>
            <pre className="lf-report__pre">
              {error.message}
              {error.stack ? `\n\n${error.stack}` : ''}
            </pre>
          </details>
        )}
        <div className="lf-btn-row">
          <Button variant="primary" data-testid="error-boundary-reset" onClick={reset}>
            {m.crashRetry}
          </Button>
          <a className="lf-btn lf-btn--secondary" href="/instances">
            {m.crashHome}
          </a>
          <ReportProblemButton variant="text" crash={error} />
        </div>
      </div>
      <ToastContainer />
    </div>
  )
}
