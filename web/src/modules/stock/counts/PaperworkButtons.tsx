/** PaperworkButtons — GH 3761 / REQ-720 criterion 4. One download button per issued paperwork document (order, sheet,
 *  differences). The xlsx comes through client.getBlob (bearer header) and is saved under the file name of the
 *  Content-Disposition header, else count-<kind>.xlsx. */
import { Fragment } from 'react'
import { useIntl } from 'react-intl'
import { Download, Printer } from 'lucide-react'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { usePdfDownload } from '../register/usePdfDownload'
import { countsApi, type CountForm, type CountFormFormat, type CountOrder, type PaperworkKind } from './counts.api'
import { paperworkAvailable, parseFilename, printReasonMessageId, reasonMessageId } from './countsModel'

const KINDS: PaperworkKind[] = ['order', 'sheet', 'differences']
/** T-1418: the official form that belongs to a document kind (Inv-18 on the differences, Inv-10 on the sheet). */
const FORM_OF: Partial<Record<PaperworkKind, CountForm>> = { differences: 'inv18', sheet: 'inv10' }
const FORMATS: CountFormFormat[] = ['docx', 'pdf']

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
  const { busyKey, error, run } = usePdfDownload(parseFilename)
  const shown = KINDS.filter((k) => paperworkAvailable(order, k))
  if (shown.length === 0) return null

  const label = order.number ?? order.id
  // REQ-738: the print language is the UI language at the moment of the click.
  const print = (k: PaperworkKind) =>
    run(`print-${k}`, () => countsApi.print(order.id, k, getUiLocale()), `count-${label}-${k}.pdf`, printReasonMessageId)
  // T-1418: the official forms exist in ru and kk only; the Kazakh UI prints kk, any other UI ru.
  const printForm = (k: PaperworkKind, form: CountForm, format: CountFormFormat) =>
    run(
      `form-${form}-${format}`,
      () => countsApi.printForm(order.id, k, form, format, getUiLocale() === 'kk' ? 'kk' : 'ru'),
      `count-${label}-${form}.${format}`,
      printReasonMessageId,
    )
  const download = (k: PaperworkKind) =>
    run(k, () => countsApi.paperwork(order.id, k), `count-${label}-${k}.xlsx`, reasonMessageId)
  return (
    <div className="lf-form" data-testid="paperwork">
      {error !== null && <Banner tone="danger">{t(error)}</Banner>}
      <div className="lf-form__actions">
        {shown.map((k) => (
          <Fragment key={k}>
            <Button
              variant="secondary"
              size="sm"
              icon={<Download className="lf-icon" aria-hidden="true" />}
              loading={busyKey === k}
              onClick={() => void download(k)}
              data-testid={`paperwork-${k}`}
            >
              {t(`counts.paperwork.${k}`)}
            </Button>
            <Button
              variant="secondary"
              size="sm"
              icon={<Printer className="lf-icon" aria-hidden="true" />}
              loading={busyKey === `print-${k}`}
              onClick={() => void print(k)}
              data-testid={`print-${k}`}
            >
              {t(`counts.print.${k}`)}
            </Button>
            {FORMATS.map((format) => {
              const form = FORM_OF[k]
              return form === undefined ? null : (
                <Button
                  key={`${form}-${format}`}
                  variant="secondary"
                  size="sm"
                  icon={format === 'pdf' ? <Printer className="lf-icon" aria-hidden="true" /> : <Download className="lf-icon" aria-hidden="true" />}
                  loading={busyKey === `form-${form}-${format}`}
                  onClick={() => void printForm(k, form, format)}
                  data-testid={`form-${form}-${format}`}
                >
                  {t(`counts.form.${form}.${format}`)}
                </Button>
              )
            })}
          </Fragment>
        ))}
      </div>
    </div>
  )
}
