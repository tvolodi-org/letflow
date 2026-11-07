/** LinesStates — the non-table states of the lines editor: no permission, loading, load error, empty, no search match. */
import { AlertTriangle, Layers, Search } from 'lucide-react'
import { Button } from '../Button'
import { useLinesT } from './linesMessages'

export function NoPermissionState() {
  const t = useLinesT()
  return (
    <div className="lf-le__state" data-testid="lines-noperm">
      <div className="lf-empty">
        <AlertTriangle className="lf-icon lf-empty__icon" aria-hidden="true" />
        <p className="lf-empty__title">{t('noPerm')}</p>
        <p className="lf-empty__text">{t('noPermText')}</p>
      </div>
    </div>
  )
}

export function LoadingState() {
  const t = useLinesT()
  return (
    <div className="lf-le__state lf-le__skel" aria-busy="true" aria-label={t('loading')} data-testid="lines-loading">
      {Array.from({ length: 9 }, (_, i) => (
        <span key={i} className="lf-skel" />
      ))}
    </div>
  )
}

export function ErrorState({ onRetry }: { onRetry?: () => void }) {
  const t = useLinesT()
  return (
    <div className="lf-le__state" data-testid="lines-error">
      <div className="lf-banner lf-banner--danger" role="alert">
        <AlertTriangle className="lf-icon lf-icon--18" aria-hidden="true" />
        <div>
          <strong>{t('errTitle')}</strong>
          <p>{t('errText')}</p>
        </div>
        {onRetry && (
          <Button variant="secondary" onClick={onRetry}>
            {t('retry')}
          </Button>
        )}
      </div>
    </div>
  )
}

export function EmptyState({ readOnly, onAdd, addDisabled, onImport, importDisabledReason }: { readOnly?: boolean; onAdd?: () => void; addDisabled?: boolean; onImport?: () => void; importDisabledReason?: string }) {
  const t = useLinesT()
  return (
    <div className="lf-le__state" data-testid="lines-empty">
      <div className="lf-empty">
        <Layers className="lf-icon lf-empty__icon" aria-hidden="true" />
        <p className="lf-empty__title">{t('empty')}</p>
        <p className="lf-empty__text">{readOnly ? t('readOnly') : t('emptyText')}</p>
        {!readOnly && onAdd && (
          <div className="lf-btn-row">
            <Button variant="primary" onClick={onAdd} disabled={addDisabled}>
              {t('add')}
            </Button>
            {onImport && (
              <Button variant="secondary" onClick={onImport} disabled={importDisabledReason !== undefined} title={importDisabledReason} data-testid="lines-empty-import">
                {t('imp')}
              </Button>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export function NoMatchState({ onClear }: { onClear: () => void }) {
  const t = useLinesT()
  return (
    <div className="lf-le__emptyview lf-empty" data-testid="lines-nomatch">
      <Search className="lf-icon lf-empty__icon" aria-hidden="true" />
      <p className="lf-empty__title">{t('noMatchLines')}</p>
      <p className="lf-empty__text">{t('noMatchLinesText')}</p>
      <Button variant="secondary" onClick={onClear}>
        {t('clearSearch')}
      </Button>
    </div>
  )
}
