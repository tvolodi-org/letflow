/** T-TZ — GH 3735 R7: the stock formatter shows the tenant zone. */
import { describe, expect, it } from 'vitest'
import { STOCK_TIME_ZONE, formatStockDateTime } from '../register/stockRegisterModel'

const AT = '2026-11-05T11:24:00Z'

describe('T-TZ the stock formatter shows the tenant zone', () => {
  it('2026-11-05T11:24:00Z is 16:24 in Asia/Almaty, en and ru', () => {
    expect(STOCK_TIME_ZONE).toBe('Asia/Almaty')
    expect(formatStockDateTime(AT, { locale: 'en' })).toBe('Nov 5, 2026 16:24')
    expect(formatStockDateTime(AT, { locale: 'ru' })).toBe('05-11-2026 16:24')
    expect(formatStockDateTime(null)).toBe('')
  })
})
