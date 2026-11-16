/** myProblemReportsMessages — strings of "My reports" (REQ-872) and of its links (en, ru, kk). The status words are
 *  not repeated here: they come from `problemReports.status.*` of the owner inbox catalog. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface MyProblemReportsCatalog {
  link: string
  eyebrow: string
  title: string
  lede: string
  loading: string
  colNumber: string
  colReceived: string
  colStatus: string
  colText: string
  question: string
  reply: string
  emptyTitle: string
  emptyText: string
  unavailable: string
  hasMore: string
}

export const myProblemReportsMessages: Record<UiLocale, MyProblemReportsCatalog> = {
  en: {
    link: 'My reports',
    eyebrow: 'Account',
    title: 'My reports',
    lede: 'The problems you reported and what happened to each.',
    loading: 'Loading your reports',
    colNumber: 'Number',
    colReceived: 'Received',
    colStatus: 'Status',
    colText: 'Your report',
    question: 'Question from the support team',
    reply: 'Reply from the support team',
    emptyTitle: 'You have not reported a problem yet',
    emptyText: 'Your reports and the answers to them will be listed here.',
    unavailable: 'Your reports are not available right now. Try again later.',
    hasMore: 'Only the newest 50 reports are listed.',
  },
  ru: {
    link: 'Мои сообщения',
    eyebrow: 'Учётная запись',
    title: 'Мои сообщения',
    lede: 'Проблемы, о которых вы сообщили, и что с каждой произошло.',
    loading: 'Загрузка ваших сообщений',
    colNumber: 'Номер',
    colReceived: 'Получено',
    colStatus: 'Статус',
    colText: 'Ваше сообщение',
    question: 'Вопрос службы поддержки',
    reply: 'Ответ службы поддержки',
    emptyTitle: 'Вы ещё не сообщали о проблемах',
    emptyText: 'Здесь появятся ваши сообщения и ответы на них.',
    unavailable: 'Ваши сообщения сейчас недоступны. Попробуйте позже.',
    hasMore: 'Показаны только 50 новейших сообщений.',
  },
  kk: {
    link: 'Менің хабарламаларым',
    eyebrow: 'Тіркелгі',
    title: 'Менің хабарламаларым',
    lede: 'Сіз хабарлаған мәселелер және олардың әрқайсысына не болғаны.',
    loading: 'Хабарламаларыңыз жүктелуде',
    colNumber: 'Нөмір',
    colReceived: 'Қабылданды',
    colStatus: 'Мәртебе',
    colText: 'Сіздің хабарламаңыз',
    question: 'Қолдау қызметінің сұрағы',
    reply: 'Қолдау қызметінің жауабы',
    emptyTitle: 'Сіз әлі мәселе туралы хабарлаған жоқсыз',
    emptyText: 'Хабарламаларыңыз бен оларға жауаптар осында көрсетіледі.',
    unavailable: 'Хабарламаларыңыз қазір қолжетімсіз. Кейінірек қайталап көріңіз.',
    hasMore: 'Тек ең жаңа 50 хабарлама көрсетілген.',
  },
}
