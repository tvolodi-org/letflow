/** Texts of the "Storekeeper: assets" card (T-1570, D-097), per UI language. Local on purpose: the page has no IntlProvider.
 *  The kk texts are machine drafts until the owner's native check (docs/assets/i18n-gaps.md). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface StorekeeperGrantMessages {
  title: string
  lede: string
  read: string
  post: string
  save: string
  saved: string
  loadError: string
  saveError: string
  retry: string
  notInstalled: string
  loading: string
}

export const storekeeperGrantMessages: Record<UiLocale, StorekeeperGrantMessages> = {
  en: {
    title: 'Storekeeper: assets',
    lede: 'What the storekeeper may do in the asset register of this company. Reversal, reconciliation and card changes stay with the administrator.',
    read: 'Read the register, movements and documents',
    post: 'Post asset documents',
    save: 'Save',
    saved: 'Saved.',
    loadError: 'Could not load the storekeeper access.',
    saveError: 'Could not save. Nothing was changed.',
    retry: 'Retry',
    notInstalled: 'The asset module is not installed in this company.',
    loading: 'Loading…',
  },
  ru: {
    title: 'Кладовщик: активы',
    lede: 'Что кладовщик может делать в реестре активов этой компании. Сторно, сверка и изменение карточек остаются у администратора.',
    read: 'Смотреть реестр, движения и документы',
    post: 'Проводить документы по активам',
    save: 'Сохранить',
    saved: 'Сохранено.',
    loadError: 'Не удалось загрузить доступ кладовщика.',
    saveError: 'Не удалось сохранить. Ничего не изменено.',
    retry: 'Повторить',
    notInstalled: 'Модуль активов в этой компании не установлен.',
    loading: 'Загрузка…',
  },
  kk: {
    title: 'Қоймашы: активтер',
    lede: 'Қоймашы осы компанияның активтер тізілімінде не істей алады. Қайтару, салыстыру және карточканы өзгерту әкімшіде қалады.',
    read: 'Тізілімді, қозғалыстарды және құжаттарды көру',
    post: 'Активтер құжаттарын жүргізу',
    save: 'Сақтау',
    saved: 'Сақталды.',
    loadError: 'Қоймашының қолжетімділігін жүктеу мүмкін болмады.',
    saveError: 'Сақтау мүмкін болмады. Ештеңе өзгерген жоқ.',
    retry: 'Қайталау',
    notInstalled: 'Бұл компанияда активтер модулі орнатылмаған.',
    loading: 'Жүктелуде…',
  },
}
