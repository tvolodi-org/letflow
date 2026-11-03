/** Fixed strings of the layout and feedback components (NOTES.md rule 4: en, ru, kk).
 *  Consumers may override each string through a prop; these are the defaults. */
import type { EntitiesUiLocale } from '@/i18n/entitiesMessages'
import { useUiLocale } from '@/i18n/uiLocaleStore'

export type UiMessageId =
  | 'close'
  | 'dismiss'
  | 'confirm'
  | 'cancel'
  | 'openMenu'
  | 'closeMenu'
  | 'breadcrumb'
  | 'language'
  | 'dropChoose'
  | 'dropOr'
  | 'dropOver'
  | 'replace'
  | 'invalidFile'
  | 'skipLink'
  | 'back'

export const uiMessages: Record<EntitiesUiLocale, Record<UiMessageId, string>> = {
  en: {
    close: 'Close',
    dismiss: 'Dismiss notification',
    confirm: 'Confirm',
    cancel: 'Cancel',
    openMenu: 'Open menu',
    closeMenu: 'Close menu',
    breadcrumb: 'Breadcrumb',
    language: 'Language',
    dropChoose: 'choose a file',
    dropOr: 'or',
    dropOver: 'Release to upload',
    replace: 'Replace',
    invalidFile: 'This file cannot be used.',
    skipLink: 'Skip to main content',
    back: 'Back to the list',
  },
  ru: {
    close: 'Закрыть',
    dismiss: 'Скрыть уведомление',
    confirm: 'Подтвердить',
    cancel: 'Отмена',
    openMenu: 'Открыть меню',
    closeMenu: 'Закрыть меню',
    breadcrumb: 'Навигационная цепочка',
    language: 'Язык',
    dropChoose: 'выберите файл',
    dropOr: 'или',
    dropOver: 'Отпустите, чтобы загрузить',
    replace: 'Заменить',
    invalidFile: 'Этот файл нельзя использовать.',
    skipLink: 'Перейти к основному содержимому',
    back: 'Назад к списку',
  },
  kk: {
    close: 'Жабу',
    dismiss: 'Хабарландыруды жабу',
    confirm: 'Растау',
    cancel: 'Болдырмау',
    openMenu: 'Мәзірді ашу',
    closeMenu: 'Мәзірді жабу',
    breadcrumb: 'Навигация жолы',
    language: 'Тіл',
    dropChoose: 'файлды таңдаңыз',
    dropOr: 'немесе',
    dropOver: 'Жүктеу үшін жіберіңіз',
    replace: 'Ауыстыру',
    invalidFile: 'Бұл файлды қолдануға болмайды.',
    skipLink: 'Негізгі мазмұнға өту',
    back: 'Тізімге оралу',
  },
}

export function useUiMessages(locale?: EntitiesUiLocale): Record<UiMessageId, string> {
  const current = useUiLocale()
  return uiMessages[locale ?? current]
}
