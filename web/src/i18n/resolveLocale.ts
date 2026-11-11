/** resolveLocale — the one locale resolver the module message files share (core extraction S5).
 *
 *  `undefined` candidates: the live UI language (`getUiLocale`, D-083). A list: the first entry whose base
 *  language tag (`kk-KZ` -> `kk`, case-insensitive) is in `supported`; else `en`. `supported` is the module's own
 *  locale tuple, so the module keeps its own `resolveUiLocale` name and type and imports only from `@/i18n`. */
import { getUiLocale } from '@/i18n/uiLocaleStore'

export function resolveLocale<T extends string>(supported: readonly T[], candidates?: readonly string[]): T {
  if (candidates === undefined) return getUiLocale() as string as T
  for (const raw of candidates) {
    const base = raw.split('-')[0].toLowerCase()
    if ((supported as readonly string[]).includes(base)) return base as T
  }
  return 'en' as T
}
