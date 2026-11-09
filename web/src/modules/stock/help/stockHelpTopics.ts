/** stockHelpTopics — T-1560. The closed list of help topics of the stock module. Every topic explains a screen that
 *  needs STOCK_READ, so the help route needs the same permission. */
export const STOCK_HELP_TOPICS = ['documents', 'balances', 'movements', 'counts'] as const
export type StockHelpTopic = (typeof STOCK_HELP_TOPICS)[number]

export function isStockHelpTopic(value: string | undefined): value is StockHelpTopic {
  return value !== undefined && (STOCK_HELP_TOPICS as readonly string[]).includes(value)
}

export const stockHelpPath = (topic: StockHelpTopic) => `/admin/stock/help/${topic}`
