/** Harness screens of the "Official form" menu (task T-1434, E5e): the menu open in the action row of an issue
 *  document (Z-2) and of a count order (Inv-10 and Inv-18). T-1912 adds Z-1 for receipts. Invented data only; no request is made. */
import type { ReactElement } from 'react'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { Banner } from '@/components/ui/Banner'
import { PageHeader } from '@/components/ui/PageHeader'
import { OfficialFormMenu } from '@/modules/stock/forms/OfficialFormMenu'
import type { HarnessScreen } from '../types'

const shell = (children: ReactElement): ReactElement => (
  <StockIntlProvider>
    <div className="lf-main">
      <main className="lf-content">
        <div className="lf-form__actions">
          {children}
        </div>
      </main>
    </div>
  </StockIntlProvider>
)

/** The real position: the menu in the right-hand action row of a PageHeader (the clipping complaint, T-1441). */
const headed = (title: string, children: ReactElement): ReactElement => (
  <StockIntlProvider>
    <div className="lf-main">
      <main className="lf-content">
        <PageHeader eyebrow="Stock" title={title} lede="Official forms are in one menu." actions={children} />
      </main>
    </div>
  </StockIntlProvider>
)

const noop = () => undefined
const NEED = { inv10: 'counts.form.needSheet', inv18: 'counts.form.needDifferences' }

export const officialFormsScreens: HarnessScreen[] = [
  { name: 'official-form-z2', routes: [], render: () => shell(<OfficialFormMenu forms={['z2']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'docs-z2-menu-open', routes: [], render: () => shell(<OfficialFormMenu forms={['z2']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'docs-z2-menu-right', routes: [], render: () => headed('Issue note', <OfficialFormMenu forms={['z2']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'docs-z5-menu-right', routes: [], render: () => headed('Transfer', <OfficialFormMenu forms={['z5']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'docs-z1-menu-right', routes: [], render: () => headed('Receipt', <OfficialFormMenu forms={['z1']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'balances-z3-hint', routes: [], render: () => headed('Balances', <><OfficialFormMenu forms={['z3']} disabledForms={{ z3: 'stock.balances.cardHint' }} busyKey={null} onPick={noop} initialOpen /></>) },
  { name: 'balances-z3-ready', routes: [], render: () => headed('Balances', <OfficialFormMenu forms={['z3']} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'balances-z3-closed', routes: [], render: () => headed('Balances', <OfficialFormMenu forms={['z3']} disabledForms={{ z3: 'stock.balances.cardHint' }} busyKey={null} onPick={noop} />) },
  { name: 'docs-z2-busy', routes: [], render: () => shell(<OfficialFormMenu forms={['z2']} busyKey="form-z2-pdf" onPick={noop} />) },
  { name: 'docs-z2-error', routes: [], render: () => shell(<><Banner tone="danger">The form could not be created.</Banner><OfficialFormMenu forms={['z2']} busyKey={null} onPick={noop} /></>) },
  { name: 'count-order-only', routes: [], render: () => shell(<OfficialFormMenu forms={['inv10', 'inv18']} disabledForms={NEED} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'count-sheet-issued', routes: [], render: () => shell(<OfficialFormMenu forms={['inv10', 'inv18']} disabledForms={{ inv18: NEED.inv18 }} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'count-differences-issued', routes: [], render: () => shell(<OfficialFormMenu forms={['inv10', 'inv18']} disabledForms={{ inv10: NEED.inv10 }} busyKey={null} onPick={noop} initialOpen />) },
  { name: 'count-busy', routes: [], render: () => shell(<OfficialFormMenu forms={['inv10', 'inv18']} busyKey="form-inv10-pdf" onPick={noop} />) },
  { name: 'count-error', routes: [], render: () => shell(<><Banner tone="danger">The form could not be created.</Banner><OfficialFormMenu forms={['inv10', 'inv18']} busyKey={null} onPick={noop} initialOpen /></>) },
  { name: 'count-menu-right', routes: [], render: () => headed('Count order', <OfficialFormMenu forms={['inv10', 'inv18']} disabledForms={{ inv18: NEED.inv18 }} busyKey={null} onPick={noop} initialOpen />) },
]
