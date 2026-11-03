/** Harness screen of the TopBar with the language switcher (D-083). State `default` shows the menu open,
 *  `empty` shows it closed. The switcher reads and writes the UI-language store, so ?lang drives the screen. */
import { useEffect } from 'react'
import { LanguageSwitcher } from '@/components/ui/LanguageSwitcher'
import { TopBar } from '@/components/ui/TopBar'
import { UI_LOCALES, UI_LOCALE_LABELS, useUiLocale, useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { navMessages } from '@/components/layout/navMessages'
import type { HarnessScreen } from './types'

function OpenMenu({ active }: { active: boolean }) {
  useEffect(() => {
    if (!active) return
    const frame = requestAnimationFrame(() => document.querySelector<HTMLElement>('[data-testid="language-switcher-trigger"]')?.click())
    return () => cancelAnimationFrame(frame)
  }, [active])
  return null
}

function TopBarHarness({ open }: { open: boolean }) {
  const locale = useUiLocale()
  const setLocale = useUiLocaleStore(s => s.setLocale)
  return (
    <>
      <TopBar
        crumbs={[{ label: navMessages[locale].groups.tenantAdmin, to: '/' }, { label: navMessages[locale].items['/admin/org/units'] }]}
        end={
          <LanguageSwitcher
            locales={UI_LOCALES.map(code => ({ code, label: UI_LOCALE_LABELS[code] }))}
            current={locale}
            onChange={code => setLocale(code as (typeof UI_LOCALES)[number])}
          />
        }
      />
      <OpenMenu active={open} />
    </>
  )
}

export const topbarLanguage: HarnessScreen = {
  name: 'topbar-language',
  routes: [],
  render: ({ state }) => <TopBarHarness open={state === 'default'} />,
}
