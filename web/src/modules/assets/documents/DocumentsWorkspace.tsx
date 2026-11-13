/** DocumentsWorkspace — T-1334 / C14. One screen for the two asset document routes (list, one document) on the
 *  platform document form (`lf-doc`): list | header card | lines table on wide screens, the open document replacing the
 *  list under 900 px. The record is never in a modal (rule 2a); the list stays mounted while the user clicks other rows.
 *  Modes: `list`, `view` and `create` (the draft form of a new document, kind from `?kind=`; editing a draft happens in
 *  the view, T-1469). */
import { useIntl } from 'react-intl'
import { useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { Button } from '@/components/ui/Button'
import { PageHeader } from '@/components/ui/PageHeader'
import { AssetsHelpLink } from '@/modules/assets/help/AssetsHelpLink'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { useAccess } from '@/auth/access/useAccess'
import { DocBlank, DocLayout } from '@/components/ui/doc/DocLayout'
import { useDocumentLayout } from '@/hooks/useDocumentLayout'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { useLayoutMessages } from '@/components/ui/layout/layoutMessages'
import { DOCUMENTS_PATH, DocumentList } from './DocumentList'
import { DocumentForm } from './DocumentForm'
import { DocumentView } from './DocumentView'
import { DOC_KINDS, type DocKind } from './documentsModel'
import { ASSETS_POST } from '../assetsPermissions'
import { ASSET_DOCUMENTS_LAYOUT_SCREEN } from './lineColumns'

export type WorkspaceMode = 'list' | 'view' | 'create'

/** The form of a new document; the kind comes from `?kind=` (default commission) and a change of kind starts a new form. */
function DocumentCreate({ onBack }: { onBack: () => void }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const navigate = useNavigate()
  const { can } = useAccess()
  const [params, setParams] = useSearchParams()
  const asked = params.get('kind') ?? ''
  const kind: DocKind = (DOC_KINDS as readonly string[]).includes(asked) ? (asked as DocKind) : 'commission'
  if (!can(ASSETS_POST)) return <PermissionDenied />
  return (
    <DocumentForm
      key={kind}
      kind={kind}
      title={t('assets.doc.newTitle')}
      onBack={onBack}
      onCancel={onBack}
      onKindChange={(k) => setParams({ kind: k }, { replace: true })}
      onDone={(saved) => navigate(`${DOCUMENTS_PATH}/${encodeURIComponent(saved.id)}`)}
    />
  )
}

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
          <>
          <AssetsHelpLink topic="documents" />
          <Button variant="ghost" onClick={() => store.resetScreen(ASSET_DOCUMENTS_LAYOUT_SCREEN)} data-testid="reset-layout">
            {lm.resetLayout}
          </Button>
          </>
        }
      />
      <DocLayout screen={ASSET_DOCUMENTS_LAYOUT_SCREEN} detailOpen={mode !== 'list'} layout={layout} docState={mode === 'view' ? 'existing' : mode === 'create' ? 'new' : 'none'} docKey={`${mode}:${id ?? ''}`} data-testid="document-workspace">
        <DocumentList selectedId={mode === 'view' ? id : undefined} />
        {mode === 'list' && <DocBlank title={t('assets.doc.blank.title')} text={t('assets.doc.blank.text')} />}
        {mode === 'create' && <DocumentCreate onBack={back} />}
        {mode === 'view' && id && <DocumentView key={id} id={id} onBack={back} />}
      </DocLayout>
    </>
  )
}
