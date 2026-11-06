/** DocumentsWorkspace — T-1334 / C14. One screen for the two asset document routes (list, one document) on the
 *  platform document form (`lf-doc`): list | header card | lines table on wide screens, the open document replacing the
 *  list under 900 px. The record is never in a modal (rule 2a); the list stays mounted while the user clicks other rows.
 *  Modes: `list` and `view`; the draft form mode joins them in the follow-up task. */
import { useIntl } from 'react-intl'
import { useNavigate, useParams } from 'react-router-dom'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { DocBlank, DocLayout } from '@/components/ui/doc/DocLayout'
import { useDocumentLayout } from '@/hooks/useDocumentLayout'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { useLayoutMessages } from '@/components/ui/layout/layoutMessages'
import { DOCUMENTS_PATH, DocumentList } from './DocumentList'
import { DocumentView } from './DocumentView'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN } from './lineColumns'

export type WorkspaceMode = 'list' | 'view'

export function DocumentsWorkspace({ mode }: { mode: WorkspaceMode }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const { id } = useParams()
  const navigate = useNavigate()
  const back = () => navigate(DOCUMENTS_PATH)
  const layout = useDocumentLayout()
  const store = useLayoutPrefs()
  const lm = useLayoutMessages()
  return (
    <>
      <PageHeader
        eyebrow={t('assets.reg.eyebrow')}
        title={t('assets.doc.title')}
        lede={t('assets.doc.lede')}
        actions={
          <Button variant="ghost" onClick={() => store.resetScreen(ASSET_DOCUMENTS_LAYOUT_SCREEN)} data-testid="reset-layout">
            {lm.resetLayout}
          </Button>
        }
      />
      <DocLayout screen={ASSET_DOCUMENTS_LAYOUT_SCREEN} detailOpen={mode !== 'list'} layout={layout} docState={mode === 'view' ? 'existing' : 'none'} docKey={`${mode}:${id ?? ''}`} data-testid="document-workspace">
        <DocumentList selectedId={mode === 'view' ? id : undefined} />
        {mode === 'list' && <DocBlank title={t('assets.doc.blank.title')} text={t('assets.doc.blank.text')} />}
        {mode === 'view' && id && <DocumentView key={id} id={id} onBack={back} />}
      </DocLayout>
    </>
  )
}
