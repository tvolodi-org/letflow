/** loginMessages -- REQ-438
 *
 *  Message catalog for the public email-first login page (decision 0021).
 *  Locales: the same three the entities catalog ships (en, ru, kk); the
 *  locale resolver is reused from entitiesMessages.ts. Every id has all three
 *  locales populated (asserted by web/src/__tests__/login-i18n-grep.test.ts).
 *
 *  Wording rule: no message may say or imply whether an address is registered.
 */
import type { EntitiesUiLocale } from './entitiesMessages'

export const loginMessages: Record<EntitiesUiLocale, Record<string, string>> = {
  en: {
    'login.title': 'Sign in',
    'login.skipToContent': 'Skip to main content',
    'login.intro': 'Enter your work email address to continue to your organisation sign-in.',
    'login.email.label': 'Email address',
    'login.email.placeholder': 'name@example.com',
    'login.email.invalid': 'Enter a valid email address.',
    'login.submit': 'Continue',
    'login.submitting': 'Checking...',
    'login.neutral':
      'If this address is registered, instructions have been sent to it. You can also sign in with your organisation code below.',
    'login.error.network':
      'We could not reach the sign-in service. Check your connection and try again, or use your organisation code below.',
    'login.error.rateLimited':
      'Too many attempts. Please wait a moment and try again, or use your organisation code below.',
    'login.error.malformed':
      'The sign-in service sent an unexpected reply. Try again, or use your organisation code below.',
    'login.retry': 'Try again',
    'login.org.heading': 'Have an organisation code?',
    'login.org.label': 'Organisation code',
    'login.org.invalid': 'Enter your organisation code (up to 255 characters).',
    'login.org.submit': 'Go to sign-in',
  },
  ru: {
    'login.title': 'Вход',
    'login.skipToContent': 'Перейти к основному содержимому',
    'login.intro': 'Введите рабочий адрес электронной почты, чтобы перейти ко входу в вашу организацию.',
    'login.email.label': 'Адрес электронной почты',
    'login.email.placeholder': 'name@example.com',
    'login.email.invalid': 'Введите корректный адрес электронной почты.',
    'login.submit': 'Продолжить',
    'login.submitting': 'Проверка...',
    'login.neutral':
      'Если этот адрес зарегистрирован, на него отправлены инструкции. Вы также можете войти по коду организации ниже.',
    'login.error.network':
      'Не удалось связаться со службой входа. Проверьте подключение и повторите попытку или воспользуйтесь кодом организации ниже.',
    'login.error.rateLimited':
      'Слишком много попыток. Подождите немного и повторите попытку или воспользуйтесь кодом организации ниже.',
    'login.error.malformed':
      'Служба входа вернула непредвиденный ответ. Повторите попытку или воспользуйтесь кодом организации ниже.',
    'login.retry': 'Повторить',
    'login.org.heading': 'Есть код организации?',
    'login.org.label': 'Код организации',
    'login.org.invalid': 'Введите код организации (не более 255 символов).',
    'login.org.submit': 'Перейти ко входу',
  },
  kk: {
    'login.title': 'Кіру',
    'login.skipToContent': 'Негізгі мазмұнға өту',
    'login.intro': 'Ұйымыңызға кіруге өту үшін жұмыс электрондық поштаңызды енгізіңіз.',
    'login.email.label': 'Электрондық пошта мекенжайы',
    'login.email.placeholder': 'name@example.com',
    'login.email.invalid': 'Электрондық пошта мекенжайын дұрыс енгізіңіз.',
    'login.submit': 'Жалғастыру',
    'login.submitting': 'Тексерілуде...',
    'login.neutral':
      'Егер бұл мекенжай тіркелген болса, оған нұсқаулар жіберілді. Төмендегі ұйым коды арқылы да кіре аласыз.',
    'login.error.network':
      'Кіру қызметіне қосыла алмадық. Байланысты тексеріп, қайталап көріңіз немесе төмендегі ұйым кодын пайдаланыңыз.',
    'login.error.rateLimited':
      'Әрекеттер тым көп. Сәл күтіп, қайталап көріңіз немесе төмендегі ұйым кодын пайдаланыңыз.',
    'login.error.malformed':
      'Кіру қызметі күтпеген жауап қайтарды. Қайталап көріңіз немесе төмендегі ұйым кодын пайдаланыңыз.',
    'login.retry': 'Қайталау',
    'login.org.heading': 'Ұйым коды бар ма?',
    'login.org.label': 'Ұйым коды',
    'login.org.invalid': 'Ұйым кодын енгізіңіз (ең көбі 255 таңба).',
    'login.org.submit': 'Кіруге өту',
  },
}
