/** T7 — T-1933 / REQ-822 (K7a): the three catalogs of the asset count screens carry the same ids, none empty. */
import { describe, expect, it } from 'vitest'
import { countsEn, countsKk, countsRu } from '../counts/assetCountsMessages'
import { COUNT_KINDS, COUNT_REASONS, COUNT_STATUSES } from '../counts/assetCountsModel'
import { assetsMessages } from '../assetsMessages'

describe('T7 asset count messages', () => {
  it('has the same ids in en, ru and kk, and no empty text', () => {
    const en = Object.keys(countsEn).sort()
    expect(Object.keys(countsRu).sort()).toEqual(en)
    expect(Object.keys(countsKk).sort()).toEqual(en)
    for (const cat of [countsEn, countsRu, countsKk]) for (const [id, text] of Object.entries(cat)) expect(text.trim(), id).not.toBe('')
  })

  it('has a text for every status, reason and kind the screen builds an id from', () => {
    for (const lang of ['en', 'ru', 'kk'] as const) {
      const cat = assetsMessages[lang]
      for (const s of COUNT_STATUSES) expect(cat[`assets.count.status.${s}`], s).toBeTruthy()
      for (const r of COUNT_REASONS) expect(cat[`assets.count.reason.${r}`], r).toBeTruthy()
      for (const k of COUNT_KINDS) expect(cat[`assets.kind.${k}`], k).toBeTruthy()
    }
  })

  it('the Russian texts are Russian: no Latin letters in the title, a status word or a reason', () => {
    for (const id of ['assets.count.title', 'assets.count.status.draft', 'assets.count.reason.not_chair']) {
      expect(countsRu[id]).toMatch(/[А-Яа-я]/)
      expect(countsRu[id]).not.toMatch(/[A-Za-z]/)
    }
  })
})
