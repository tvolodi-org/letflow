/** T-1442 — icons of the side nav entries. The collapsed nav shows icons only, so every entry needs one:
 *  a lucide icon for the fixed routes, the first letter of the label (an svg glyph) for module entries with no mapping.
 *  Both are decorative (`aria-hidden`); the label text stays in the DOM and in `title`. */
import {
  Activity, BarChart3, Boxes, ClipboardList, FileCheck, FileText, FileUp, Globe, HeartPulse, Inbox,
  KeyRound, Layers, ListTodo, Package, Puzzle, ScrollText, Server, ShieldCheck, Users, UsersRound, Webhook, Workflow,
  Building2, History, Hourglass, PackageCheck, type LucideIcon,
} from 'lucide-react'

const ICONS: Record<string, LucideIcon> = {
  '/instances': Workflow,
  '/tasks': ListTodo,
  '/definitions': FileText,
  '/reports': BarChart3,
  '/promotions': FileCheck,
  '/dlq': Inbox,
  '/webhooks': Webhook,
  '/admin/users': Users,
  '/admin/groups': UsersRound,
  '/admin/tokens': KeyRound,
  '/admin/audit': ScrollText,
  '/admin/print-templates': ClipboardList,
  '/admin/import': FileUp,
  '/admin/module-lifecycle': Layers,
  '/admin/health': HeartPulse,
  '/admin/metrics': BarChart3,
  '/admin/onboarding/new': Building2,
  '/admin/tenants': Globe,
  '/admin/services': Server,
  '/admin/module-rollouts': PackageCheck,
  '/admin/platform-migrations': Activity,
  '/solution-packs': Puzzle,
  '/admin/event-retention': Hourglass,
  '/admin/codes': ShieldCheck,
  '/stock': Boxes,
  '/stock/journal': History,
  '/assets': Package,
}

/** Nav icon for a route; an entry with no mapping gets the first letter of its label as a glyph. */
export function NavIcon({ to, label }: { to: string; label: string }) {
  const Icon = ICONS[to]
  if (Icon) return <Icon className="lf-icon lf-icon--18" aria-hidden="true" />
  const letter = (label.trim().charAt(0) || '•').toUpperCase()
  return (
    <svg className="lf-icon lf-icon--18" viewBox="0 0 24 24" aria-hidden="true" data-testid="nav-glyph">
      <text x="12" y="17" textAnchor="middle" fontSize="15" fontWeight="600" fill="currentColor">
        {letter}
      </text>
    </svg>
  )
}
