/** codesRoutes — GH 3606 / REQ-672. Route objects of the codes module; registry.ts wraps them in ModuleGuard. */
import type { RouteObject } from 'react-router-dom'
import { RequirePermission } from '@/auth/access'
import CodesPage from './CodesPage'
import { CODES_WRITE } from './codesPermissions'

export const codesRouteObjects: RouteObject[] = [
  {
    path: 'admin/codes',
    children: [
      {
        index: true,
        element: (
          <RequirePermission permission={CODES_WRITE}>
            <CodesPage />
          </RequirePermission>
        ),
      },
    ],
  },
]
