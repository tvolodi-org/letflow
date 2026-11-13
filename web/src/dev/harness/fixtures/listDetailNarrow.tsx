/** Harness fixtures for the ListDetail component at narrow widths (T-1886). Used to capture the
 *  390 px open state which requires a synchronous render (no async API). */
import type { ReactElement } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { ListDetail } from '@/components/ui/listDetail'
import type { HarnessScreen } from '../types'
import { AUTH } from './stockDocuments'

function page(children: ReactElement) {
  return (
    <AuthContext.Provider value={AUTH}>
      <div className="lf-main">
        <main className="lf-content lf-content--fluid">
          <LayoutPrefsProvider>{children}</LayoutPrefsProvider>
        </main>
      </div>
    </AuthContext.Provider>
  )
}

/** ListDetail with no row selected (empty state). */
const ClosedShell = () => (
  <ListDetail
    screen="list-detail-harness"
    listLabel="Items"
    list={
      <table>
        <tbody>
          <tr><td>Item A</td></tr>
          <tr><td>Item B</td></tr>
          <tr><td>Item C</td></tr>
        </tbody>
      </table>
    }
    detail={<p>Detail content</p>}
    detailOpen={false}
    onClose={() => {}}
  />
)

/** ListDetail with a row selected (the detail pane is shown; at 390 px the detail replaces the list). */
const OpenShell = () => (
  <ListDetail
    screen="list-detail-harness"
    listLabel="Items"
    list={
      <table>
        <tbody>
          <tr><td>Item A</td></tr>
          <tr><td>Item B</td></tr>
          <tr><td>Item C</td></tr>
        </tbody>
      </table>
    }
    detail={
      <div style={{ padding: 16 }}>
        <h2>Record: Item A</h2>
        <p>Location: Warehouse 1</p>
        <p>Quantity: 42.000</p>
      </div>
    }
    detailOpen
    onClose={() => {}}
  />
)

export const listDetailNarrowScreens: HarnessScreen[] = [
  { name: 'list-detail-narrow', routes: [], render: () => page(<ClosedShell />) },
  { name: 'list-detail-narrow-open', routes: [], render: () => page(<OpenShell />) },
]
