/** FileRow — a chosen file: name, size / rows, replace action; invalid-file text inside. */
import { FileSpreadsheet } from 'lucide-react'
import { useUiMessages } from './uiMessages'

export interface FileRowProps {
  name: string
  /** Pre-formatted size, e.g. "9 KB". */
  size?: string
  rows?: string
  onReplace?: () => void
  replaceText?: string
  /** Set when the file is not usable; shown under the row with role="alert". */
  error?: string
}

export function FileRow({ name, size, rows, onReplace, replaceText, error }: FileRowProps) {
  const t = useUiMessages()
  const meta = [size, rows].filter((v) => v != null && v !== '').join(' · ')
  return (
    <div data-testid="file-row">
      <div className="lf-file">
        <FileSpreadsheet className="lf-icon" aria-hidden="true" />
        <div>
          <div className="lf-file__name">{name}</div>
          {meta !== '' && <div className="lf-file__meta">{meta}</div>}
        </div>
        {onReplace != null && (
          <button type="button" className="lf-btn lf-btn--ghost lf-btn--s" data-testid="file-row-replace" onClick={onReplace}>
            {replaceText ?? t.replace}
          </button>
        )}
      </div>
      {error != null && (
        <p className="lf-error" role="alert" data-testid="file-row-error">
          {error}
        </p>
      )}
    </div>
  )
}
