/** Texts of the "Send password reset instructions" button on the user page (REQ-789), per UI language.
 *  Local on purpose: the page has no IntlProvider. The kk texts are machine drafts until the owner's native check. */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import type { User } from '@/types/api'

export type PasswordResetMessages = {
  button: string
  confirmTitle: string
  /** {email} is the stored e-mail address of the user. */
  confirmBody: string
  confirm: string
  cancel: string
  sending: string
  /** {email} is the stored e-mail address of the user. */
  sent: string
  hintInactive: string
  hintNoLogin: string
  hintNoEmail: string
  errorInactive: string
  errorNoLogin: string
  errorNoEmail: string
}

export const passwordResetMessages: Record<UiLocale, PasswordResetMessages> = {
  en: {
    button: 'Send password reset instructions',
    confirmTitle: 'Send password reset instructions',
    confirmBody: 'An e-mail with a link to set a new password will be sent to {email}.',
    confirm: 'Send',
    cancel: 'Cancel',
    sending: 'Sending...',
    sent: 'Password reset instructions were requested for {email}.',
    hintInactive: 'This user is inactive, so no reset message can be sent.',
    hintNoLogin: "This user does not sign in through the company's sign-in page, so there is no password to reset here.",
    hintNoEmail: 'This user has no e-mail address. Add one and save, then send the instructions.',
    errorInactive: 'This user is inactive, so no reset message can be sent.',
    errorNoLogin: "This user does not sign in through the company's sign-in page, so there is no password to reset here.",
    errorNoEmail: 'This user has no e-mail address. Add one and save, then send the instructions.',
  },
  ru: {
    button: 'Отправить инструкцию по сбросу пароля',
    confirmTitle: 'Отправить инструкцию по сбросу пароля',
    confirmBody: 'Письмо со ссылкой для установки нового пароля будет отправлено на {email}.',
    confirm: 'Отправить',
    cancel: 'Отмена',
    sending: 'Отправка...',
    sent: 'Инструкция по сбросу пароля запрошена для {email}.',
    hintInactive: 'Пользователь неактивен, поэтому письмо для сброса пароля отправить нельзя.',
    hintNoLogin: 'Этот пользователь входит не через общую страницу входа компании, поэтому сбрасывать здесь нечего.',
    hintNoEmail: 'У пользователя нет адреса электронной почты. Добавьте его, сохраните и отправьте инструкцию.',
    errorInactive: 'Пользователь неактивен, поэтому письмо для сброса пароля отправить нельзя.',
    errorNoLogin: 'Этот пользователь входит не через общую страницу входа компании, поэтому сбрасывать здесь нечего.',
    errorNoEmail: 'У пользователя нет адреса электронной почты. Добавьте его, сохраните и отправьте инструкцию.',
  },
  kk: {
    button: 'Құпиясөзді қалпына келтіру нұсқауын жіберу',
    confirmTitle: 'Құпиясөзді қалпына келтіру нұсқауын жіберу',
    confirmBody: 'Жаңа құпиясөзді орнату сілтемесі бар хат {email} мекенжайына жіберіледі.',
    confirm: 'Жіберу',
    cancel: 'Бас тарту',
    sending: 'Жіберілуде...',
    sent: '{email} үшін құпиясөзді қалпына келтіру нұсқауы сұралды.',
    hintInactive: 'Пайдаланушы белсенді емес, сондықтан хат жіберу мүмкін емес.',
    hintNoLogin: 'Бұл пайдаланушы компанияның ортақ кіру бетінен кірмейді, сондықтан мұнда қалпына келтіретін ештеңе жоқ.',
    hintNoEmail: 'Пайдаланушыда электрондық пошта мекенжайы жоқ. Оны қосып, сақтаңыз да, нұсқауды жіберіңіз.',
    errorInactive: 'Пайдаланушы белсенді емес, сондықтан хат жіберу мүмкін емес.',
    errorNoLogin: 'Бұл пайдаланушы компанияның ортақ кіру бетінен кірмейді, сондықтан мұнда қалпына келтіретін ештеңе жоқ.',
    errorNoEmail: 'Пайдаланушыда электрондық пошта мекенжайы жоқ. Оны қосып, сақтаңыз да, нұсқауды жіберіңіз.',
  },
}

export type PasswordResetBlock = 'inactive' | 'noLogin' | 'noEmail'

/** Why the route would refuse this user, in the route's own order (inactive, not oidc, no e-mail); null = it accepts. */
export function passwordResetBlock(user: Pick<User, 'status' | 'auth_source' | 'email'>): PasswordResetBlock | null {
  if (user.status !== 'active') return 'inactive'
  if (user.auth_source !== 'oidc') return 'noLogin'
  if (!user.email || user.email.trim() === '') return 'noEmail'
  return null
}

export function hintText(block: PasswordResetBlock, m: PasswordResetMessages): string {
  return block === 'inactive' ? m.hintInactive : block === 'noLogin' ? m.hintNoLogin : m.hintNoEmail
}

/** Text of a 409 by the server's `detail`; undefined for an unknown detail. */
export function conflictText(detail: unknown, m: PasswordResetMessages): string | undefined {
  if (detail === 'user_inactive') return m.errorInactive
  if (detail === 'no_identity_provider_login') return m.errorNoLogin
  if (detail === 'no_email') return m.errorNoEmail
  return undefined
}

export function fillEmail(text: string, email: string): string {
  return text.replace('{email}', email)
}
