/** assetsRoutes — T-1333 / C13, T-1334 / C14. Route objects of the assets module; registry.ts wraps them in ModuleGuard. */
import type { ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import AssetCardsPage from './AssetCardsPage'
import DocumentNewPage from './documents/DocumentNewPage'
import DocumentPage from './documents/DocumentPage'
import DocumentsPage from './documents/DocumentsPage'
import BalancesPage from './register/BalancesPage'
import MovementsPage from './register/MovementsPage'
import { ASSETS_CARD_WRITE, ASSETS_POST, ASSETS_READ } from './assetsPermissions'

function guard(page: ReactNode, permission: string = ASSETS_CARD_WRITE) {
  return <RequirePermission permission={permission}>{page}</RequirePermission>
}

export const assetsRouteObjects: RouteObject[] = [
  {
    path: 'admin/assets',
    children: [
      { path: 'cards', element: guard(<AssetCardsPage />) },
      { path: 'documents', element: guard(<DocumentsPage />, ASSETS_READ) },
      { path: 'documents/new', element: guard(<DocumentNewPage />, ASSETS_POST) },
      { path: 'documents/:id', element: guard(<DocumentPage />, ASSETS_READ) },
      { path: 'balances', element: guard(<BalancesPage />, ASSETS_READ) },
      { path: 'movements', element: guard(<MovementsPage />, ASSETS_READ) },
    ],
  },
]
