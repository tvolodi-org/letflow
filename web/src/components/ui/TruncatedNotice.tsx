/** TruncatedNotice — an info banner saying that a list shows only the first rows the screen loads. */
import { useIntl } from 'react-intl'
import { Banner } from './Banner'

export function TruncatedNotice({ messageId, count }: { messageId: string; count: number }) {
  const intl = useIntl()
  return (
    <div data-testid="list-truncated">
      <Banner tone="info">{intl.formatMessage({ id: messageId }, { count })}</Banner>
    </div>
  )
}
