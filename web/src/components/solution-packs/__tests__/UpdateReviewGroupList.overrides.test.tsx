// @vitest-environment jsdom
/** REQ-631 part B — override outcomes in UpdateReviewGroupList. S0 snapshot taken on unmodified code. */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, fireEvent } from '@testing-library/react'
import { UpdateReviewGroupList } from '../UpdateReviewGroupList'
import type { PackResolutionChoice, PackUpdateAppliedEntry, PackUpdateReviewEntry } from '@/api/solutionPacks'

expect.extend(jestDomMatchers)

afterEach(() => {
  cleanup()
})

const entries: PackUpdateReviewEntry[] = [
  { artefact_type: 'process_definition', artefact_id: 'a', classification: 'unchanged', resolved: true },
  { artefact_type: 'process_definition', artefact_id: 'b', classification: 'safe_to_update', resolved: false },
  { artefact_type: 'process_definition', artefact_id: 'c', classification: 'local_only', resolved: false },
  { artefact_type: 'process_definition', artefact_id: 'd', classification: 'both_sides_conflict', resolved: false },
  { artefact_type: 'process_definition', artefact_id: 'e', classification: 'both_sides_conflict', resolved: true },
]
const applied: PackUpdateAppliedEntry[] = [
  { artefact_type: 'process_definition', artefact_id: 'd', classification: 'both_sides_conflict', action: 'left_unchanged' },
]

describe('REQ-631 part B S0', () => {
  it('S0 entries without override keys render as before', () => {
    const { container } = render(
      <UpdateReviewGroupList
        entries={entries}
        resolutionChoices={new Map<string, PackResolutionChoice>([['process_definition:d', 'keep_local']])}
        onChooseResolution={vi.fn()}
        attribution={new Map()}
        appliedEntries={applied}
      />,
    )
    expect(container.innerHTML).toMatchSnapshot()
  })
})

// ── override rendering (O1, O2, O3, O5, I2) ─────────────────────────────────

import { screen, within } from '@testing-library/react'
import { IntlProvider } from 'react-intl'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import type { PackUpdateOverride } from '@/api/solutionPacks'

const T = entitiesMessages.en

function ov(outcome: PackUpdateOverride['outcome'], warning?: PackUpdateOverride['warning']): PackUpdateOverride {
  return { override_id: 'o1', override_version: 2, made_against: '1.0.0', outcome, ...(warning ? { warning } : {}) }
}

function renderOv(
  list: PackUpdateReviewEntry[],
  extra: Partial<React.ComponentProps<typeof UpdateReviewGroupList>> = {},
  locale: 'en' | 'ru' | 'kk' = 'en',
) {
  return render(
    <IntlProvider locale={locale} messages={entitiesMessages[locale]}>
      <UpdateReviewGroupList
        entries={list}
        resolutionChoices={new Map()}
        onChooseResolution={vi.fn()}
        attribution={new Map()}
        appliedEntries={null}
        {...extra}
      />
    </IntlProvider>,
  )
}

const e = (id: string, classification: PackUpdateReviewEntry['classification'], over: Partial<PackUpdateReviewEntry>) =>
  ({ artefact_type: 'process_definition', artefact_id: id, classification, resolved: false, ...over }) as PackUpdateReviewEntry

describe('REQ-631 part B outcomes', () => {
  it('O1 kept shows its label; the warning only when present', () => {
    renderOv([e('k1', 'safe_to_update', { override: ov('kept') }), e('k2', 'local_only', { override: ov('kept', 'override_kept_pack_changed') })])
    const notes = screen.getAllByTestId('update-review-override-outcome')
    expect(notes).toHaveLength(2)
    expect(notes[0]).toHaveTextContent(T['solutionOverrides.report.outcome.kept'])
    expect(within(notes[0]).queryByTestId('update-review-override-warning')).toBeNull()
    expect(within(notes[1]).getByTestId('update-review-override-warning')).toHaveTextContent(
      T['solutionOverrides.report.warning.override_kept_pack_changed'],
    )
  })

  it('O2 override_conflict: keep and take radios, no merged radio, counted once', () => {
    const choose = vi.fn()
    renderOv(
      [
        e('c1', 'safe_to_update', { override: ov('override_conflict') }),
        e('c2', 'both_sides_conflict', { override: ov('override_conflict') }),
      ],
      { onChooseResolution: choose },
    )
    expect(screen.getAllByTestId('update-review-resolution-control')).toHaveLength(2)
    expect(screen.getAllByTestId('update-review-resolution-keep-local')).toHaveLength(2)
    expect(screen.getAllByTestId('update-review-resolution-take-incoming')).toHaveLength(2)
    expect(screen.getAllByRole('radio')).toHaveLength(4)
    const block = screen.getByTestId('update-review-override-conflict-needs-decision')
    expect(within(block).getAllByTestId('update-review-resolution-control')).toHaveLength(1)
    expect(screen.getByTestId('update-review-group-safe_to_update')).toHaveTextContent('Safe to update (0)')
    fireEvent.click(within(block).getByTestId('update-review-resolution-take-incoming'))
    expect(choose).toHaveBeenCalledWith('process_definition', 'c1', 'take_incoming')
  })

  it('O3 orphaned and property_gone are labelled and non-blocking', () => {
    renderOv([e('o1', 'safe_to_update', { override: ov('orphaned') }), e('p1', 'local_only', { override: ov('property_gone') })])
    const notes = screen.getAllByTestId('update-review-override-outcome')
    expect(notes[0]).toHaveTextContent(T['solutionOverrides.report.outcome.orphaned'])
    expect(notes[1]).toHaveTextContent(T['solutionOverrides.report.outcome.property_gone'])
    expect(screen.getAllByTestId('update-review-override-nonblocking')).toHaveLength(2)
    expect(screen.queryAllByRole('radio')).toHaveLength(0)
  })

  it('O5 applied override actions each show their label; no panel without override_action', () => {
    const actions = ['advanced', 'retired', 'orphaned', 'property_gone', 'left_unchanged'] as const
    const applied5: PackUpdateAppliedEntry[] = actions.map((a) => ({
      artefact_type: 'process_definition',
      artefact_id: `x-${a}`,
      classification: 'safe_to_update',
      action: 'advanced_to_incoming',
      override_action: a,
    }))
    const { unmount } = renderOv([], { appliedEntries: applied5 })
    for (const a of actions) {
      const row = screen.getAllByTestId('update-override-action').find((r) => r.getAttribute('data-override-action') === a)
      expect(row).toHaveTextContent(T[`solutionOverrides.report.action.${a}`])
    }
    unmount()
    renderOv([], { appliedEntries: applied })
    expect(screen.queryByTestId('update-override-actions')).toBeNull()
  })

  it('unknown outcome and action fall back to the unknown label', () => {
    const odd = { ...ov('kept'), outcome: 'future' } as unknown as PackUpdateOverride
    renderOv([e('u', 'unchanged', { override: odd })], {
      appliedEntries: [
        { artefact_type: 'process_definition', artefact_id: 'u', classification: 'unchanged', action: 'left_unchanged', override_action: 'later' as never },
      ],
    })
    expect(screen.getByTestId('update-review-override-outcome')).toHaveTextContent(T['solutionOverrides.report.outcome.unknown'])
    expect(screen.getByTestId('update-override-action')).toHaveTextContent(T['solutionOverrides.report.action.unknown'])
  })

  it.each(['ru', 'kk'] as const)('I2 renders outcome and action labels in %s', (locale) => {
    renderOv(
      [e('c1', 'safe_to_update', { override: ov('override_conflict') })],
      {
        appliedEntries: [
          { artefact_type: 'process_definition', artefact_id: 'c1', classification: 'safe_to_update', action: 'advanced_to_incoming', override_action: 'retired' },
        ],
      },
      locale,
    )
    expect(screen.getByTestId('update-review-override-outcome')).toHaveTextContent(
      entitiesMessages[locale]['solutionOverrides.report.outcome.override_conflict'],
    )
    expect(screen.getByTestId('update-override-action')).toHaveTextContent(
      entitiesMessages[locale]['solutionOverrides.report.action.retired'],
    )
  })
})
