/** Consent dialog of "Report a problem" (T-1950). Takes one snapshot of the capture rings when it opens; the preview
 *  and the posted body are built from that snapshot by the same function, so the user sees exactly what is sent.
 *  Nothing is sent before the consent tick and Send. */
import { useState } from 'react'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { Dialog } from '@/components/ui/Dialog'
import { Field } from '@/components/ui/Field'
import { Checkbox } from '@/components/ui/Checkbox'
import { useToast } from '@/hooks/useToast'
import { useSubmitProblemReport } from '@/hooks/useSubmitProblemReport'
import { snapshot } from '@/lib/problemReport/capture'
import { buildReportBody } from '@/lib/problemReport/payload'
import { fill, useReportProblemMessages, type ReportProblemMessages } from './reportProblemMessages'

const MAX_TEXT = 4000

function messageFor(e: unknown, m: ReportProblemMessages): string {
  const status = (e as { status?: unknown } | null)?.status
  if (status === 422) return m.errInvalid
  if (status === 429) return m.errTooMany
  if (status === 503) return m.errUnavailable
  return m.errGeneric
}

export function ReportProblemDialog({ crash, onClose }: { crash: Error | null; onClose: () => void }) {
  const m = useReportProblemMessages()
  const uiLocale = useUiLocale()
  const { session } = useAuth()
  const access = useAccess()
  const toast = useToast()
  const mutation = useSubmitProblemReport()
  const [snap] = useState(() => snapshot())
  const [text, setText] = useState(crash ? m.crashPrefill : '')
  const [consent, setConsent] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const body = buildReportBody(text, snap, { uiLanguage: uiLocale, crash })
  const errorCount = body.context.requests.filter((r) => r.status === undefined || r.status === 0 || r.status >= 400).length
  const permissionCount = access.state.status === 'ready' ? access.state.info.permissions.length : null

  const send = (): void => {
    setError(null)
    mutation.mutate(body, {
      onSuccess: (r) => {
        toast.success(fill(m.received, { number: r.number }), { description: m.receivedHint })
        onClose()
      },
      onError: (e) => setError(messageFor(e, m)),
    })
  }

  return (
    <Dialog
      open
      testId="report-dialog"
      size="l"
      title={m.title}
      subtitle={m.subtitle}
      confirmText={m.send}
      cancelText={m.cancel}
      confirmDisabled={!text.trim() || !consent}
      isLoading={mutation.isPending}
      error={error}
      onConfirm={send}
      onCancel={onClose}
    >
      <Field label={m.textLabel} hint={`${text.length} / ${MAX_TEXT}`}>
        <textarea
          className="lf-control"
          data-testid="report-text"
          rows={5}
          maxLength={MAX_TEXT}
          placeholder={m.placeholder}
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
      </Field>

      <h4 className="lf-report__h">{m.sendHeading}</h4>
      <ul className="lf-report__list" data-testid="report-summary">
        <li>
          {m.factScreen}: <code>{body.context.route}</code>
        </li>
        <li>
          {m.factBrowser}: {body.context.browser.language ?? '—'}, {body.context.browser.viewport}
        </li>
        <li>{fill(m.factActions, { n: body.context.actions.length })}</li>
        <li>{fill(m.factRequests, { n: body.context.requests.length, e: errorCount })}</li>
        {body.context.crash && <li>{fill(m.factCrash, { name: body.context.crash.name })}</li>}
      </ul>

      <details className="lf-report__details" data-testid="report-preview-toggle">
        <summary>{m.showExact}</summary>
        <pre className="lf-report__pre" data-testid="report-preview">
          {JSON.stringify(body, null, 2)}
        </pre>
      </details>

      <h4 className="lf-report__h">{m.serverAdds}</h4>
      <ul className="lf-report__list" data-testid="report-server-adds">
        <li>
          {m.addName}: {session?.display_name ?? '—'}
        </li>
        <li>
          {m.addCompany}: {session?.tenant_display_name ?? '—'}
        </li>
        <li>
          {m.addRoles}: {access.roles.length > 0 ? access.roles.join(', ') : m.noRoles}
        </li>
        <li>{fill(m.addPermissions, { n: permissionCount ?? '—' })}</li>
        <li>{m.addVersion}</li>
      </ul>

      <Checkbox data-testid="report-consent" label={m.consent} checked={consent} onChange={setConsent} />
    </Dialog>
  )
}
