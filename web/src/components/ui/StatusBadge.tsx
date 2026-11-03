/** StatusBadge — thin wrapper over StatusPill, kept until callers migrate to a
 *  per-module pill map (NOTES.md §2: StatusPill replaces StatusBadge).
 *
 *  Resolves a (domain, status) pair to a pill tone + glyph (the old §5 tables,
 *  re-made for the new look). The word shown is the status itself. `timer`/`dlq`
 *  domains and any unrecognised status fall back to a neutral ring pill.
 *  `size` is accepted for source compatibility; pills have one size.
 */

import React from 'react'
import { StatusPill, type StatusGlyph, type StatusTone } from './StatusPill'

export type StatusBadgeDomain = 'definition' | 'instance' | 'task' | 'timer' | 'dlq' | 'rollout' | 'rollout-outcome' | 'event-retirement' | 'event-retirement-outcome'

export interface StatusBadgeProps {
  status: string
  domain: StatusBadgeDomain
  size?: 'sm' | 'md'
}

interface ResolvedStatus {
  tone: StatusTone
  glyph: StatusGlyph
}

const FALLBACK: ResolvedStatus = { tone: 'neutral', glyph: 'ring' }

const ok: ResolvedStatus = { tone: 'success', glyph: 'dot' }
const active: ResolvedStatus = { tone: 'info', glyph: 'half' }
const bad: ResolvedStatus = { tone: 'danger', glyph: 'triangle' }
const off: ResolvedStatus = { tone: 'neutral', glyph: 'dash' }

const DEFINITION_STATUSES: Record<string, ResolvedStatus> = {
  DRAFT: { tone: 'neutral', glyph: 'ring' },
  ACTIVE: ok,
  DEPRECATED: { tone: 'warning', glyph: 'half' },
  ARCHIVED: off,
}

const INSTANCE_STATUSES: Record<string, ResolvedStatus> = {
  ACTIVE: active,
  COMPLETED: ok,
  CANCELLED: off,
  ERROR: bad,
}

const TASK_STATUSES: Record<string, ResolvedStatus> = {
  PENDING: active,
  COMPLETED: ok,
  CANCELLED: off,
}

// REQ-375: `rollout.status` and `outcome.status` are two DISJOINT enums, so
// they stay two separate tables (one shared table fell through to FALLBACK).
const ROLLOUT_STATUSES: Record<string, ResolvedStatus> = {
  running: active,
  completed: ok,
}

const ROLLOUT_OUTCOME_STATUSES: Record<string, ResolvedStatus> = {
  succeeded: ok,
  failed: bad,
  pending: active,
}

// REQ-377: EventHistoryRetirement.status and its per-tenant outcome enum.
const EVENT_RETIREMENT_STATUSES: Record<string, ResolvedStatus> = {
  running: active,
  completed: ok,
  failed: bad,
}

const EVENT_RETIREMENT_OUTCOME_STATUSES: Record<string, ResolvedStatus> = {
  succeeded: ok,
  skipped: off,
  failed: bad,
  pending: active,
}

// timer/dlq: no status table exists in the spec; every status falls back.
const STATUS_TABLES: Partial<Record<StatusBadgeDomain, Record<string, ResolvedStatus>>> = {
  definition: DEFINITION_STATUSES,
  instance: INSTANCE_STATUSES,
  task: TASK_STATUSES,
  rollout: ROLLOUT_STATUSES,
  'rollout-outcome': ROLLOUT_OUTCOME_STATUSES,
  'event-retirement': EVENT_RETIREMENT_STATUSES,
  'event-retirement-outcome': EVENT_RETIREMENT_OUTCOME_STATUSES,
}

function resolveStatus(domain: StatusBadgeDomain, status: string): ResolvedStatus {
  const resolved = STATUS_TABLES[domain]?.[status]
  if (resolved) return resolved

  if (import.meta.env.DEV) {
    console.warn(`StatusBadge: no status table entry for domain="${domain}" status="${status}" — rendering fallback badge.`)
  }
  return FALLBACK
}

export function StatusBadge(props: StatusBadgeProps): React.ReactElement {
  const { status, domain } = props
  const { tone, glyph } = resolveStatus(domain, status)
  return (
    <StatusPill
      tone={tone}
      glyph={glyph}
      data-testid="status-badge"
      dataAttributes={{ 'data-status': status, 'data-domain': domain }}
    >
      {status}
    </StatusPill>
  )
}
