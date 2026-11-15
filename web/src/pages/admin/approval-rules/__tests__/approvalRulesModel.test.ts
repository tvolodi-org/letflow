// @vitest-environment node
/** W-M1 — pure model of the Approval rules screen. */
import { describe, expect, it } from 'vitest'
import { processName, ruleKey, saveErrorKey, stepName } from '../approvalRulesModel'

describe('W-M1 model', () => {
  it('ruleKey is JSON and survives a slash in the name', () => {
    expect(ruleKey({ definition_name: 'a/b', node_id: 'n' })).toBe('["a/b","n"]')
  })

  it('processName: own catalog, then shared definition labels, then the key', () => {
    expect(processName('assets_opening', 'ru')).toBe('Ввод остатков активов')
    expect(processName('assets_writeoff', 'en')).toBe('Asset write-off')
    expect(processName('my_own_process', 'kk')).toBe('my_own_process')
    expect(processName('constructor', 'en')).toBe('constructor')
  })

  it('stepName: node label, then catalog, then the id', () => {
    expect(stepName({ node_id: 'approve', node_label: 'Chief sign-off' }, 'en')).toBe('Chief sign-off')
    expect(stepName({ node_id: 'approve', node_label: null }, 'ru')).toBe('Утверждение')
    expect(stepName({ node_id: 'x1', node_label: null }, 'en')).toBe('x1')
  })

  it('saveErrorKey maps each server detail, the status fallbacks and an unknown error', () => {
    const e = (status: number, detail?: string) => ({ status, details: detail ? { detail } : undefined })
    expect(saveErrorKey(e(422, 'invalid_reason'))).toBe('approvalRules.error.invalid_reason')
    expect(saveErrorKey(e(422, 'not_a_four_eyes_step'))).toBe('approvalRules.error.not_a_four_eyes_step')
    expect(saveErrorKey(e(409, 'concurrent_change'))).toBe('approvalRules.error.concurrent_change')
    expect(saveErrorKey(e(409))).toBe('approvalRules.error.concurrent_change')
    expect(saveErrorKey(e(403))).toBe('approvalRules.error.forbidden')
    expect(saveErrorKey(e(500))).toBe('approvalRules.error.generic')
    expect(saveErrorKey(new Error('x'))).toBe('approvalRules.error.generic')
  })
})
