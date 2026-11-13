/** T-1442 — strings of the splitter, column handle and side-nav toggle (en, ru, kk; rule 4).
 *  T-1886 — selectRecord added for the ListDetail default empty state.
 *  The ru and kk words follow the design repo's preview (LFShell.TXT); a native check is listed in language-switch.md. */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { useUiLocale } from '@/i18n/uiLocaleStore'

export interface LayoutCatalog {
  resize: string
  resizeColumn: string
  collapse: string
  expand: string
  navCollapse: string
  navExpand: string
  navResize: string
  resetLayout: string
  resetLayoutHint: string
  splitList: string
  splitHeader: string
  selectRecord: string
}

export const layoutMessages: Record<UiLocale, LayoutCatalog> = {
  en: {
    resize: 'Resize',
    resizeColumn: 'Resize column',
    collapse: 'Collapse',
    expand: 'Expand',
    navCollapse: 'Collapse the side nav',
    navExpand: 'Expand the side nav',
    navResize: 'Resize the side nav',
    resetLayout: 'Reset layout',
    resetLayoutHint: 'Forget every saved panel size, collapsed panel and column width',
    splitList: 'Resize the document list',
    splitHeader: 'Resize the header',
    selectRecord: 'Select a record on the left',
  },
  ru: {
    resize: 'Изменить ширину',
    resizeColumn: 'Ширина столбца',
    collapse: 'Свернуть',
    expand: 'Развернуть',
    navCollapse: 'Свернуть меню',
    navExpand: 'Развернуть меню',
    navResize: 'Ширина меню',
    resetLayout: 'Сбросить раскладку',
    resetLayoutHint: 'Забыть все сохранённые размеры, свёрнутые панели и ширину столбцов',
    splitList: 'Ширина списка документов',
    splitHeader: 'Ширина шапки',
    selectRecord: 'Выберите запись слева',
  },
  kk: {
    resize: 'Енін өзгерту',
    resizeColumn: 'Баған ені',
    collapse: 'Жию',
    expand: 'Жаю',
    navCollapse: 'Мәзірді жию',
    navExpand: 'Мәзірді жаю',
    navResize: 'Мәзір ені',
    resetLayout: 'Орналасуды қалпына келтіру',
    resetLayoutHint: 'Барлық сақталған панель өлшемдерін, жиылған панельдер мен баған енін ұмыту',
    splitList: 'Құжаттар тізімінің ені',
    splitHeader: 'Тақырып ені',
    selectRecord: 'Сол жақтан жазба таңдаңыз',
  },
}

export function useLayoutMessages(): LayoutCatalog {
  return layoutMessages[useUiLocale()]
}
