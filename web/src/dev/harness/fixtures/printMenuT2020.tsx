/** Harness screens of the one Print menu (T-2020): a count order's header in a narrow panel with `overflow: hidden`
 *  beside a second panel, the menu open. The popup is portaled to <body>, so neither the panel nor the divider clips it.
 *  Invented data only; no request is made. */
import type { ReactElement } from 'react'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
import { PageHeader } from '@/components/ui/PageHeader'
import { OfficialFormMenu } from '@/modules/stock/forms/OfficialFormMenu'
import { countsEn } from '@/modules/stock/counts/countsMessages'
import type { HarnessScreen } from '../types'

const noop = () => undefined
const plain = ['order', 'sheet', 'differences'].flatMap((k) => [
  { key: k, label: countsEn[`counts.paperwork.${k}`] ?? k, testId: `paperwork-${k}`, onPick: noop },
  { key: `print-${k}`, label: countsEn[`counts.print.${k}`] ?? k, testId: `print-${k}`, onPick: noop },
])
const NEED = { inv18: 'counts.form.needDifferences' }

const panels = (initialOpen: boolean): ReactElement => (
  <StockIntlProvider>
    <div className="lf-main">
      <main className="lf-content lf-content--fluid">
        <PageHeader eyebrow="Stock" title="Count order CNT-0007" lede="One Print menu per document." />
        <div className="lf-form__actions">
          <section className="lf-card" style={{ overflow: 'hidden', flex: '0 1 22rem' }}>
            <div className="lf-card__body">
              <OfficialFormMenu forms={['inv10', 'inv18']} disabledForms={NEED} plain={plain} busyKey={null} onPick={noop} initialOpen={initialOpen} />
            </div>
          </section>
          <section className="lf-card" style={{ flex: '1 1 20rem' }}>
            <div className="lf-card__body">Neighbour panel (count sheet)</div>
          </section>
        </div>
      </main>
    </div>
  </StockIntlProvider>
)

export const printMenuT2020Screens: HarnessScreen[] = [
  { name: 'print-menu-open', routes: [], render: () => panels(true) },
  { name: 'print-menu-closed', routes: [], render: () => panels(false) },
]
