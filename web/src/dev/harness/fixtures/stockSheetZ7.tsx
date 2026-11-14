/** Harness screens of the Z-7 balances sheet entry (T-1925): the "Official form" menu with Z-3 and Z-7 on the balances
 *  header, and the period dialog in its states. Invented data only; no request is made. */
import type { ReactElement } from 'react'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { Banner } from '@/components/ui/Banner'
import { PageHeader } from '@/components/ui/PageHeader'
import { OfficialFormMenu } from '@/modules/stock/forms/OfficialFormMenu'
import { SheetPeriodDialog } from '@/modules/stock/register/SheetPeriodDialog'
import { useIntl } from 'react-intl'
import type { HarnessScreen } from '../types'

const noop = () => undefined

const headed = (children: ReactElement, extra?: ReactElement): ReactElement => (
  <StockIntlProvider>
    <div className="lf-main">
      <main className="lf-content">
        <PageHeader eyebrow="Stock" title="Balances" lede="Official forms are in one menu." actions={children} />
        {extra}
      </main>
    </div>
  </StockIntlProvider>
)

function SheetError(): ReactElement {
  const intl = useIntl()
  return <Banner tone="danger">{intl.formatMessage({ id: 'stock.balances.sheetEmpty' }, { from: '01.11.2026', to: '14.11.2026' })}</Banner>
}

const dialog = (from: string, to: string): ReactElement =>
  headed(
    <OfficialFormMenu forms={['z3', 'z7']} busyKey={null} onPick={noop} />,
    <SheetPeriodDialog open initialFrom={from} initialTo={to} today="2026-11-14" onConfirm={noop} onCancel={noop} />,
  )

export const stockSheetZ7Screens: HarnessScreen[] = [
  {
    name: 'balances-z7-hint',
    routes: [],
    render: () => headed(<OfficialFormMenu forms={['z3', 'z7']} disabledForms={{ z3: 'stock.balances.cardHint', z7: 'stock.balances.sheetHint' }} busyKey={null} onPick={noop} initialOpen />),
  },
  {
    name: 'balances-z7-ready',
    routes: [],
    render: () => headed(<OfficialFormMenu forms={['z3', 'z7']} disabledForms={{ z3: 'stock.balances.cardHint' }} busyKey={null} onPick={noop} initialOpen />),
  },
  { name: 'balances-z7-dialog', routes: [], render: () => dialog('2026-11-01', '2026-11-14') },
  { name: 'balances-z7-invalid', routes: [], render: () => dialog('2026-11-20', '2026-11-14') },
  { name: 'balances-z7-busy', routes: [], render: () => headed(<OfficialFormMenu forms={['z3', 'z7']} busyKey="form-z7-pdf" onPick={noop} />) },
  {
    name: 'balances-z7-error',
    routes: [],
    render: () => headed(<OfficialFormMenu forms={['z3', 'z7']} busyKey={null} onPick={noop} />, <SheetError />),
  },
]
