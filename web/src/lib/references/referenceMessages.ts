/** Messages of the shared reference label (T-1378): en / ru / kk. */
import type { UiLocale } from '@/i18n/uiLocaleStore'

export interface ReferenceMessages {
  unknown: string
  loading: string
  you: string
  anotherUser: string
  instanceLabel: string
  assignedTo: string
  /** Document kind words for the task subject, by the `document_type` process variable. */
  docType: Record<string, string>
}

export const REFERENCE_MESSAGES: Record<UiLocale, ReferenceMessages> = {
  en: { unknown: 'Unknown record', loading: '…', you: 'You', anotherUser: 'Another user', instanceLabel: 'Instance', assignedTo: 'Assigned to',
    docType: { stock_receipt: 'Receipt', stock_issue: 'Issue', stock_writeoff: 'Write off', stock_transfer: 'Transfer', stock_handover: 'Hand over', stock_return: 'Return', stock_reversal: 'Reversal', stock_opening: 'Opening balance', 'count.differences': 'Count differences', count: 'Stock count' },
  },
  ru: { unknown: 'Запись недоступна', loading: '…', you: 'Вы', anotherUser: 'Другой пользователь', instanceLabel: 'Экземпляр', assignedTo: 'Исполнитель',
    docType: { stock_receipt: 'Приход', stock_issue: 'Расход', stock_writeoff: 'Списание', stock_transfer: 'Перемещение', stock_handover: 'Передача', stock_return: 'Возврат', stock_reversal: 'Сторно', stock_opening: 'Начальный остаток', 'count.differences': 'Расхождения инвентаризации', count: 'Инвентаризация' },
  },
  kk: { unknown: 'Жазба қолжетімсіз', loading: '…', you: 'Сіз', anotherUser: 'Басқа пайдаланушы', instanceLabel: 'Данасы', assignedTo: 'Орындаушы',
    docType: { stock_receipt: 'Кіріс', stock_issue: 'Шығыс', stock_writeoff: 'Есептен шығару', stock_transfer: 'Орын ауыстыру', stock_handover: 'Тапсыру', stock_return: 'Қайтару', stock_reversal: 'Сторно', stock_opening: 'Бастапқы қалдық', 'count.differences': 'Түгендеу айырмашылықтары', count: 'Түгендеу' },
  },
}
