/** DropZone — empty / drag-over / chosen / invalid file. Picks a file by drop or by the
 *  "choose a file" button (keyboard reachable). A chosen file renders as FileRow with
 *  Replace; `accept` extensions and `maxBytes` are checked here, the message is shown
 *  next to the zone (invalid file). */
import { useRef, useState, type DragEvent } from 'react'
import { Upload } from 'lucide-react'
import { FileRow } from './FileRow'
import { useUiMessages } from './uiMessages'

export interface DropZoneProps {
  /** Comma-separated extensions / MIME types, as the input `accept` attribute. */
  accept?: string
  /** Largest allowed size in bytes. */
  maxBytes?: number
  /** Heading, e.g. "Drop an .xlsx file here". */
  title: string
  /** Limits text, e.g. "up to 2 MB, 200 rows". */
  limits?: string
  onFile: (file: File) => void
  /** Message for a refused file; default is a generic one. */
  invalidText?: string
  /** Shows the chosen file (size, rows) instead of the empty zone. */
  chosen?: { file: File; rows?: string } | null
  formatSize?: (bytes: number) => string
}

function defaultSize(bytes: number): string {
  return bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`
}

function acceptable(file: File, accept: string | undefined): boolean {
  if (accept == null || accept.trim() === '') return true
  const name = file.name.toLowerCase()
  return accept.split(',').map((a) => a.trim().toLowerCase()).filter(Boolean).some((a) =>
    a.startsWith('.') ? name.endsWith(a) : a.endsWith('/*') ? file.type.startsWith(a.slice(0, -1)) : file.type === a,
  )
}

export function DropZone({ accept, maxBytes, title, limits, onFile, invalidText, chosen, formatSize = defaultSize }: DropZoneProps) {
  const t = useUiMessages()
  const input = useRef<HTMLInputElement | null>(null)
  const [over, setOver] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const take = (file: File | undefined) => {
    if (file == null) return
    if (!acceptable(file, accept) || (maxBytes != null && file.size > maxBytes)) {
      setError(invalidText ?? t.invalidFile)
      return
    }
    setError(null)
    onFile(file)
  }
  const onDrop = (e: DragEvent) => {
    e.preventDefault()
    setOver(false)
    take(e.dataTransfer.files[0])
  }
  const choose = () => input.current?.click()

  const hiddenInput = (
    <input
      ref={input}
      type="file"
      accept={accept}
      className="sr-only"
      tabIndex={-1}
      aria-hidden="true"
      data-testid="dropzone-input"
      onChange={(e) => {
        take(e.target.files?.[0])
        e.target.value = ''
      }}
    />
  )

  if (chosen != null && error == null) {
    return (
      <div data-testid="dropzone-chosen">
        <FileRow name={chosen.file.name} size={formatSize(chosen.file.size)} rows={chosen.rows} onReplace={choose} />
        {hiddenInput}
      </div>
    )
  }

  return (
    <div>
      <div
        className={over ? 'lf-drop is-over' : 'lf-drop'}
        data-testid="dropzone"
        onDragOver={(e) => {
          e.preventDefault()
          setOver(true)
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <Upload className="lf-icon" aria-hidden="true" />
        <strong>{over ? t.dropOver : title}</strong>
        <span>
          {t.dropOr}{' '}
          <button type="button" className="lf-btn lf-btn--ghost lf-btn--s" data-testid="dropzone-choose" onClick={choose}>
            {t.dropChoose}
          </button>
          {limits != null && <> · {limits}</>}
        </span>
        {hiddenInput}
      </div>
      {error != null && (
        <p className="lf-error" role="alert" data-testid="dropzone-error">
          {error}
        </p>
      )}
    </div>
  )
}
