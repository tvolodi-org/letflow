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
    docType: { stock_receipt: 'Receipt', stock_issue: 'Issue', stock_writeoff: 'Write off', stock_transfer: 'Transfer', stock_handover: 'Hand over', stock_return: 'Return', stock_reversal: 'Reversal', stock_opening: 'Opening balance', assets_opening: 'Asset opening', assets_commission: 'Asset commissioning', assets_handover: 'Asset hand over', assets_writeoff: 'Asset write off', assets_change: 'Asset change', assets_kind_change: 'Asset kind change', assets_reversal: 'Asset reversal', 'count.differences': 'Count differences', count: 'Stock count', stock_count: 'Stock count' },
  },
  ru: { unknown: 'Запись недоступна', loading: '…', you: 'Вы', anotherUser: 'Другой пользователь', instanceLabel: 'Экземпляр', assignedTo: 'Исполнитель',
    docType: { stock_receipt: 'Приход', stock_issue: 'Расход', stock_writeoff: 'Списание', stock_transfer: 'Перемещение', stock_handover: 'Передача', stock_return: 'Возврат', stock_reversal: 'Сторно', stock_opening: 'Начальный остаток', assets_opening: 'Ввод остатков активов', assets_commission: 'Ввод активов в эксплуатацию', assets_handover: 'Передача активов', assets_writeoff: 'Списание активов', assets_change: 'Изменение активов', assets_kind_change: 'Смена вида актива', assets_reversal: 'Сторно активов', 'count.differences': 'Расхождения инвентаризации', count: 'Инвентаризация', stock_count: 'Инвентаризация' },
  },
  kk: { unknown: 'Жазба қолжетімсіз', loading: '…', you: 'Сіз', anotherUser: 'Басқа пайдаланушы', instanceLabel: 'Данасы', assignedTo: 'Орындаушы',
    docType: { stock_receipt: 'Кіріс', stock_issue: 'Шығыс', stock_writeoff: 'Есептен шығару', stock_transfer: 'Орын ауыстыру', stock_handover: 'Тапсыру', stock_return: 'Қайтару', stock_reversal: 'Сторно', stock_opening: 'Бастапқы қалдық', assets_opening: 'Активтердің бастапқы қалдығы', assets_commission: 'Активтерді пайдалануға беру', assets_handover: 'Активтерді тапсыру', assets_writeoff: 'Активтерді есептен шығару', assets_change: 'Активтерді өзгерту', assets_kind_change: 'Актив түрін өзгерту', assets_reversal: 'Активтер сторносы', 'count.differences': 'Түгендеу айырмашылықтары', count: 'Түгендеу', stock_count: 'Түгендеу' },
  },
}
