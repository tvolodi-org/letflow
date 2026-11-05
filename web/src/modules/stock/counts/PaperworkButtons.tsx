/** PaperworkButtons — GH 3761 / REQ-720 criterion 4. One download button per issued paperwork document (order, sheet,
 *  differences). The xlsx comes through client.getBlob (bearer header) and is saved under the file name of the
 *  Content-Disposition header, else count-<kind>.xlsx. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Download } from 'lucide-react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { countsApi, type CountOrder, type PaperworkKind } from './counts.api'
import { paperworkAvailable, parseFilename, reasonMessageId } from './countsModel'

const KINDS: PaperworkKind[] = ['order', 'sheet', 'differences']

export function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

export function PaperworkButtons({ order }: { order: CountOrder }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [busy, setBusy] = useState<PaperworkKind | null>(null)
  const [error, setError] = useState<string | null>(null)
  const shown = KINDS.filter((k) => paperworkAvailable(order, k))
  if (shown.length === 0) return null

  async function download(kind: PaperworkKind) {
    if (busy !== null) return
    setBusy(kind)
    setError(null)
    try {
      const { blob, contentDisposition } = await countsApi.paperwork(order.id, kind)
      saveBlob(blob, parseFilename(contentDisposition, `count-${order.number ?? order.id}-${kind}.xlsx`))
    } catch (err) {
      setError(t(reasonMessageId(err)))
    } finally {
      setBusy(null)
    }
  }
  return (
    <div className="lf-form" data-testid="paperwork">
      {error !== null && <Banner tone="danger">{error}</Banner>}
      <div className="lf-form__actions">
        {shown.map((k) => (
          <Button
            key={k}
            variant="secondary"
            size="sm"
            icon={<Download className="lf-icon" aria-hidden="true" />}
            loading={busy === k}
            onClick={() => void download(k)}
            data-testid={`paperwork-${k}`}
          >
            {t(`counts.paperwork.${k}`)}
          </Button>
        ))}
      </div>
    </div>
  )
}
