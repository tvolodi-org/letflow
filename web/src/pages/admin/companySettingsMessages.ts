/** companySettingsMessages — strings of the "Company name and time zone" section (T-2403; en, ru, kk). */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface CompanySettingsCatalog {
  sectionTitle: string
  lede: string
  nameLabel: string
  nameError: string
  zoneLabel: string
  save: string
  saved: string
  saveError: string
  loading: string
}

export const companySettingsMessages: Record<UiLocale, CompanySettingsCatalog> = {
  en: {
    sectionTitle: 'Company name and time zone',
    lede: 'The name shown in the application and the time zone used for document dates.',
    nameLabel: 'Company name (1 to 100 characters)',
    nameError: 'Enter a company name of 1 to 100 characters.',
    zoneLabel: 'Time zone',
    save: 'Save',
    saved: 'Company name and time zone saved.',
    saveError: 'Could not save the company name and time zone.',
    loading: 'Loading company settings',
  },
  ru: {
    sectionTitle: 'Название организации и часовой пояс',
    lede: 'Название в приложении и часовой пояс для дат документов.',
    nameLabel: 'Название организации (от 1 до 100 символов)',
    nameError: 'Введите название организации длиной от 1 до 100 символов.',
    zoneLabel: 'Часовой пояс',
    save: 'Сохранить',
    saved: 'Название организации и часовой пояс сохранены.',
    saveError: 'Не удалось сохранить название организации и часовой пояс.',
    loading: 'Загрузка настроек организации',
  },
  kk: {
    sectionTitle: 'Ұйым атауы және уақыт белдеуі',
    lede: 'Қолданбада көрсетілетін атау және құжат күндеріне арналған уақыт белдеуі.',
    nameLabel: 'Ұйым атауы (1-ден 100 таңбаға дейін)',
    nameError: 'Ұйым атауын 1-ден 100 таңбаға дейін енгізіңіз.',
    zoneLabel: 'Уақыт белдеуі',
    save: 'Сақтау',
    saved: 'Ұйым атауы мен уақыт белдеуі сақталды.',
    saveError: 'Ұйым атауы мен уақыт белдеуін сақтау мүмкін болмады.',
    loading: 'Ұйым баптаулары жүктелуде',
  },
}
