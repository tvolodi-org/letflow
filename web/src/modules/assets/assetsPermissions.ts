/** The permission atoms of the assets module screens. The server stays the authority (REQ-750, C8, C10, C11); the SPA
 *  only hides what the user's access does not list. */
export const ASSETS_CARD_WRITE = 'AssetsCardWrite'
/** Reads: the documents list and view, balances and movements (C8, C10). */
export const ASSETS_READ = 'AssetsRead'
/** Issue and discard of a draft document (C10). */
export const ASSETS_POST = 'AssetsPost'
/** Reverse of a posted document (C11). */
export const ASSETS_REVERSE = 'AssetsReverse'
