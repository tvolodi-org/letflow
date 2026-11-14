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
