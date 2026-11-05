/** DocumentPage — thin route wrapper (T-1379): the three document routes render one workspace, see DocumentsWorkspace. */
import { StockIntlProvider } from '../StockIntlProvider'
import { DocumentsWorkspace } from './DocumentsWorkspace'

export default function DocumentPage() {
  return (
    <StockIntlProvider>
      <DocumentsWorkspace mode="view" />
    </StockIntlProvider>
  )
}
