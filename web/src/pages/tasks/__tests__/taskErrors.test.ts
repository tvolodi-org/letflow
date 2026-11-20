import { describe, it, expect } from 'vitest'
import { taskErrorText } from '../taskErrors'
import { TASK_MESSAGES } from '../taskMessages'

const base = 'https://letflow.dev/problems/'
const err = (status: number, type: string, code = '') => ({ status, code: type, details: { type, code, status } })

describe('taskErrorText known problem types (T-1969)', () => {
  for (const lang of ['en', 'ru', 'kk'] as const) {
    const m = TASK_MESSAGES[lang]
    it(`${lang}: module upgrade required (409 and 503) is not the generic text`, () => {
      expect(taskErrorText(err(409, base + 'module-upgrade-required', 'upgrade_required'), 'approve', m)).toBe(m.errModuleUpgrade)
      expect(taskErrorText(err(503, base + 'module-upgrade-required', 'module_upgrade_required'), 'approve', m)).toBe(m.errModuleUpgrade)
      expect(m.errModuleUpgrade).not.toBe(m.errGeneric)
    })
    it(`${lang}: conflict and plain forbidden have their own text`, () => {
      expect(taskErrorText(err(409, base + 'conflict'), 'post', m)).toBe(m.errConflict)
      expect(taskErrorText(err(403, base + 'forbidden'), 'post', m)).toBe(m.errForbidden)
    })
  }
  it('an unknown failure stays generic', () => {
    expect(taskErrorText(new Error('boom'), 'post', TASK_MESSAGES.en)).toBe(TASK_MESSAGES.en.errGeneric)
  })
  it('the English upgrade text names the admin path', () => {
    expect(TASK_MESSAGES.en.errModuleUpgrade).toContain('Administration > Modules')
  })
})

// REQ-906: the two posting refusals of REQ-903 / REQ-904 are plain entity write refusals (409, body `error`).
const refusal = (status: number, error: string) => ({ status, code: 'STALE_VERSION', details: { xResourceVersion: null, error } })

describe('taskErrorText posting refusals (REQ-906)', () => {
  for (const lang of ['en', 'ru', 'kk'] as const) {
    const m = TASK_MESSAGES[lang]
    it(`${lang}: record_version_conflict and master_inactive have their own texts`, () => {
      expect(taskErrorText(refusal(409, 'record_version_conflict'), 'post', m)).toBe(m.errDocumentChanged)
      expect(taskErrorText(refusal(409, 'master_inactive'), 'post', m)).toBe(m.errMasterRetired)
      expect(m.errDocumentChanged).not.toBe(m.errGeneric)
      expect(m.errMasterRetired).not.toBe(m.errGeneric)
      expect(m.errDocumentChanged).not.toBe(m.errMasterRetired)
    })
    it(`${lang}: the earlier mappings keep their texts`, () => {
      expect(taskErrorText(refusal(409, 'insufficient_stock'), 'post', m)).toBe(m.errInsufficientStock)
      expect(taskErrorText(refusal(409, 'location_frozen'), 'post', m)).toBe(m.errLocationFrozen)
      expect(taskErrorText(err(409, base + 'record-version-conflict'), 'post', m)).toBe(m.errConflict)
    })
    it(`${lang}: no code or id reaches the new texts`, () => {
      for (const t of [m.errDocumentChanged, m.errMasterRetired]) {
        expect(t).not.toContain('record_version_conflict')
        expect(t).not.toContain('master_inactive')
        expect(t.length).toBeGreaterThan(20)
      }
    })
  }
  it('the codes only map on status 409', () => {
    const m = TASK_MESSAGES.en
    expect(taskErrorText(refusal(500, 'master_inactive'), 'post', m)).toBe(m.errGeneric)
    expect(taskErrorText(refusal(500, 'record_version_conflict'), 'post', m)).toBe(m.errGeneric)
  })
})
