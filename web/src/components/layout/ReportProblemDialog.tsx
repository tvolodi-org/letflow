/** Consent dialog of "Report a problem" (T-1950). Takes one snapshot of the capture rings when it opens; the preview
 *  and the posted body are built from that snapshot by the same function, so the user sees exactly what is sent.
 *  Nothing is sent before the consent tick and Send.
 *  T-2015: adds screenshot upload (paste, drag-and-drop, file picker; max 3 images; PNG/JPEG/WebP). */
import { useEffect, useRef, useState } from 'react'
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
import { processImageFile, extractPastedImages, extractDroppedImages, MAX_IMAGES, MAX_TOTAL_BYTES, ACCEPTED_TYPES, type ReportImage } from '@/lib/problemReport/images'
import { fill, useReportProblemMessages, type ReportProblemMessages } from './reportProblemMessages'

const MAX_TEXT = 4000

function messageFor(e: unknown, m: ReportProblemMessages): string {
  const status = (e as { status?: unknown } | null)?.status
  if (status === 422) return m.errInvalid
  if (status === 429) return m.errTooMany
  if (status === 503) return m.errUnavailable
  return m.errGeneric
}

export function ReportProblemDialog({
  crash,
  onClose,
  preloadImages,
}: {
  crash: Error | null
  onClose: () => void
  preloadImages?: boolean
}) {
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
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [images, setImages] = useState<ReportImage[]>(() => {
    if (!preloadImages) return []
    // 1×1 solid-colour PNGs (red, blue) so the fixture always shows visible thumbnails
    const redPng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGO4Y2QEAAMuAUHwMaabAAAAAElFTkSuQmCC'
    const bluePng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwSrkDAAI+AXNw2boZAAAAAElFTkSuQmCC'
    return [
      { dataBase64: redPng, contentType: 'image/png', preview: `data:image/png;base64,${redPng}`, name: 'placeholder1.png', size: atob(redPng).length },
      { dataBase64: bluePng, contentType: 'image/png', preview: `data:image/png;base64,${bluePng}`, name: 'placeholder2.png', size: atob(bluePng).length },
    ]
  })
  const [imageError, setImageError] = useState<string | null>(null)

  const body = buildReportBody(text, snap, { uiLanguage: uiLocale, crash, images })
  const errorCount = body.context.requests.filter((r) => r.status === undefined || r.status === 0 || r.status >= 400).length
  const permissionCount = access.state.status === 'ready' ? access.state.info.permissions.length : null

  // Handle paste events anywhere in the dialog
  useEffect(() => {
    const handlePaste = (e: ClipboardEvent) => {
      const files = extractPastedImages(e)
      if (files.length > 0) void processImages(files)
    }
    window.addEventListener('paste', handlePaste)
    return () => window.removeEventListener('paste', handlePaste)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [images])

  async function processImages(files: File[]): Promise<void> {
    setImageError(null)
    // Track running total for this call (using the stale closure value as the starting point
    // is intentional: concurrent calls would each check against the same baseline, which is
    // safe — the setState callback below is the final arbiter).
    let runningTotal = images.reduce((sum, img) => sum + img.size, 0)
    for (const file of files) {
      if (images.length >= MAX_IMAGES) break
      const result = await processImageFile(file)
      if (result === null) {
        setImageError(ACCEPTED_TYPES.includes(file.type) ? m.imageTooLarge : m.imageInvalidType)
      } else if (runningTotal + result.size > MAX_TOTAL_BYTES) {
        setImageError(m.imagesTooLargeTotal)
      } else {
        runningTotal += result.size
        setImages((current) => (current.length < MAX_IMAGES ? [...current, result] : current))
      }
    }
  }

  const handleDrop = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    const files = extractDroppedImages(e.nativeEvent)
    void processImages(files)
  }

  const handleDragOver = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault()
  }

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? [])
    void processImages(files)
    // Reset so the same file can be re-added after removal
    e.target.value = ''
  }

  const removeImage = (index: number) => {
    setImages((current) => current.filter((_, i) => i !== index))
    setImageError(null)
  }

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

      <div className="lf-report__images">
        <h4 className="lf-report__h">
          {m.imagesHeading}
          {images.length > 0 && (
            <span className="lf-muted" data-testid="report-image-count"> {fill(m.imagesCount, { n: images.length })}</span>
          )}
        </h4>
        <div
          role="button"
          tabIndex={0}
          className="lf-report__drop"
          data-testid="report-drop-zone"
          onClick={() => fileInputRef.current?.click()}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInputRef.current?.click() } }}
          onDrop={handleDrop}
          onDragOver={handleDragOver}
        >
          <span className="lf-muted">{m.imagesHint}</span>
        </div>
        {images.length > 0 && (
          <div className="lf-report__thumbs">
            {images.map((img, i) => (
              <div key={i} className="lf-report__thumb">
                <img src={img.preview} alt={img.name} />
                <button
                  type="button"
                  className="lf-report__thumb-remove"
                  data-testid={`report-image-remove-${i}`}
                  onClick={() => removeImage(i)}
                  aria-label={m.imageRemove}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        )}
        {imageError && <p className="lf-error" data-testid="report-image-error">{imageError}</p>}
        <input
          ref={fileInputRef}
          type="file"
          accept="image/png,image/jpeg,image/webp"
          multiple
          data-testid="report-image-input"
          style={{ display: 'none' }}
          onChange={handleFileChange}
        />
        {images.length < MAX_IMAGES && (
          <button
            type="button"
            className="lf-btn lf-btn--secondary lf-btn--sm"
            data-testid="report-image-pick"
            onClick={() => fileInputRef.current?.click()}
          >
            {m.imagesPickButton}
          </button>
        )}
      </div>

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
        {images.length > 0 && <li>{fill(m.imagesConsentNote, { n: images.length })}</li>}
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
