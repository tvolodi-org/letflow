/** DocumentNewPage — GH 3769 / REQ-722. A new draft; the query key `kind` picks receipt, issue or write_off
 *  (anything else opens a receipt). On a created draft it opens the document view. */
import { useIntl } from 'react-intl'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { PageHeader } from '@/components/ui/PageHeader'
import { Select } from '@/components/ui/Select'
import { StockIntlProvider } from '../StockIntlProvider'
import { DocumentForm, useOpenDocument } from './DocumentForm'
import { DOC_KINDS, type DocKind } from './documentsModel'

function NewInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [search, setSearch] = useSearchParams()
  const navigate = useNavigate()
  const open = useOpenDocument()
  const raw = search.get('kind') ?? ''
  const kind: DocKind = (DOC_KINDS as readonly string[]).includes(raw) ? (raw as DocKind) : 'receipt'
  return (
    <>
      <PageHeader eyebrow={t('stock.eyebrow')} title={t('stock.doc.newTitle')} lede={t('stock.doc.newLede')} />
      <Select
        label={t('stock.doc.col.kind')}
        value={kind}
        onChange={(k) => setSearch({ kind: k }, { replace: true })}
        options={DOC_KINDS.map((k) => ({ value: k, label: t(`stock.doc.kind.${k}`) }))}
      />
      {/* key: a kind change starts a fresh form (its fields differ). */}
      <DocumentForm key={kind} kind={kind} onDone={open} onCancel={() => navigate('/admin/stock/documents')} />
    </>
  )
}

export default function DocumentNewPage() {
  return (
    <StockIntlProvider>
      <NewInner />
    </StockIntlProvider>
  )
}
