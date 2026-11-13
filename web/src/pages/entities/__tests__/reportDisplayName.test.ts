/** T-1874 P3 — reportDisplayName: the shipped "Asset list" name in en/ru/kk, other names unchanged. */
import { describe, expect, it } from 'vitest'
import { createIntl } from 'react-intl'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import { reportDisplayName } from '../reportDisplayName'

const intlFor = (l: 'en' | 'ru' | 'kk') => createIntl({ locale: l, messages: entitiesMessages[l] })

describe('T-1874 reportDisplayName', () => {
  it.each([
    ['en', 'Asset list'],
    ['ru', 'Список активов'],
    ['kk', 'Активтер тізімі'],
  ] as const)('P3 shipped name in %s', (l, text) => {
    expect(reportDisplayName('Asset list', intlFor(l))).toBe(text)
  })
  it('P3 an unknown or tenant-made name is shown as stored', () => {
    expect(reportDisplayName('Monthly totals', intlFor('ru'))).toBe('Monthly totals')
  })
})
