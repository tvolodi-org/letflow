/** Texts of the shared refusal and failed-save surfaces (PermissionDenied, StaleVersionError,
 *  RateLimitBackpressure, saveErrorText), en/ru/kk. The kk texts are machine drafts until the owner's
 *  native check (docs/assets/i18n-gaps.md). Server wording and codes never reach these texts. */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { useUiLocale } from '@/i18n/uiLocaleStore'

export interface FeedbackMessages {
  permissionDenied: string
  goToExams: string
  myTasks: string
  staleTitle: string
  staleHint: string
  rateLimit: string
  /** {surface} is the name of the area being loaded. */
  rateLimitSurface: string
  /** {n} is the number of seconds. */
  retryIn: string
  retrying: string
  retryNow: string
  saveInvalid: string
  saveForbidden: string
  saveNotFound: string
  saveConflict: string
  /** {n} is the number of seconds. */
  saveRateLimit: string
  saveRateLimitNoWait: string
  saveFailed: string
}

export const feedbackMessages: Record<UiLocale, FeedbackMessages> = {
  en: {
    permissionDenied: 'You do not have access to this area. Contact your tenant administrator.',
    goToExams: 'Go to Exams',
    myTasks: 'My Tasks',
    staleTitle: 'This record has been updated by another user since you started editing.',
    staleHint: 'Choose how to resolve the conflict.',
    rateLimit: 'Rate limit reached.',
    rateLimitSurface: 'Rate limit reached while loading {surface}.',
    retryIn: 'Retry in {n}s',
    retrying: 'Retrying…',
    retryNow: 'Retry now',
    saveInvalid: 'Could not save: please check the fields and try again.',
    saveForbidden: 'You are not allowed to do this. Contact your administrator.',
    saveNotFound: 'This record no longer exists. Reload the page.',
    saveConflict: 'Someone changed this record in the meantime. Reload the page and try again.',
    saveRateLimit: 'Too many requests. Wait {n} s and try again.',
    saveRateLimitNoWait: 'Too many requests. Try again in a minute.',
    saveFailed: 'Could not save. Try again; if it keeps failing, contact your administrator.',
  },
  ru: {
    permissionDenied: 'У вас нет доступа к этому разделу. Обратитесь к администратору организации.',
    goToExams: 'Перейти к экзаменам',
    myTasks: 'Мои задачи',
    staleTitle: 'Эту запись изменил другой пользователь, пока вы её редактировали.',
    staleHint: 'Выберите, как разрешить конфликт.',
    rateLimit: 'Слишком много запросов.',
    rateLimitSurface: 'Слишком много запросов при загрузке: {surface}.',
    retryIn: 'Повтор через {n} с',
    retrying: 'Повторяем…',
    retryNow: 'Повторить сейчас',
    saveInvalid: 'Не удалось сохранить: проверьте поля и повторите.',
    saveForbidden: 'У вас нет прав на это действие. Обратитесь к администратору.',
    saveNotFound: 'Этой записи больше нет. Обновите страницу.',
    saveConflict: 'Запись тем временем изменили. Обновите страницу и повторите.',
    saveRateLimit: 'Слишком много запросов. Подождите {n} с и повторите.',
    saveRateLimitNoWait: 'Слишком много запросов. Повторите через минуту.',
    saveFailed: 'Не удалось сохранить. Повторите; если не получается, обратитесь к администратору.',
  },
  kk: {
    permissionDenied: 'Сізде бұл бөлімге қолжетімділік жоқ. Ұйым әкімшісіне хабарласыңыз.',
    goToExams: 'Емтихандарға өту',
    myTasks: 'Менің тапсырмаларым',
    staleTitle: 'Сіз өңдеп жатқанда бұл жазбаны басқа пайдаланушы өзгертті.',
    staleHint: 'Қайшылықты қалай шешуді таңдаңыз.',
    rateLimit: 'Сұраныстар тым көп.',
    rateLimitSurface: 'Жүктеу кезінде сұраныстар тым көп: {surface}.',
    retryIn: '{n} с кейін қайталау',
    retrying: 'Қайталануда…',
    retryNow: 'Қазір қайталау',
    saveInvalid: 'Сақтау мүмкін болмады: өрістерді тексеріп, қайталаңыз.',
    saveForbidden: 'Бұл әрекетке рұқсатыңыз жоқ. Әкімшіге хабарласыңыз.',
    saveNotFound: 'Бұл жазба енді жоқ. Бетті жаңартыңыз.',
    saveConflict: 'Жазбаны осы арада өзгертті. Бетті жаңартып, қайталаңыз.',
    saveRateLimit: 'Сұраныстар тым көп. {n} с күтіп, қайталаңыз.',
    saveRateLimitNoWait: 'Сұраныстар тым көп. Бір минуттан кейін қайталаңыз.',
    saveFailed: 'Сақтау мүмкін болмады. Қайталаңыз; егер болмаса, әкімшіге хабарласыңыз.',
  },
}

export function useFeedbackMessages(locale?: UiLocale): FeedbackMessages {
  const current = useUiLocale()
  return feedbackMessages[locale ?? current]
}

/** Replaces `{name}` placeholders; values are inserted as text. */
export function fillFeedback(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (whole, key: string) =>
    key in values ? String(values[key]) : whole,
  )
}
