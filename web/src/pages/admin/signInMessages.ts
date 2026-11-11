/** Texts of "Create sign-in" (REQ-809) per UI language: the user-page action, the new-user checkbox, the
 *  one-time password panel and one plain sentence per refusal reason of REQ-807 (plus `not_attempted` of REQ-808).
 *  Local on purpose, like passwordResetMessages.ts. The kk texts are machine drafts until the owner's native check. */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import type { FeedbackMessages } from '@/components/ui/feedbackMessages'
import { saveErrorText } from '@/utils/saveError'

export const SIGN_IN_REASONS = [
  'sign_in_creation_off',
  'user_inactive',
  'sign_in_exists',
  'no_email',
  'realm_not_provisioned',
  'login_exists_in_realm',
  'provisioner_unavailable',
  'provisioner_refused',
  'service_principal',
  'not_attempted',
] as const

export type SignInReason = (typeof SIGN_IN_REASONS)[number]

export type SignInMessages = {
  action: string
  creating: string
  checkbox: string
  panelTitle: string
  usernameLabel: string
  passwordLabel: string
  copy: string
  copied: string
  onceNote: string
  close: string
  openUser: string
  /** {reason} is the plain-words refusal text. */
  createdNoSignIn: string
  reasons: Record<SignInReason, string>
}

export const signInMessages: Record<UiLocale, SignInMessages> = {
  en: {
    action: 'Create sign-in',
    creating: 'Creating...',
    checkbox: 'Create sign-in now',
    panelTitle: 'Sign-in created',
    usernameLabel: 'Username',
    passwordLabel: 'Temporary password',
    copy: 'Copy',
    copied: 'Copied',
    onceNote: 'This password is shown only once. Give it to the person; they must change it at the first sign-in.',
    close: 'Close',
    openUser: 'Open user page',
    createdNoSignIn: 'The user was created, but the sign-in was not: {reason}',
    reasons: {
      sign_in_creation_off: 'Creating sign-ins is not available yet.',
      user_inactive: 'The user is inactive. Activate the user first.',
      sign_in_exists: 'This user already has a sign-in.',
      no_email: 'The user has no e-mail address. Add one and try again.',
      realm_not_provisioned: "The company's sign-in page is not set up yet.",
      login_exists_in_realm: 'A sign-in with this username or e-mail already exists on the company sign-in page.',
      provisioner_unavailable: 'The sign-in service is not reachable right now. Try again later.',
      provisioner_refused: 'The sign-in service refused to create the sign-in.',
      service_principal: 'This is a service account; it cannot have a person sign-in.',
      not_attempted: 'No sign-in was attempted for this row.',
    },
  },
  ru: {
    action: 'Создать вход',
    creating: 'Создание...',
    checkbox: 'Сразу создать вход',
    panelTitle: 'Вход создан',
    usernameLabel: 'Имя пользователя',
    passwordLabel: 'Временный пароль',
    copy: 'Копировать',
    copied: 'Скопировано',
    onceNote: 'Пароль показан только один раз. Передайте его человеку; при первом входе он должен его сменить.',
    close: 'Закрыть',
    openUser: 'Открыть страницу пользователя',
    createdNoSignIn: 'Пользователь создан, но вход не создан: {reason}',
    reasons: {
      sign_in_creation_off: 'Создание входа пока недоступно.',
      user_inactive: 'Пользователь неактивен. Сначала активируйте его.',
      sign_in_exists: 'У пользователя уже есть вход.',
      no_email: 'У пользователя нет адреса электронной почты. Добавьте его и повторите.',
      realm_not_provisioned: 'Страница входа компании ещё не настроена.',
      login_exists_in_realm: 'Вход с таким именем или адресом почты уже есть на странице входа компании.',
      provisioner_unavailable: 'Служба входа сейчас недоступна. Повторите позже.',
      provisioner_refused: 'Служба входа отказалась создать вход.',
      service_principal: 'Это служебная учётная запись; вход для человека ей не нужен.',
      not_attempted: 'Для этой строки создание входа не выполнялось.',
    },
  },
  kk: {
    action: 'Кіруді жасау',
    creating: 'Жасалуда...',
    checkbox: 'Кіруді дереу жасау',
    panelTitle: 'Кіру жасалды',
    usernameLabel: 'Пайдаланушы аты',
    passwordLabel: 'Уақытша құпиясөз',
    copy: 'Көшіру',
    copied: 'Көшірілді',
    onceNote: 'Құпиясөз тек бір рет көрсетіледі. Оны адамға беріңіз; ол алғашқы кіруде оны ауыстыруы керек.',
    close: 'Жабу',
    openUser: 'Пайдаланушы бетін ашу',
    createdNoSignIn: 'Пайдаланушы жасалды, бірақ кіру жасалмады: {reason}',
    reasons: {
      sign_in_creation_off: 'Кіруді жасау әзірге қолжетімсіз.',
      user_inactive: 'Пайдаланушы белсенді емес. Алдымен оны белсендіріңіз.',
      sign_in_exists: 'Пайдаланушыда кіру бұрыннан бар.',
      no_email: 'Пайдаланушыда электрондық пошта мекенжайы жоқ. Оны қосып, қайталаңыз.',
      realm_not_provisioned: 'Компанияның кіру беті әлі бапталмаған.',
      login_exists_in_realm: 'Мұндай атпен немесе поштамен кіру компанияның кіру бетінде бұрыннан бар.',
      provisioner_unavailable: 'Кіру қызметі қазір қолжетімсіз. Кейінірек қайталаңыз.',
      provisioner_refused: 'Кіру қызметі кіруді жасаудан бас тартты.',
      service_principal: 'Бұл қызметтік тіркелгі; оған адамның кіруі қажет емес.',
      not_attempted: 'Бұл жол үшін кіру жасалмады.',
    },
  },
}

export function fillReason(text: string, reason: string): string {
  return text.replace('{reason}', reason)
}

/** Plain-words text of a refusal reason; undefined for an unknown one. */
export function signInReasonText(detail: unknown, m: SignInMessages): string | undefined {
  if (typeof detail !== 'string') return undefined
  return (SIGN_IN_REASONS as readonly string[]).includes(detail) ? m.reasons[detail as SignInReason] : undefined
}

/** Text of a failed sign-in call: a 409 with a known `detail` names the reason, anything else is the generic save error. */
export function signInErrorText(error: unknown, m: SignInMessages, feedback: FeedbackMessages): string {
  const status = (error as { status?: unknown })?.status
  const detail = (error as { details?: { detail?: unknown } })?.details?.detail
  return (status === 409 ? signInReasonText(detail, m) : undefined) ?? saveErrorText(error, feedback)
}
