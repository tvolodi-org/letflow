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
import { OfficialFormMenu } from '../forms/OfficialFormMenu'
import { OFFICIAL_FORMS, formsForOrder, type OfficialFormFormat, type OfficialFormId, type OfficialFormLang } from '../forms/officialForms'
import { countsApi, type CountForm, type CountOrder, type PaperworkKind } from './counts.api'
import { paperworkAvailable, parseFilename, printReasonMessageId, reasonMessageId } from './countsModel'

const KINDS: PaperworkKind[] = ['order', 'sheet', 'differences']

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
  // T-1418/T-1434: the official forms exist in ru and kk only; the menu passes the language (kk UI kk, else ru).
  const printForm = (form: OfficialFormId, format: OfficialFormFormat, lang: OfficialFormLang) => {
    const k: PaperworkKind = OFFICIAL_FORMS[form].countKind ?? 'sheet'
    return run(
      `form-${form}-${format}`,
      () => countsApi.printForm(order.id, k, form as CountForm, format, lang),
      `count-${label}-${form}.${format}`,
      printReasonMessageId,
    )
  }
  const download = (k: PaperworkKind) =>
    run(k, () => countsApi.paperwork(order.id, k, getUiLocale()), `count-${label}-${k}.xlsx`, reasonMessageId)
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
          </Fragment>
        ))}
        <OfficialFormMenu
          forms={formsForOrder()}
          busyKey={busyKey}
          disabledForms={{
            ...(paperworkAvailable(order, 'sheet') ? {} : { inv10: 'counts.form.needSheet' }),
            ...(paperworkAvailable(order, 'differences') ? {} : { inv18: 'counts.form.needDifferences' }),
          }}
          onPick={(form, format, lang) => void printForm(form, format, lang)}
        />
      </div>
    </div>
  )
}
