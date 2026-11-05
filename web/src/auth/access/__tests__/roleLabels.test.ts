import { describe, expect, it } from 'vitest'
import { UI_LOCALES } from '@/i18n/uiLocaleStore'
import { ROLES } from '../roles'
import { ROLE_LABELS, roleDescription, roleLabel } from '../roleLabels'
import { ACCESS_FIXTURES } from '../fixtures'

describe('role labels (T-1317, T-14)', () => {
  it('every built-in role has a name and a description in en, ru and kk', () => {
    for (const role of ROLES) {
      for (const locale of UI_LOCALES) {
        expect(ROLE_LABELS[role][locale].name.length).toBeGreaterThan(0)
        expect(ROLE_LABELS[role][locale].description.length).toBeGreaterThan(0)
      }
    }
  })

  it('translates STOREKEEPER and returns any other name unchanged', () => {
    expect(roleLabel('STOREKEEPER', 'en')).toBe('Storekeeper')
    expect(roleLabel('STOREKEEPER', 'ru')).toBe('Кладовщик')
    expect(roleLabel('STOREKEEPER', 'kk')).toBe('Қоймашы')
    expect(roleLabel('warehouse-approvers', 'ru')).toBe('warehouse-approvers')
    expect(roleDescription('warehouse-approvers', 'ru')).toBe('')
  })

  it('the storekeeper fixture holds stock permissions and no administration', () => {
    const permissions = ACCESS_FIXTURES.storekeeper.permissions as readonly string[]
    expect(permissions).toContain('StockPost')
    expect(permissions).not.toContain('UsersGroupsRolesManage')
    expect(permissions).not.toContain('EntitiesRecordsWrite')
  })
})
