/** currenciesMessages — REQ-827. Message catalog of the Currencies admin screen, en/ru/kk. */
export const CURRENCIES_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type CurrenciesUiLocale = (typeof CURRENCIES_UI_LOCALES)[number]

type Triple = readonly [en: string, ru: string, kk: string]

const UI: Record<string, Triple> = {
  'currencies.title': ['Currencies', 'Валюты', 'Валюталар'],
  'currencies.search.placeholder': [
    'Search by code or name',
    'Поиск по коду или названию',
    'Код немесе атау бойынша іздеу',
  ],
  'currencies.col.code': ['Code', 'Код', 'Код'],
  'currencies.col.name': ['Name', 'Название', 'Атауы'],
  'currencies.col.minorUnits': ['Minor units', 'Дробные единицы', 'Ондық бөлшек'],
  'currencies.col.active': ['Active', 'Активна', 'Белсенді'],
  'currencies.col.tenantCurrency': ['Tenant currency', 'Валюта организации', 'Ұйым валютасы'],
  'currencies.switch.disabled': [
    'The tenant currency is always on',
    'Валюта организации всегда активна',
    'Ұйым валютасы әрқашан белсенді',
  ],
  'currencies.action.makeTenantCurrency': [
    'Make tenant currency',
    'Сделать валютой организации',
    'Ұйым валютасы ету',
  ],
  'currencies.tenantCurrency.mark': ['●', '●', '●'],
  'currencies.empty': [
    'No currencies matched the search.',
    'Нет валют, соответствующих поиску.',
    'Іздеуге сәйкес валюта жоқ.',
  ],
  'currencies.error.currency_is_tenant_currency': [
    'This is the tenant currency and cannot be switched off.',
    'Это валюта организации, её нельзя отключить.',
    'Бұл ұйым валютасы, оны өшіруге болмайды.',
  ],
  'currencies.error.currency_unknown': [
    'Unknown currency code.',
    'Неизвестный код валюты.',
    'Белгісіз валюта коді.',
  ],
  'currencies.error.invalid_body': [
    'The request is invalid.',
    'Запрос недействителен.',
    'Сұрау жарамсыз.',
  ],
}

function build(index: 0 | 1 | 2): Record<string, string> {
  return Object.fromEntries(Object.entries(UI).map(([id, triple]) => [id, triple[index]]))
}

export const currenciesMessages: Record<CurrenciesUiLocale, Record<string, string>> = {
  en: build(0),
  ru: build(1),
  kk: build(2),
}
