/** Page-level strings of PrintTemplatesPage (title and the scope note), in the three shipped languages. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export const printTemplatesMessages: Record<UiLocale, { title: string; scope: string }> = {
  en: {
    title: 'Print templates',
    scope:
      'These overrides change only the print layout of documents of your own document types. Module prints (official forms, acts and similar) ignore them and always use their fixed layout.',
  },
  ru: {
    title: 'Шаблоны печати',
    scope:
      'Эти переопределения меняют только печатный макет документов ваших собственных типов. Печать модулей (официальные формы, акты и т. п.) их не учитывает и всегда использует свой фиксированный макет.',
  },
  kk: {
    title: 'Басып шығару үлгілері',
    scope:
      'Бұл баптаулар тек өз құжат түрлеріңіздің баспа макетін өзгертеді. Модульдердің баспасы (ресми нысандар, актілер және т.б.) оларды ескермейді және әрқашан өзінің бекітілген макетін қолданады.',
  },
}
