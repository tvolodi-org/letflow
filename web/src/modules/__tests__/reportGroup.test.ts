/** T-1874 P1 — getReportGroupFor: an installed module claims entity types by prefix. */
import { describe, expect, it } from 'vitest'
import { getReportGroupFor } from '../registry'

const ASSETS = [{ module_id: 'assets', version: '1' }]

describe('T-1874 getReportGroupFor', () => {
  it.each(['assets_card', 'assets_commission', 'assets_opening_line', 'assets_writeoff_line'])('claims %s', (t) => {
    expect(getReportGroupFor(ASSETS, t)?.moduleId).toBe('assets')
  })
  it('does not claim a core type or a similar name', () => {
    expect(getReportGroupFor(ASSETS, 'orders')).toBeNull()
    expect(getReportGroupFor(ASSETS, 'asset_card')).toBeNull()
  })
  it('claims nothing when the module is not installed', () => {
    expect(getReportGroupFor([], 'assets_card')).toBeNull()
  })
  it('carries the label per locale', () => {
    expect(getReportGroupFor(ASSETS, 'assets_card')?.labels).toEqual({ en: 'Assets', ru: 'Активы', kk: 'Активтер' })
  })
})
