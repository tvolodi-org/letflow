/** DocumentNewPage — T-1469. Thin route wrapper: the document routes render one workspace, see DocumentsWorkspace. */
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { DocumentsWorkspace } from './DocumentsWorkspace'

export default function DocumentNewPage() {
  return (
    <AssetsIntlProvider>
      <DocumentsWorkspace mode="create" />
    </AssetsIntlProvider>
  )
}
