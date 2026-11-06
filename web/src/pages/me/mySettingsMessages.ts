/** mySettingsMessages — strings of "My settings" and of the tenant document-layout default (en, ru, kk). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface MySettingsCatalog {
  link: string
  eyebrow: string
  title: string
  lede: string
  sectionTitle: string
  legend: string
  save: string
  useDefault: string
  saved: string
  saveError: string
  loading: string
  tenantDefaultIs: string
  tenantSectionTitle: string
  tenantLegend: string
  tenantLede: string
  tenantSaved: string
}

export const mySettingsMessages: Record<UiLocale, MySettingsCatalog> = {
  en: {
    link: 'My settings',
    eyebrow: 'Account',
    title: 'My settings',
    lede: 'Choose how document forms are arranged for you.',
    sectionTitle: 'Document layout',
    legend: 'Layout of document forms',
    save: 'Save',
    useDefault: 'Use the tenant default',
    saved: 'Settings saved.',
    saveError: 'Could not save the settings.',
    loading: 'Loading settings',
    tenantDefaultIs: 'Tenant default:',
    tenantSectionTitle: 'Document layout (default for all users)',
    tenantLegend: 'Default layout of document forms',
    tenantLede: 'Users who have not chosen their own layout see this one.',
    tenantSaved: 'Tenant default saved.',
  },
  ru: {
    link: 'Мои настройки',
    eyebrow: 'Учётная запись',
    title: 'Мои настройки',
    lede: 'Выберите, как для вас расположены формы документов.',
    sectionTitle: 'Расположение документа',
    legend: 'Расположение форм документов',
    save: 'Сохранить',
    useDefault: 'Использовать значение организации',
    saved: 'Настройки сохранены.',
    saveError: 'Не удалось сохранить настройки.',
    loading: 'Загрузка настроек',
    tenantDefaultIs: 'Значение организации:',
    tenantSectionTitle: 'Расположение документа (по умолчанию для всех)',
    tenantLegend: 'Расположение форм документов по умолчанию',
    tenantLede: 'Пользователи, не выбравшие своё расположение, видят это.',
    tenantSaved: 'Значение организации сохранено.',
  },
  kk: {
    link: 'Менің баптауларым',
    eyebrow: 'Есептік жазба',
    title: 'Менің баптауларым',
    lede: 'Құжат формалары сізге қалай орналасатынын таңдаңыз.',
    sectionTitle: 'Құжат орналасуы',
    legend: 'Құжат формаларының орналасуы',
    save: 'Сақтау',
    useDefault: 'Ұйымның мәнін қолдану',
    saved: 'Баптаулар сақталды.',
    saveError: 'Баптауларды сақтау мүмкін болмады.',
    loading: 'Баптаулар жүктелуде',
    tenantDefaultIs: 'Ұйымның мәні:',
    tenantSectionTitle: 'Құжат орналасуы (барлығына әдепкі)',
    tenantLegend: 'Құжат формаларының әдепкі орналасуы',
    tenantLede: 'Өз орналасуын таңдамаған пайдаланушылар осыны көреді.',
    tenantSaved: 'Ұйымның мәні сақталды.',
  },
}
