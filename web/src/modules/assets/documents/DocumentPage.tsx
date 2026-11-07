/** DocumentPage — thin route wrapper (T-1334 / C14): the two document routes render one workspace. */
import { AssetsIntlProvider } from '../AssetsIntlProvider'
import { DocumentsWorkspace } from './DocumentsWorkspace'

export default function DocumentPage() {
  return (
    <AssetsIntlProvider>
      <DocumentsWorkspace mode="view" />
    </AssetsIntlProvider>
  )
}
