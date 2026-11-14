/** Texts of the "Install on your phone" entry of the home screen (O-003), per UI language. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface InstallHintMessages {
  title: string
  intro: string
  iphoneTitle: string
  iphoneSteps: string[]
  androidTitle: string
  androidSteps: string[]
  read: string
}

export const installHintMessages: Record<UiLocale, InstallHintMessages> = {
  en: {
    title: 'Install on your phone',
    intro: 'Add the app to your home screen to open it like any other app and to keep saved drafts.',
    iphoneTitle: 'iPhone or iPad (Safari)',
    iphoneSteps: ['Open this site in Safari.', 'Tap the Share button.', 'Choose "Add to Home Screen".', 'Open the app from the new icon.'],
    androidTitle: 'Android (Chrome)',
    androidSteps: ['Open this site in Chrome.', 'Open the browser menu.', 'Choose "Install app" or "Add to Home screen".', 'Open the app from the new icon.'],
    read: 'I have read it',
  },
  ru: {
    title: 'Установить на телефон',
    intro: 'Добавьте приложение на главный экран: оно открывается как обычное и сохраняет черновики.',
    iphoneTitle: 'iPhone или iPad (Safari)',
    iphoneSteps: ['Откройте сайт в Safari.', 'Нажмите кнопку «Поделиться».', 'Выберите «На экран «Домой»».', 'Запускайте приложение с нового значка.'],
    androidTitle: 'Android (Chrome)',
    androidSteps: ['Откройте сайт в Chrome.', 'Откройте меню браузера.', 'Выберите «Установить приложение» или «Добавить на главный экран».', 'Запускайте приложение с нового значка.'],
    read: 'Я прочитал',
  },
  kk: {
    title: 'Телефонға орнату',
    intro: 'Қосымшаны басты экранға қосыңыз: ол әдеттегі қосымша сияқты ашылады және жобаларды сақтайды.',
    iphoneTitle: 'iPhone немесе iPad (Safari)',
    iphoneSteps: ['Сайтты Safari-де ашыңыз.', '«Бөлісу» түймесін басыңыз.', '«Басты экранға қосу» таңдаңыз.', 'Қосымшаны жаңа белгіден ашыңыз.'],
    androidTitle: 'Android (Chrome)',
    androidSteps: ['Сайтты Chrome-да ашыңыз.', 'Браузер мәзірін ашыңыз.', '«Қосымшаны орнату» немесе «Басты экранға қосу» таңдаңыз.', 'Қосымшаны жаңа белгіден ашыңыз.'],
    read: 'Оқыдым',
  },
}
