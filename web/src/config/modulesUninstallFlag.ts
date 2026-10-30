/** Module uninstall screen build flag (REQ-630; decision 0066 D8 slice 5).
 *
 *  `VITE_MODULES_UNINSTALL_ENABLED` is a build-time Vite variable. Only the
 *  exact value `true` shows the module lifecycle page and its nav entry;
 *  absent, empty or anything else is OFF. It is a visibility switch only: the
 *  SPA cannot read the server flag, and the server decides every call (a
 *  disabled server answers 404). No committed non-dev env file or vite config
 *  may set it to true (web/src/config/modulesUninstallFlag.test.ts).
 */
export function isModulesUninstallEnabled(): boolean {
  return (import.meta.env.VITE_MODULES_UNINSTALL_ENABLED as string | undefined) === 'true'
}
