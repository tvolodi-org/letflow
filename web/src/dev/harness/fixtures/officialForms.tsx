/** Harness screens of the "Official form" menu (task T-1434, E5e): the menu open in the action row of an issue
 *  document (Z-2) and of a count order (Inv-10 and Inv-18). Invented data only; no request is made. */
import type { ReactElement } from 'react'
import { StockIntlProvider } from '@/modules/stock/StockIntlProvider'
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

export const officialFormsScreens: HarnessScreen[] = [
  { name: 'official-form-z2', routes: [], render: () => shell(<OfficialFormMenu forms={['z2']} busyKey={null} onPick={() => undefined} initialOpen />) },
  {
    name: 'official-form-inv',
    routes: [],
    render: () => shell(<OfficialFormMenu forms={['inv10']} busyKey={null} onPick={() => undefined} testIdSuffix="sheet" initialOpen />),
  },
]
