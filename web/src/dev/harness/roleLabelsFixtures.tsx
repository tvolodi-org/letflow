/** Harness screen of the role list as the access screens show it (T-1317, D-083): every built-in role with its
 *  translated name and one-sentence description. The language comes from the UI-language store (?lang). */
import { ROLES, roleDescription, roleLabel } from '@/auth/access'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import type { HarnessScreen } from './types'

function RoleList() {
  const locale = useUiLocale()
  return (
    <div style={{ padding: 'var(--space-6)' }}>
      <h3 style={{ marginBottom: 'var(--space-2)' }}>Role assignments</h3>
      <div style={{ border: '1px solid var(--border-default)', borderRadius: 'var(--radius-md)', padding: 'var(--space-3)' }}>
        {ROLES.map(name => (
          <label key={name} style={{ display: 'block', marginBottom: 'var(--space-2)' }}>
            <input type="checkbox" defaultChecked={name === 'STOREKEEPER'} /> {roleLabel(name, locale)}
            <span style={{ display: 'block', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>
              {roleDescription(name, locale)}
            </span>
          </label>
        ))}
      </div>
    </div>
  )
}

export const roleLabelsScreens: HarnessScreen[] = [{ name: 'role-labels', routes: [], render: () => <RoleList /> }]
