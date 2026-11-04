/** RegisterShell — GH 3767 / REQ-724. Error banner and Load more button shared by the two register screens. */
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { errorKind } from './stockRegisterModel'

export function RegisterError({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const intl = useIntl()
  const kind = errorKind(error)
  const retry =
    kind === 'notFound' || kind === 'forbidden' ? undefined : (
      <Button variant="secondary" size="sm" onClick={onRetry}>
        {intl.formatMessage({ id: 'stock.common.retry' })}
      </Button>
    )
  return (
    <Banner tone={kind === 'notFound' ? 'info' : 'danger'} action={retry}>
      {intl.formatMessage({ id: `stock.error.${kind}` })}
    </Banner>
  )
}

export function LoadMore({ visible, loading, onClick }: { visible: boolean; loading: boolean; onClick: () => void }) {
  const intl = useIntl()
  if (!visible) return null
  return (
    <div className="lf-form-actions">
      <Button variant="secondary" loading={loading} onClick={onClick} data-testid="load-more">
        {intl.formatMessage({ id: 'stock.common.loadMore' })}
      </Button>
    </div>
  )
}
