/** assetsHelpTopics — T-1560. The closed list of help topics of the assets module and the permission of the screen
 *  each one explains (help never opens for a user who cannot open the screen). */
import { ASSETS_CARD_WRITE, ASSETS_READ } from '../assetsPermissions'

export const ASSETS_HELP_TOPICS = ['cards', 'documents', 'balances', 'movements'] as const
export type AssetsHelpTopic = (typeof ASSETS_HELP_TOPICS)[number]

export const ASSETS_HELP_PERMISSION: Record<AssetsHelpTopic, string> = {
  cards: ASSETS_CARD_WRITE,
  documents: ASSETS_READ,
  balances: ASSETS_READ,
  movements: ASSETS_READ,
}

export function isAssetsHelpTopic(value: string | undefined): value is AssetsHelpTopic {
  return value !== undefined && (ASSETS_HELP_TOPICS as readonly string[]).includes(value)
}

export const assetsHelpPath = (topic: AssetsHelpTopic) => `/admin/assets/help/${topic}`
