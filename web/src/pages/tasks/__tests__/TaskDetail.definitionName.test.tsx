// @vitest-environment jsdom
/** T-1529: the task detail "Definition" row shows the friendly name with the technical id as a second line;
 *  a name without a catalog entry stays plain text (fallback). */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
import { TASK_MESSAGES } from '../taskMessages'
import type { UiLocale } from '@/i18n/uiLocaleStore'
expect.extend(jestDomMatchers)

let definitionName: string | undefined

vi.mock('@/hooks/useTasks', () => ({
  useTask: () => ({
    data: {
      id: 't1',
      instance_id: 'inst-1',
      token_id: 'tok',
      node_id: 'n1',
      node_name: 'Approve',
      status: 'PENDING',
      assignee_ref: null,
      assignee_type: null,
      created_at: '2026-09-24T08:00:00Z',
      definition_name: definitionName,
    },
    isLoading: false,
  }),
  useCompleteTask: () => ({ mutate: vi.fn(), isPending: false }),
  useClaimTask: () => ({ mutate: vi.fn(), isPending: false }),
}))
vi.mock('@/hooks/useTaskSubjects', () => ({ useTaskSubjects: () => () => 'subject' }))
vi.mock('@/hooks/useAttachments', () => ({ useTaskCompletionAttachments: () => ({ data: [] }) }))
vi.mock('@/hooks/useToast', () => ({ useToast: () => ({ show: vi.fn(), success: vi.fn(), error: vi.fn() }) }))
vi.mock('@/auth/access', () => ({
  P: new Proxy({}, { get: (_t, k) => String(k) }),
  useAccess: () => ({ can: () => false }),
}))
vi.mock('@/lib/references/useReferenceLabels', () => ({ useReferenceLabels: () => () => '' }))
vi.mock('../useTaskDocument', () => ({ useTaskContexts: () => () => undefined }))

import { TaskDetail } from '../TaskDetail'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'

function show(locale: UiLocale) {
  useUiLocaleStore.getState().setLocale(locale)
  render(<TaskDetail taskId="t1" onClose={vi.fn()} m={TASK_MESSAGES[locale]} locale={locale} userId="u1" />)
}

afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocale('en')
})

describe('TaskDetail definition row', () => {
  it.each([
    ['en', 'Asset write-off'],
    ['ru', 'Списание актива'],
    ['kk', 'Активті есептен шығару'],
  ] as const)('T4: catalog key shows the %s friendly name and the technical id', (locale, label) => {
    definitionName = 'assets_writeoff'
    show(locale)
    const row = screen.getByTestId('instance-definition-name')
    expect(row).toHaveTextContent(label)
    expect(screen.getByTestId('definition-technical-id')).toHaveTextContent('assets_writeoff')
  })

  it('T5: a name without a catalog entry is plain text with no second line', () => {
    definitionName = 'Onboarding Flow'
    show('en')
    expect(screen.getByTestId('instance-definition-name')).toHaveTextContent('Onboarding Flow')
    expect(screen.queryByTestId('definition-technical-id')).not.toBeInTheDocument()
  })

  it('T5b: no definition name shows a dash', () => {
    definitionName = undefined
    show('en')
    expect(screen.getByTestId('instance-definition-name')).toHaveTextContent('—')
  })
})
