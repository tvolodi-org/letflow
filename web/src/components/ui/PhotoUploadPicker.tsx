/** PhotoUploadPicker — T-2042 (photos P3). The four ways to hand images to a screen: a file button (several files), a
 *  separate camera button (phone rear camera; the ordinary picker stays as the fallback), drag-and-drop, and paste.
 *  Paste and drop are handled on the focusable drop target only, never on `window`, so a hidden panel cannot take a
 *  paste, and a paste into a text field keeps its text behaviour. It only reports the files; the caller prepares,
 *  limits and uploads them. Every text comes in `labels` (the caller owns the catalog).
 *  Inside a `Field` with `group`, the field gives the picker its id, its group role and the name of the
 *  label; the picker passes them to its root, so the whole picker is the named group of the field. */
import { useId, useRef, useState, type ClipboardEvent, type DragEvent, type HTMLAttributes, type KeyboardEvent } from 'react'
import { Camera, ImagePlus } from 'lucide-react'
import { Button } from './Button'

export interface PhotoUploadLabels {
  choose: string
  take: string
  /** the instruction inside the drop target */
  drop: string
  /** accessible name of the drop target */
  target: string
}

const PICKER_ACCEPT = 'image/jpeg,image/png,image/webp,image/heic,image/heif,.heic,.heif'

/** Image files of a clipboard or a drop, in order. Anything that is not a file is ignored. */
export function imageFilesOf(list: DataTransfer | null | undefined): File[] {
  const files: File[] = []
  if (!list) return files
  for (const item of Array.from(list.items ?? [])) {
    if (item.kind === 'file' && item.type.startsWith('image/')) {
      const f = item.getAsFile()
      if (f) files.push(f)
    }
  }
  if (files.length === 0) for (const f of Array.from(list.files ?? [])) if (f.type.startsWith('image/')) files.push(f)
  return files
}

function isTextTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null
  if (!el || typeof el.closest !== 'function') return false
  return el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]') !== null
}

export interface PhotoUploadPickerProps extends HTMLAttributes<HTMLDivElement> {
  labels: PhotoUploadLabels
  onFiles: (files: File[]) => void
  disabled?: boolean
  /** shown when disabled, so a dead control always says why */
  disabledReason?: string
  /** The test id of the file input; the camera input keeps its own. */
  inputTestId?: string
}

export function PhotoUploadPicker(props: PhotoUploadPickerProps) {
  const { labels, onFiles, disabled = false, inputTestId = 'photo-file-input', className, ...rest } = props
  const reasonId = useId()
  const fileRef = useRef<HTMLInputElement | null>(null)
  const cameraRef = useRef<HTMLInputElement | null>(null)
  const [over, setOver] = useState(false)

  const fromInput = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? [])
    e.target.value = ''
    if (files.length > 0) onFiles(files)
  }
  const onPaste = (e: ClipboardEvent<HTMLDivElement>) => {
    if (disabled || isTextTarget(e.target)) return
    const files = imageFilesOf(e.clipboardData)
    if (files.length === 0) return
    e.preventDefault()
    onFiles(files)
  }
  const onDrop = (e: DragEvent<HTMLDivElement>) => {
    e.preventDefault()
    setOver(false)
    if (disabled) return
    const files = imageFilesOf(e.dataTransfer)
    if (files.length > 0) onFiles(files)
  }
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (disabled || e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      fileRef.current?.click()
    }
  }

  return (
    <div {...rest} className={className == null ? 'lf-photoup' : `lf-photoup ${className}`}>
      <div className="lf-btn-row">
        <Button variant="secondary" size="md" icon={<ImagePlus className="lf-icon" aria-hidden="true" />} disabled={disabled} aria-describedby={disabled ? reasonId : undefined} onClick={() => fileRef.current?.click()} data-testid="photo-choose">
          {labels.choose}
        </Button>
        <Button variant="secondary" size="md" icon={<Camera className="lf-icon" aria-hidden="true" />} disabled={disabled} aria-describedby={disabled ? reasonId : undefined} onClick={() => cameraRef.current?.click()} data-testid="photo-take">
          {labels.take}
        </Button>
      </div>
      <input ref={fileRef} type="file" className="sr-only" tabIndex={-1} aria-hidden="true" multiple accept={PICKER_ACCEPT} disabled={disabled} onChange={fromInput} data-testid={inputTestId} />
      <input ref={cameraRef} type="file" className="sr-only" tabIndex={-1} aria-hidden="true" accept="image/*" capture="environment" disabled={disabled} onChange={fromInput} data-testid="photo-camera-input" />
      <div
        className={`lf-photoup__drop${over ? ' is-over' : ''}${disabled ? ' is-disabled' : ''}`}
        role="group"
        tabIndex={disabled ? -1 : 0}
        aria-label={labels.target}
        onPaste={onPaste}
        onDrop={onDrop}
        onDragOver={(e) => {
          e.preventDefault()
          if (!disabled) setOver(true)
        }}
        onDragLeave={() => setOver(false)}
        onKeyDown={onKey}
        data-testid="photo-drop"
      >
        {labels.drop}
      </div>
      {disabled && props.disabledReason ? (
        <p className="caption lf-faint" id={reasonId} data-testid="photo-disabled-reason">
          {props.disabledReason}
        </p>
      ) : null}
    </div>
  )
}
