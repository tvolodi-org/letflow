// @vitest-environment jsdom
/** C1–C7 — T-1691: static help of four core screens (users import, password reset, instance replay, module rollouts):
 *  catalogue completeness, text quality, route, permission, links from the screens. */
import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import { helpIds } from '@/components/help/helpTopicText'
import { useUiLocaleStore, type UiLocale } from '@/i18n/uiLocaleStore'
import UsersImportPage from '@/pages/admin/usersImport/UsersImportPage'
import ModuleRolloutsPage from '@/pages/admin/module-rollouts/ModuleRolloutsPage'
import { router } from '@/router'
import CoreHelpPage from '../CoreHelpPage'
import { coreHelpMessages } from '../coreHelpMessages'
import { CORE_HELP_TOPICS, coreHelpPath } from '../coreHelpTopics'

expect.extend(jestDomMatchers)

const clientMock = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), postRaw: vi.fn(), getBlob: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-1' }, isAuthenticated: true }),
}))
vi.mock('@/api/useTenantScopedQueryKeys', async () => {
  const { queryKeys: qk } = await import('@/api/queryKeys')
  return { useTenantScopedQueryKeys: () => ({ moduleRollouts: { all: () => qk.moduleRollouts.all('t1'), list: () => qk.moduleRollouts.list('t1'), status: (id: string) => qk.moduleRollouts.status('t1', id) } }) }
})

const LOCALES: UiLocale[] = ['en', 'ru', 'kk']
const access = (permissions: string[], platform = false): AccessState => ({ status: 'ready', info: { roles: [], platform_tenant: platform, permissions } })

beforeEach(() => {
  clientMock.get.mockResolvedValue({ rollouts: [], items: [] })
  useUiLocaleStore.getState().setLocaleTransient('en')
})
afterEach(() => cleanup())

function renderHelp(path: string, state: AccessState) {
  return render(
    <AccessStateProvider state={state}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="help/:topic" element={<CoreHelpPage />} />
        </Routes>
      </MemoryRouter>
    </AccessStateProvider>,
  )
}

const helpKeys = (l: UiLocale) => Object.keys(coreHelpMessages[l])

describe('C1 catalogue', () => {
  it('has every id of the fixed shape, non-empty, for every topic and locale; ru/kk differ from en', () => {
    for (const l of LOCALES) {
      for (const topic of CORE_HELP_TOPICS) {
        for (const id of helpIds('core', topic)) {
          expect(coreHelpMessages[l][id], `${l} ${id}`).toBeTruthy()
          if (l !== 'en') expect(coreHelpMessages[l][id], `${l} ${id}`).not.toBe(coreHelpMessages.en[id])
        }
      }
      for (const id of ['link', 'back', 'h.purpose', 'h.tasks', 'h.refusals']) expect(coreHelpMessages[l][`core.help.${id}`], `${l} ${id}`).toBeTruthy()
    }
  })
  it('the topic list equals the topics present in the catalogue', () => {
    const present = new Set(helpKeys('en').map((k) => k.split('.')[2]).filter((p) => p !== 'link' && p !== 'back' && p !== 'h'))
    expect([...present].sort()).toEqual([...CORE_HELP_TOPICS].sort())
  })
})

describe('C2 text quality', () => {
  it('has no code-like words, no markup, no stray Latin inside Cyrillic words, short tasks and refusals', () => {
    for (const l of LOCALES) {
      for (const id of helpKeys(l)) {
        const text = coreHelpMessages[l][id]
        expect(text, id).not.toMatch(/\b[a-z]+_[a-z_]+\b/)
        expect(text, id).not.toMatch(/undefined|!\[|<img/)
        expect(text, id).not.toMatch(/[Ѐ-ӿ][a-z]|[a-z][Ѐ-ӿ]/)
        if (/\.task\d$/.test(id)) expect(text.length, id).toBeLessThanOrEqual(190)
        if (/\.ref\d\./.test(id)) expect(text.length, id).toBeLessThanOrEqual(300)
      }
    }
  })
})

describe('C3 route', () => {
  it.each([
    ['en', 'Help: import users', 'Three common tasks'],
    ['ru', 'Справка: импорт пользователей', 'Три частые задачи'],
    ['kk', 'Анықтама: пайдаланушыларды импорттау', 'Үш жиі міндет'],
  ] as const)('renders the users import topic in %s', (locale, title, tasks) => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
    const { container } = renderHelp(coreHelpPath('usersImport'), access(['UsersGroupsRolesManage']))
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(title)
    expect(screen.getByRole('heading', { name: tasks })).toBeInTheDocument()
    expect(screen.getByTestId('help-tasks-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-refusals-list').children).toHaveLength(3)
    expect(screen.getByTestId('help-back')).toHaveAttribute('href', '/admin/users/import')
    expect(container.querySelector('img')).toBeNull()
  })
  it('every topic renders and links back to its screen', () => {
    const back = { usersImport: '/admin/users/import', passwordReset: '/admin/users', instanceReplay: '/instances', moduleRollouts: '/admin/module-rollouts', createSignIn: '/admin/users' }
    for (const topic of CORE_HELP_TOPICS) {
      const { unmount } = renderHelp(coreHelpPath(topic), access(['UsersGroupsRolesManage', 'ModuleRolloutsManage'], true))
      expect(screen.getByTestId('help-topic')).toBeInTheDocument()
      expect(screen.getByTestId('help-back')).toHaveAttribute('href', back[topic])
      unmount()
    }
  })
  it('an unknown topic is the not-found page', () => {
    renderHelp('/help/nope', access([]))
    expect(screen.getByTestId('not-found-page')).toBeInTheDocument()
  })
  it('the route is registered in the app router', () => {
    const root = router.routes.find((r) => r.path === '/')
    expect((root?.children ?? []).some((r) => r.path === 'help/:topic')).toBe(true)
  })
})

describe('C4 permission', () => {
  it.each(['usersImport', 'passwordReset', 'createSignIn'] as const)('%s needs UsersGroupsRolesManage', (topic) => {
    renderHelp(coreHelpPath(topic), access([]))
    expect(screen.queryByTestId('help-topic')).toBeNull()
  })
  it('moduleRollouts needs the permission in the platform tenant', () => {
    renderHelp(coreHelpPath('moduleRollouts'), access(['ModuleRolloutsManage'], false))
    expect(screen.queryByTestId('help-topic')).toBeNull()
    cleanup()
    renderHelp(coreHelpPath('moduleRollouts'), access(['ModuleRolloutsManage'], true))
    expect(screen.getByTestId('help-topic')).toBeInTheDocument()
  })
  it('instanceReplay has no guard of its own, as the instance screens', () => {
    renderHelp(coreHelpPath('instanceReplay'), access([]))
    expect(screen.getByTestId('help-topic')).toBeInTheDocument()
  })
})

describe('C5 links from the screens', () => {
  it('the users import screen shows a Help link to its topic', () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <UsersImportPage />
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(screen.getByTestId('help-link')).toHaveAttribute('href', coreHelpPath('usersImport'))
  })
  it('the module rollouts screen shows a Help link to its topic', () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <ModuleRolloutsPage />
        </MemoryRouter>
      </QueryClientProvider>,
    )
    expect(screen.getByTestId('help-link')).toHaveAttribute('href', coreHelpPath('moduleRollouts'))
  })
  it.each([
    ['../../admin/UserDetailPage.tsx', 'passwordReset'],
    ['../../instances/InstanceDetailPage.tsx', 'instanceReplay'],
  ])('%s carries the link to the %s topic (heavy page, source check)', (file, topic) => {
    const src = readFileSync(new URL(file, import.meta.url), 'utf8')
    expect(src).toContain(`<CoreHelpLink topic="${topic}" />`)
  })
})

describe('C6 accuracy', () => {
  it('create sign-in says: shown once, hand over safely, changed at first sign-in, may be unavailable', () => {
    const want = {
      en: [/once/, /safely/, /change the password at the first sign-in/, /not available/],
      ru: [/один раз/, /безопасно/, /сменить пароль/, /недоступно/],
      kk: [/бір рет/, /қауіпсіз/, /ауыстыру/, /қолжетімсіз/],
    } as const
    for (const l of LOCALES) {
      const text = Object.entries(coreHelpMessages[l]).filter(([k]) => k.startsWith('core.help.createSignIn.')).map(([, v]) => v).join(' ')
      for (const re of want[l]) expect(text, `${l} ${re}`).toMatch(re)
    }
  })
  it('names the buttons as the screens do', () => {
    const rollouts = {
      en: ['Start rollout', 'Resume'],
      ru: ['Начать развёртывание', 'Продолжить'],
      kk: ['Таратуды бастау', 'Жалғастыру'],
    } as const
    for (const l of LOCALES) {
      const tasks = [1, 2, 3].map((n) => coreHelpMessages[l][`core.help.moduleRollouts.task${n}`]).join(' ')
      for (const label of rollouts[l]) expect(tasks, `${l} ${label}`).toContain(label)
    }
  })
  it('says the import limits as the screen does', () => {
    expect(coreHelpMessages.en['core.help.usersImport.ref1.body']).toMatch(/200/)
    expect(coreHelpMessages.en['core.help.usersImport.ref1.body']).toMatch(/2 MB/)
  })
})
