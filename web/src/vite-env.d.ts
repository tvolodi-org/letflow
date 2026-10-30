/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** REQ-438: only the exact value 'true' enables the email-first login screen. */
  readonly VITE_EMAIL_FIRST_LOGIN?: string
  readonly VITE_MODULES_UNINSTALL_ENABLED?: string
}
