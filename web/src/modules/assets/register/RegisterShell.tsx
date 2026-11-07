/** RegisterShell — T-1334 / C14. Error banner and Load more button shared by the register and document screens. */
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { errorKind } from './registerModel'

export function RegisterError({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const intl = useIntl()
  const kind = errorKind(error)
  const retry =
    kind === 'notFound' || kind === 'forbidden' ? undefined : (
      <Button variant="secondary" size="sm" onClick={onRetry}>
        {intl.formatMessage({ id: 'assets.reg.retry' })}
      </Button>
    )
  return (
    <Banner tone={kind === 'notFound' ? 'info' : 'danger'} action={retry}>
      {intl.formatMessage({ id: `assets.reg.error.${kind}` })}
    </Banner>
  )
}

export function LoadMore({ visible, loading, onClick }: { visible: boolean; loading: boolean; onClick: () => void }) {
  const intl = useIntl()
  if (!visible) return null
  return (
    <div className="lf-btn-row">
      <Button variant="secondary" loading={loading} onClick={onClick} data-testid="load-more">
        {intl.formatMessage({ id: 'assets.reg.loadMore' })}
      </Button>
    </div>
  )
}
