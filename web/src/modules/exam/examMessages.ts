/** examMessages — REQ-338
 *
 *  Message catalog for the hand-written candidate exam-taking screens
 *  (web/src/pages/exam/). Follows the exact convention REQ-336 established
 *  in web/src/i18n/entitiesMessages.ts: a flat `Record<locale, Record<id,
 *  string>>` covering en/ru/kk, every id populated in all three locales.
 *
 *  Deliberately does NOT import REQ-336's `resolveUiLocale`/
 *  `ENTITIES_UI_LOCALES` from entitiesMessages.ts: REQ-336 is a separate,
 *  currently-blocked requirement (ISS-0648) and REQ-338's own text states it
 *  does not depend on REQ-336. `resolveUiLocale` below is this file's own
 *  copy of the same generic navigator-language resolver pattern REQ-336
 *  established (first-catalog-adds-its-own-narrower-resolver), applied
 *  independently to REQ-338's own three-locale set, matching the earlier
 *  REVIEWER pass's acceptance of that pattern rather than sharing REQ-336's
 *  module.
 */

export const EXAM_UI_LOCALES = ['en', 'ru', 'kk'] as const
export type ExamUiLocale = (typeof EXAM_UI_LOCALES)[number]

const EXAM_UI_FALLBACK_LOCALE: ExamUiLocale = 'en'

function isExamUiLocale(value: string): value is ExamUiLocale {
  return (EXAM_UI_LOCALES as readonly string[]).includes(value)
}

/** Resolves the locale this catalog's consumers render in: the first of
 *  `navigator.languages` (or `navigator.language`) whose base language tag
 *  (before any "-REGION" suffix) is one of EXAM_UI_LOCALES, else
 *  EXAM_UI_FALLBACK_LOCALE. Never throws; safe under SSR/test environments
 *  with no `navigator`. */
export function resolveUiLocale(candidates?: readonly string[]): ExamUiLocale {
  const sources =
    candidates ??
    (typeof navigator !== 'undefined'
      ? navigator.languages && navigator.languages.length > 0
        ? navigator.languages
        : navigator.language
          ? [navigator.language]
          : []
      : [])

  for (const raw of sources) {
    const base = raw.split('-')[0].toLowerCase()
    if (isExamUiLocale(base)) return base
  }
  return EXAM_UI_FALLBACK_LOCALE
}

export const examMessages: Record<ExamUiLocale, Record<string, string>> = {
  en: {
    // Exam list (start/discovery) screen
    'exam.list.title': 'Available exams',
    'exam.list.loadError': 'Failed to load the list of exams.',
    'exam.list.emptyMessage': 'No active exams found.',
    'exam.list.startAction': 'Start',
    'exam.list.provisionalNotice':
      'Provisional list: assignment enforcement is not implemented yet, so this shows every active exam rather than only the exams assigned to you. This will change once an exam-assignment decision record is adopted.',

    // Start / eligibility errors (REQ-332's six eligibility errors)
    'exam.start.error.not_assigned': 'You are not assigned to this exam.',
    'exam.start.error.exam_archived': 'This exam has been archived and is no longer available.',
    'exam.start.error.exam_not_active': 'This exam is not currently active.',
    'exam.start.error.outside_availability_window': 'This exam is not available at this time.',
    'exam.start.error.attempts_exhausted': 'You have used all allowed attempts for this exam.',
    'exam.start.error.session_already_open': 'You already have an active session for this exam.',
    'exam.start.error.unknown': 'Could not start this exam. Please try again.',
    'exam.start.retryAction': 'Back to exam list',
    'exam.start.starting': 'Starting your exam session…',

    // In-progress screen
    'exam.session.remainingTime': 'Time remaining: {minutes}:{seconds}',
    'exam.session.saveStatus.saving': 'Saving…',
    'exam.session.saveStatus.saved': 'Saved',
    'exam.session.saveStatus.error': 'Could not save your answer. Please try again.',
    'exam.session.submitAction': 'Submit exam',
    'exam.session.submitError': 'Your exam could not be submitted. Please try again.',
    'exam.session.questionOf': 'Question {current} of {total}',
    'exam.session.expired.title': 'Your exam session has expired',
    'exam.session.expired.body': 'The time allowed for this exam has run out. Your last saved answers were kept.',
    'exam.session.autoSubmitted.warning':
      'A suspicious activity signal was detected and this session was automatically submitted.',
    'exam.session.shortTextPlaceholder': 'Type your answer here…',
    'exam.session.shortTextLabel': 'Your answer',
    'exam.session.prevQuestion': 'Previous',
    'exam.session.nextQuestion': 'Next',

    // Anti-cheat
    'exam.anticheat.warning': 'Warning: leaving the exam window has been detected ({count} time(s)). Further activity may auto-submit your exam.',

    // Result screen
    'exam.result.title': 'Exam result',
    'exam.result.gradingPending.title': 'Grading in progress',
    'exam.result.gradingPending.body':
      'One or more of your answers require manual grading. Your final result will be available once grading is complete.',
    'exam.result.score': 'Score: {score} / {maxScore} ({percentage}%)',
    'exam.result.passed': 'Passed',
    'exam.result.failed': 'Not passed',
    'exam.result.backToList': 'Back to exam list',

    // Result-by-id screen (REQ-351) -- loading/error states specific to
    // opening an EXISTING session by id via GET /modules/exam/exam-sessions/:id, rather
    // than the live start->answer->submit flow.
    'exam.result.byId.loading': 'Loading your result…',
    'exam.result.byId.notFound': 'This exam session could not be found.',
    'exam.result.byId.scoreUnavailable':
      'This session has been submitted, but GET /modules/exam/exam-sessions/:id does not yet return score data -- see REQ-351\'s close-out for the tracked gap. Open the exam again from the exam list to see your score at submit time.',
  },
  ru: {
    'exam.list.title': 'Доступные экзамены',
    'exam.list.loadError': 'Не удалось загрузить список экзаменов.',
    'exam.list.emptyMessage': 'Активные экзамены не найдены.',
    'exam.list.startAction': 'Начать',
    'exam.list.provisionalNotice':
      'Предварительный список: проверка назначения ещё не реализована, поэтому здесь показаны все активные экзамены, а не только назначенные вам. Это изменится после принятия решения о модели назначения экзаменов.',

    'exam.start.error.not_assigned': 'Вам не назначен этот экзамен.',
    'exam.start.error.exam_archived': 'Этот экзамен архивирован и больше недоступен.',
    'exam.start.error.exam_not_active': 'Этот экзамен сейчас не активен.',
    'exam.start.error.outside_availability_window': 'Этот экзамен сейчас недоступен по времени.',
    'exam.start.error.attempts_exhausted': 'Вы использовали все попытки для этого экзамена.',
    'exam.start.error.session_already_open': 'У вас уже есть активная сессия для этого экзамена.',
    'exam.start.error.unknown': 'Не удалось начать этот экзамен. Попробуйте снова.',
    'exam.start.retryAction': 'Назад к списку экзаменов',
    'exam.start.starting': 'Запуск вашей экзаменационной сессии…',

    'exam.session.remainingTime': 'Осталось времени: {minutes}:{seconds}',
    'exam.session.saveStatus.saving': 'Сохранение…',
    'exam.session.saveStatus.saved': 'Сохранено',
    'exam.session.saveStatus.error': 'Не удалось сохранить ваш ответ. Попробуйте снова.',
    'exam.session.submitAction': 'Завершить экзамен',
    'exam.session.submitError': 'Не удалось отправить экзамен. Попробуйте снова.',
    'exam.session.questionOf': 'Вопрос {current} из {total}',
    'exam.session.expired.title': 'Ваша экзаменационная сессия истекла',
    'exam.session.expired.body': 'Время, отведённое на этот экзамен, закончилось. Ваши последние сохранённые ответы сохранены.',
    'exam.session.autoSubmitted.warning':
      'Обнаружен сигнал подозрительной активности, и эта сессия была автоматически завершена.',
    'exam.session.shortTextPlaceholder': 'Введите ваш ответ здесь…',
    'exam.session.shortTextLabel': 'Ваш ответ',
    'exam.session.prevQuestion': 'Назад',
    'exam.session.nextQuestion': 'Далее',

    'exam.anticheat.warning': 'Внимание: обнаружен выход из окна экзамена ({count} раз(а)). Дальнейшая активность может привести к автоматическому завершению экзамена.',

    'exam.result.title': 'Результат экзамена',
    'exam.result.gradingPending.title': 'Идёт проверка',
    'exam.result.gradingPending.body':
      'Один или несколько ваших ответов требуют ручной проверки. Итоговый результат будет доступен после завершения проверки.',
    'exam.result.score': 'Баллы: {score} / {maxScore} ({percentage}%)',
    'exam.result.passed': 'Сдано',
    'exam.result.failed': 'Не сдано',
    'exam.result.backToList': 'Назад к списку экзаменов',

    'exam.result.byId.loading': 'Загрузка результата…',
    'exam.result.byId.notFound': 'Эта экзаменационная сессия не найдена.',
    'exam.result.byId.scoreUnavailable':
      'Эта сессия отправлена, но GET /modules/exam/exam-sessions/:id пока не возвращает данные о баллах -- см. отчёт REQ-351 об этом пробеле. Откройте экзамен заново из списка экзаменов, чтобы увидеть свой результат в момент отправки.',
  },
  kk: {
    'exam.list.title': 'Қолжетімді емтихандар',
    'exam.list.loadError': 'Емтихандар тізімін жүктеу мүмкін болмады.',
    'exam.list.emptyMessage': 'Белсенді емтихандар табылмады.',
    'exam.list.startAction': 'Бастау',
    'exam.list.provisionalNotice':
      'Уақытша тізім: тағайындауды тексеру әлі енгізілмеген, сондықтан мұнда сізге тағайындалған емтихандар ғана емес, барлық белсенді емтихандар көрсетіледі. Бұл емтиханға тағайындау моделі туралы шешім қабылданғаннан кейін өзгереді.',

    'exam.start.error.not_assigned': 'Сізге бұл емтихан тағайындалмаған.',
    'exam.start.error.exam_archived': 'Бұл емтихан мұрағатталған және енді қолжетімді емес.',
    'exam.start.error.exam_not_active': 'Бұл емтихан қазір белсенді емес.',
    'exam.start.error.outside_availability_window': 'Бұл емтихан қазіргі уақытта қолжетімді емес.',
    'exam.start.error.attempts_exhausted': 'Сіз бұл емтихан үшін барлық рұқсат етілген әрекеттерді пайдаландыңыз.',
    'exam.start.error.session_already_open': 'Сізде бұл емтихан үшін белсенді сессия бар.',
    'exam.start.error.unknown': 'Бұл емтиханды бастау мүмкін болмады. Қайталап көріңіз.',
    'exam.start.retryAction': 'Емтихандар тізіміне оралу',
    'exam.start.starting': 'Емтихан сессиясы басталуда…',

    'exam.session.remainingTime': 'Қалған уақыт: {minutes}:{seconds}',
    'exam.session.saveStatus.saving': 'Сақталуда…',
    'exam.session.saveStatus.saved': 'Сақталды',
    'exam.session.saveStatus.error': 'Жауабыңызды сақтау мүмкін болмады. Қайталап көріңіз.',
    'exam.session.submitAction': 'Емтиханды аяқтау',
    'exam.session.submitError': 'Емтиханды жіберу мүмкін болмады. Қайталап көріңіз.',
    'exam.session.questionOf': '{total} сұрақтың {current}-і',
    'exam.session.expired.title': 'Емтихан сессияңыздың уақыты аяқталды',
    'exam.session.expired.body': 'Бұл емтиханға берілген уақыт аяқталды. Соңғы сақталған жауаптарыңыз сақталды.',
    'exam.session.autoSubmitted.warning':
      'Күдікті белсенділік сигналы анықталды, және бұл сессия автоматты түрде аяқталды.',
    'exam.session.shortTextPlaceholder': 'Жауабыңызды осында теріңіз…',
    'exam.session.shortTextLabel': 'Сіздің жауабыңыз',
    'exam.session.prevQuestion': 'Артқа',
    'exam.session.nextQuestion': 'Алға',

    'exam.anticheat.warning': 'Ескерту: емтихан терезесінен шығу анықталды ({count} рет). Одан әрі белсенділік емтиханды автоматты түрде аяқтауы мүмкін.',

    'exam.result.title': 'Емтихан нәтижесі',
    'exam.result.gradingPending.title': 'Тексеру жүріп жатыр',
    'exam.result.gradingPending.body':
      'Жауаптарыңыздың бір немесе бірнешеуі қолмен тексеруді қажет етеді. Түпкілікті нәтиже тексеру аяқталғаннан кейін қолжетімді болады.',
    'exam.result.score': 'Балл: {score} / {maxScore} ({percentage}%)',
    'exam.result.passed': 'Өтті',
    'exam.result.failed': 'Өтпеді',
    'exam.result.backToList': 'Емтихандар тізіміне оралу',

    'exam.result.byId.loading': 'Нәтиже жүктелуде…',
    'exam.result.byId.notFound': 'Бұл емтихан сессиясы табылмады.',
    'exam.result.byId.scoreUnavailable':
      'Бұл сессия жіберілді, бірақ GET /modules/exam/exam-sessions/:id әлі балл деректерін қайтармайды -- осы олқылық туралы REQ-351 есебін қараңыз. Жіберу сәтіндегі нәтижеңізді көру үшін емтиханды тізімнен қайта ашыңыз.',
  },
}
