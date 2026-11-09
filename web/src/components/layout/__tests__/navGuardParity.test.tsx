// @vitest-environment jsdom
/**
 * T-1522 / D-114(1) N10: a nav entry declares the permission its page needs, and the page's own route guard
 * (RequirePermission) must name the same permission: one source, next to the route, machine-checked.
 * Entries whose page has no RequirePermission are listed in NO_GUARD; the server refuses those calls itself.
 */
import { isValidElement, type ReactElement, type ReactNode } from 'react'
import type { RouteObject } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import { RequirePermission } from '@/auth/access'
import { appRoutes } from '@/router'
import { REGISTERED_MODULES } from '@/modules/registry'
import { NAV_ITEMS } from '../AppShell'

interface Guard {
  permission: string
  platformOnly: boolean
}

function findGuard(node: ReactNode): Guard | null {
  if (!isValidElement(node)) return null
  const el = node as ReactElement<{ permission?: string; platformOnly?: boolean; children?: ReactNode }>
  if (el.type === RequirePermission) return { permission: String(el.props.permission), platformOnly: !!el.props.platformOnly }
  return findGuard(el.props.children)
}

/** Flat map (an index route is registered under its parent's path): full path -> guard (null when the page has none). Pathless wrappers (ModuleGuard) add no segment. */
function collect(routes: RouteObject[], prefix: string, out: Map<string, Guard | null>) {
  for (const r of routes) {
    const here = r.path ? `${prefix}/${r.path}`.replace(/\/+/g, '/') : prefix
    if ((r.path || r.index) && r.element) out.set(here, findGuard(r.element))
    if (r.children) collect(r.children, here, out)
  }
}

const guards = new Map<string, Guard | null>()
collect(appRoutes, '', guards)

/** Entries whose route has no RequirePermission (the server enforces the entry's permission on the page's calls). */
const NO_GUARD = new Set([
  '/instances', '/tasks', '/definitions', '/promotions', '/admin/metrics', '/solution-packs', '/admin/module-lifecycle',
  '/exam', '/admin/questions',
])

const entries = [
  ...NAV_ITEMS.map((n) => ({ to: n.to, permission: String(n.permission), platformOnly: !!n.platformOnly })),
  ...REGISTERED_MODULES.flatMap((m) => m.navItems.map((n) => ({ to: n.to, permission: n.permission, platformOnly: !!n.platformOnly }))),
]

describe('N10 nav entry permission equals its route guard', () => {
  it.each(entries.map((e) => [e.to, e] as const))('%s', (to, e) => {
    const guard = guards.get(to)
    if (guard === undefined) throw new Error(`no route object found for nav entry ${to}`)
    if (guard === null) {
      expect(NO_GUARD.has(to), `${to} has no RequirePermission and is not listed in NO_GUARD`).toBe(true)
      return
    }
    expect(NO_GUARD.has(to), `${to} has a guard now: remove it from NO_GUARD`).toBe(false)
    expect(guard.permission).toBe(e.permission)
    expect(guard.platformOnly).toBe(e.platformOnly)
  })
})
