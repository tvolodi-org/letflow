/** Catalog for the strings that form components own (en, ru, kk). Callers may override via props. */
import { resolveUiLocale, type EntitiesUiLocale } from '@/i18n/entitiesMessages'

export const formMessages: Record<
  EntitiesUiLocale,
  { optional: string; dirty: string; clean: string; saving: string }
> = {
  en: { optional: 'optional', dirty: 'Unsaved changes', clean: 'No unsaved changes', saving: 'Saving…' },
  ru: { optional: 'необязательно', dirty: 'Есть несохранённые изменения', clean: 'Нет несохранённых изменений', saving: 'Сохранение…' },
  kk: { optional: 'міндетті емес', dirty: 'Сақталмаған өзгерістер бар', clean: 'Сақталмаған өзгерістер жоқ', saving: 'Сақталуда…' },
}

export function useFormMessages(locale?: EntitiesUiLocale) {
  return formMessages[locale ?? resolveUiLocale(typeof navigator === 'undefined' ? [] : navigator.languages)]
}
