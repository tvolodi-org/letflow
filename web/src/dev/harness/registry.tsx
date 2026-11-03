/** Fixtures registry (task S0d). Every screen task adds one entry here: its name, the fake API routes it reads
 *  and a render function. Keep fixtures to plain data; no secrets, no real tenant names. */
import VerifyCertificatePage from '@/pages/VerifyCertificatePage'
import { locationsScreens } from './fixtures/locations'
import { orgLegal, orgSites, orgUnits } from './orgFixtures'
import type { HarnessScreen } from './types'

const verifyCertificate: HarnessScreen = {
  name: 'verify-certificate',
  initialPath: '/verify/demo-handle',
  routePattern: '/verify/:handle',
  routes: [
    {
      match: path => path.startsWith('/api/public/certificate/'),
      // empty: the server answers not found, the page shows its single "not valid" result.
      reply: state =>
        state === 'empty'
          ? { status: 404, body: { title: 'Not found', status: 404 } }
          : {
              status: 200,
              body: {
                candidate_name: 'Aigerim Sarsenova',
                exam_title: 'Warehouse operations, level 2',
                score_pct: 87,
                issued_on: '2026-10-30',
              },
            },
    },
  ],
  render: () => <VerifyCertificatePage />,
}

export const HARNESS_SCREENS: Record<string, HarnessScreen> = Object.fromEntries(
  [verifyCertificate, orgLegal, orgSites, orgUnits, ...locationsScreens].map(s => [s.name, s]),
)
