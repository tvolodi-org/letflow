/** coreHelpMessages — T-1691. Static help texts of five core screens, en/ru/kk, flattened into catalogue ids
 *  `core.help.<topic>.<part>` (shape of B2#8: purpose, three tasks, three refusals). Plain description only. The ru and
 *  kk texts are drafts until the owner's native-speaker check (docs/assets/i18n-gaps.md). */
import { flattenHelp, type HelpCommonText, type HelpTopicText } from '@/components/help/helpTopicText'
import type { UiLocale } from '@/i18n/uiLocaleStore'
import type { CoreHelpTopic } from './coreHelpTopics'

type Topics = Record<CoreHelpTopic, HelpTopicText>

const commonEn: HelpCommonText = { link: 'Help', close: 'Close', back: 'Back to the screen', purpose: 'What this screen is for', tasks: 'Three common tasks', refusals: 'What a refusal means' }
const commonRu: HelpCommonText = { link: 'Справка', close: 'Закрыть', back: 'Назад к экрану', purpose: 'Для чего этот экран', tasks: 'Три частые задачи', refusals: 'Что значит отказ' }
const commonKk: HelpCommonText = { link: 'Анықтама', close: 'Жабу', back: 'Экранға оралу', purpose: 'Бұл экран не үшін', tasks: 'Үш жиі міндет', refusals: 'Бас тарту нені білдіреді' }

const en: Topics = {
  usersImport: {
    title: 'Help: import users',
    purpose: 'Creates several users at once from an Excel file. The file is checked first and nothing is written until every row is correct.',
    tasks: [
      'Press "Download template", fill one row per user in it (user name, display name, e-mail) and save it as .xlsx.',
      'Drop the file on the screen and press "Check file". Fix any refused row in your file and check it again.',
      'When the check says "Ready to import", press "Import users".',
    ],
    refusals: [
      { title: 'The file is refused as a whole', body: 'It is not a readable .xlsx file, has columns that are not in the template, or is over 200 data rows or 2 MB. Start again from the template.' },
      { title: 'A row is refused, so the import button stays off', body: 'Open the reason next to the row, or download the refused rows as CSV. Correct them in your file and check it again.' },
      { title: 'A user shows as unchanged', body: 'This user already exists with the same data. An existing user is never changed by an import. Imported users cannot sign in until they are invited or set a password.' },
    ],
  },
  passwordReset: {
    title: 'Help: password reset instructions',
    purpose: 'On the page of a user, the button sends that user an e-mail that tells them to choose "Forgot password" on the sign-in page. You never see or set the password.',
    tasks: [
      'Open the user in the users list and press "Send password reset instructions".',
      'Check the e-mail address in the question and press "Send".',
      'Tell the user to open the e-mail and follow it on the sign-in page.',
    ],
    refusals: [
      { title: 'The user is inactive', body: 'No message is sent to an inactive user. Activate the user first, then send the instructions.' },
      { title: 'The user does not sign in through the company sign-in page', body: 'There is no password to reset here. The user resets it where they sign in.' },
      { title: 'The user has no e-mail address', body: 'Add the address to the user, save, and send the instructions again.' },
    ],
  },
  instanceReplay: {
    title: 'Help: replay of an instance',
    purpose: 'On the Graph tab of an instance, "Replay" steps through the path the instance really took, one recorded step at a time, with the time of each step.',
    tasks: [
      'Open an instance, choose the Graph tab and switch the view from "Live" to "Replay".',
      'Use "First step", "Previous step", "Next step" and "Last step" to move along the path; the diagram shows the state after that step.',
      'Read the list of recorded steps to see when each step happened and how long it took after the one before.',
    ],
    refusals: [
      { title: 'No path was recorded for this instance', body: 'The instance ran before step recording started. The "Live" view still shows the path worked out from task events.' },
      { title: 'Steps before a given time were not recorded', body: 'Only the steps from that time on can be replayed. Earlier steps are not guessed.' },
      { title: 'Not all steps could be loaded', body: 'The replay shows the steps read so far. Very long paths are shown only up to a fixed limit, and opening the instance again does not remove it. If loading failed for a moment, press Retry on the banner.' },
    ],
  },
  moduleRollouts: {
    title: 'Help: module rollouts',
    purpose: 'For platform operators. A rollout puts a new version of a module onto the companies one by one, and shows how it went for each company.',
    tasks: [
      'Type the module id and press "Start rollout". The new rollout appears at the top of the list.',
      'Pick a rollout in the list to see each company, its outcome and the error code of a failed one.',
      'If a rollout is halted, fix the cause and press "Resume" to retry the failed companies.',
    ],
    refusals: [
      { title: 'The rollout is halted', body: 'It stopped after several failures in a row to protect the other companies. They were not touched. Resume retries the failed ones.' },
      { title: 'A company is outside its upgrade window', body: 'The company is only upgraded in its own window. It is retried by the next start or resume.' },
      { title: 'Resume is not offered', body: 'The button appears only when the rollout is halted, or when some company failed, is waiting or is outside its window, or has been stuck on "running" for over 15 minutes. If it is missing, there is nothing left to retry.' },
    ],
  },
  createSignIn: {
    title: 'Help: create a sign-in',
    purpose: 'Gives a user of your company a first password so that they can sign in. The password is shown to you once, on the screen, and is never shown again.',
    tasks: [
      'Open the user in the users list and press "Create sign-in".',
      'Copy the password shown and hand it over safely: in person or by a private message, never in a group chat.',
      'Tell the user that the system asks them to change the password at the first sign-in.',
    ],
    refusals: [
      { title: 'The password is gone', body: 'It is shown once only and cannot be shown again. The sign-in cannot be created a second time; use the password reset instructions for this user.' },
      { title: 'The action is not available', body: 'Creating a sign-in is not switched on for your company yet. Nothing was changed; ask the platform operator or use the password reset instructions.' },
      { title: 'The user is refused', body: 'The user is inactive or has no e-mail address. Fix this on the user page and try again.' },
    ],
  },
  longLists: {
    title: 'Help: long lists and the "showing the first" notice',
    purpose: 'Screens with many records (asset cards, codes, items, locations, org units, stock documents) load them in parts. When a list is longer than the screen loads, a notice says how many records are shown.',
    tasks: [
      'Press "Load more" under the list to bring the next part, until the record you need appears.',
      'Narrow the list with the filters, or type more of the number or name in the search, instead of scrolling a long list.',
      'In a picker (item, location, employee) all records are offered, up to 10 000 of a kind; a notice appears on the screen only when the list is cut.',
    ],
    refusals: [
      { title: 'A notice says "Showing the first ..."', body: 'The list is longer than what is shown. Nothing is lost: use "Load more", the filters or the search to reach the other records.' },
      { title: 'A record is not in the picker', body: 'A picker holds up to 10 000 records of a kind. When a list is longer, the screen says so and the rest cannot be chosen there. If there is no notice, ask the administrator whether you may see the record.' },
      { title: 'The search finds fewer records than I expect', body: 'You see only the org units you may access, and a search shows its first matches only. Type more of the number or name to narrow it.' },
    ],
  },
}

const ru: Topics = {
  usersImport: {
    title: 'Справка: импорт пользователей',
    purpose: 'Создаёт сразу несколько пользователей из файла Excel. Сначала файл проверяется, и ничего не записывается, пока все строки не верны.',
    tasks: [
      'Нажмите «Скачать шаблон», заполните по строке на пользователя (имя пользователя, отображаемое имя, почта) и сохраните как .xlsx.',
      'Перетащите файл на экран и нажмите «Проверить файл». Исправьте отклонённые строки в файле и проверьте его снова.',
      'Когда проверка покажет «Готово к импорту», нажмите «Импортировать».',
    ],
    refusals: [
      { title: 'Файл отклонён целиком', body: 'Это не читаемый файл .xlsx, в нём есть колонки не из шаблона, или в нём больше 200 строк данных либо больше 2 МБ. Начните заново с шаблона.' },
      { title: 'Строка отклонена, поэтому импорт недоступен', body: 'Причина указана рядом со строкой; отклонённые строки можно скачать в CSV. Исправьте их в файле и проверьте снова.' },
      { title: 'Пользователь показан как «без изменений»', body: 'Такой пользователь уже есть с теми же данными. Импорт никогда не меняет существующих. Импортированные не могут войти, пока их не пригласят или они не зададут пароль.' },
    ],
  },
  passwordReset: {
    title: 'Справка: инструкция по сбросу пароля',
    purpose: 'На странице пользователя кнопка отправляет ему письмо с указанием выбрать «Забыли пароль» на странице входа. Вы не видите и не задаёте пароль.',
    tasks: [
      'Откройте пользователя в списке и нажмите «Отправить инструкцию по сбросу пароля».',
      'Проверьте адрес почты в вопросе и нажмите «Отправить».',
      'Попросите пользователя открыть письмо и выполнить его на странице входа.',
    ],
    refusals: [
      { title: 'Пользователь неактивен', body: 'Неактивному пользователю письмо не отправляется. Сначала активируйте его, затем отправьте инструкцию.' },
      { title: 'Пользователь входит не через общую страницу входа компании', body: 'Сбрасывать здесь нечего. Пароль сбрасывается там, где пользователь входит.' },
      { title: 'У пользователя нет адреса почты', body: 'Добавьте адрес пользователю, сохраните и отправьте инструкцию снова.' },
    ],
  },
  instanceReplay: {
    title: 'Справка: повтор экземпляра',
    purpose: 'На вкладке «Graph» экземпляра режим «Повтор» показывает путь, который экземпляр прошёл на самом деле: шаг за шагом, со временем каждого шага.',
    tasks: [
      'Откройте экземпляр, выберите вкладку Graph и переключите вид с «Сейчас» на «Повтор».',
      'Кнопками «Первый шаг», «Предыдущий шаг», «Следующий шаг», «Последний шаг» двигайтесь по пути; схема показывает состояние после шага.',
      'В списке записанных шагов видно, когда был каждый шаг и сколько прошло с предыдущего.',
    ],
    refusals: [
      { title: 'Для этого экземпляра путь не записан', body: 'Он выполнялся до начала записи шагов. Вид «Сейчас» всё равно показывает путь, выведенный из событий задач.' },
      { title: 'Шаги до указанного времени не записаны', body: 'Повторить можно только шаги, начиная с этого времени. Более ранние шаги не угадываются.' },
      { title: 'Не все шаги удалось загрузить', body: 'Повтор показывает уже прочитанные шаги. Очень длинные пути показываются только до установленного предела, и повторное открытие экземпляра его не снимает. Если загрузка на время не удалась, нажмите «Повторить» на плашке.' },
    ],
  },
  moduleRollouts: {
    title: 'Справка: развёртывание модулей',
    purpose: 'Для операторов платформы. Развёртывание ставит новую версию модуля на компании по очереди и показывает результат по каждой компании.',
    tasks: [
      'Введите идентификатор модуля и нажмите «Начать развёртывание». Новое развёртывание появится вверху списка.',
      'Выберите развёртывание в списке: увидите каждую компанию, её результат и код ошибки, если была ошибка.',
      'Если развёртывание остановлено, устраните причину и нажмите «Продолжить», чтобы повторить неудачные компании.',
    ],
    refusals: [
      { title: 'Развёртывание остановлено', body: 'Оно остановилось после нескольких ошибок подряд, чтобы защитить остальные компании. Их не трогали. «Продолжить» повторит неудачные.' },
      { title: 'Компания вне окна обновления', body: 'Компанию обновляют только в её собственном окне. Повтор будет при следующем запуске или продолжении.' },
      { title: 'Кнопки «Продолжить» нет', body: 'Кнопка появляется, только если развёртывание остановлено, либо какая-то компания завершилась ошибкой, ждёт или вне своего окна, либо зависла в состоянии «выполняется» более 15 минут. Если кнопки нет, повторять нечего.' },
    ],
  },
  createSignIn: {
    title: 'Справка: создание входа',
    purpose: 'Задаёт пользователю вашей компании первый пароль, чтобы он мог войти. Пароль показывается вам один раз на экране и больше не показывается.',
    tasks: [
      'Откройте пользователя в списке и нажмите «Создать вход».',
      'Скопируйте показанный пароль и передайте его безопасно: лично или в личном сообщении, не в общем чате.',
      'Скажите пользователю, что при первом входе система попросит сменить пароль.',
    ],
    refusals: [
      { title: 'Пароль утерян', body: 'Он показывается только один раз и повторно не показывается. Вход нельзя создать второй раз; воспользуйтесь инструкцией по сбросу пароля для этого пользователя.' },
      { title: 'Действие недоступно', body: 'Создание входа для вашей компании пока не включено. Ничего не изменено; обратитесь к оператору платформы или отправьте инструкцию по сбросу пароля.' },
      { title: 'Пользователю отказано', body: 'Пользователь неактивен или у него нет адреса почты. Исправьте это на странице пользователя и повторите.' },
    ],
  },
  longLists: {
    title: 'Справка: длинные списки и сообщение «Показаны первые»',
    purpose: 'Экраны с большим числом записей (карточки основных средств, коды, позиции, места хранения, подразделения, складские документы) загружают их частями. Если список длиннее загруженного, сообщение говорит, сколько записей показано.',
    tasks: [
      'Нажимайте «Загрузить ещё» под списком, пока не появится нужная запись.',
      'Вместо прокрутки длинного списка сузьте его фильтрами или введите в поиск больше символов номера или названия.',
      'В выпадающем списке (позиция, место, сотрудник) доступны все записи, до 10 000 каждого вида; сообщение на экране появляется, только если список обрезан.',
    ],
    refusals: [
      { title: 'Сообщение «Показаны первые ...»', body: 'Список длиннее показанного. Ничего не потеряно: «Загрузить ещё», фильтры или поиск помогут добраться до остальных записей.' },
      { title: 'Записи нет в выпадающем списке', body: 'Выпадающий список вмещает до 10 000 записей каждого вида. Если список длиннее, экран сообщает об этом, и остальные записи там выбрать нельзя. Если сообщения нет, спросите администратора, можно ли вам видеть запись.' },
      { title: 'Поиск находит меньше записей, чем я ждал', body: 'Вы видите только подразделения, к которым у вас есть доступ, а поиск показывает лишь первые совпадения. Введите больше символов номера или названия.' },
    ],
  },
}

const kk: Topics = {
  usersImport: {
    title: 'Анықтама: пайдаланушыларды импорттау',
    purpose: 'Excel файлынан бірнеше пайдаланушыны бірден жасайды. Файл алдымен тексеріледі, барлық жол дұрыс болмайынша ештеңе жазылмайды.',
    tasks: [
      '«Үлгіні жүктеу» түймесін басып, әр пайдаланушыға бір жол толтырыңыз (пайдаланушы аты, көрсетілетін аты, пошта) және .xlsx ретінде сақтаңыз.',
      'Файлды экранға сүйреп, «Файлды тексеру» түймесін басыңыз. Қабылданбаған жолдарды файлда түзетіп, қайта тексеріңіз.',
      'Тексеру «Импортқа дайын» десе, «Импорттау» түймесін басыңыз.',
    ],
    refusals: [
      { title: 'Файл тұтастай қабылданбады', body: 'Ол оқылатын .xlsx емес, үлгіде жоқ бағандары бар немесе 200 жолдан не 2 МБ-тан асады. Үлгіден қайта бастаңыз.' },
      { title: 'Жол қабылданбады, сондықтан импорт өшірулі', body: 'Себебі жолдың жанында көрсетілген; қабылданбаған жолдарды CSV ретінде жүктеуге болады. Оларды файлда түзетіп, қайта тексеріңіз.' },
      { title: 'Пайдаланушы «өзгеріссіз» деп көрсетілді', body: 'Мұндай пайдаланушы сол деректермен бұрыннан бар. Импорт бар пайдаланушыны ешқашан өзгертпейді. Импортталғандар шақырылғанша немесе құпиясөз орнатқанша кіре алмайды.' },
    ],
  },
  passwordReset: {
    title: 'Анықтама: құпиясөзді қалпына келтіру нұсқауы',
    purpose: 'Пайдаланушы бетіндегі түйме оған кіру бетінде «Құпиясөзді ұмыттым» таңдау керектігі туралы хат жібереді. Құпиясөзді көрмейсіз және орнатпайсыз.',
    tasks: [
      'Тізімнен пайдаланушыны ашып, «Құпиясөзді қалпына келтіру нұсқауын жіберу» түймесін басыңыз.',
      'Сұрақтағы пошта мекенжайын тексеріп, «Жіберу» түймесін басыңыз.',
      'Пайдаланушыдан хатты ашып, кіру бетінде орындауын сұраңыз.',
    ],
    refusals: [
      { title: 'Пайдаланушы белсенді емес', body: 'Белсенді емес пайдаланушыға хат жіберілмейді. Алдымен оны белсендіріңіз, содан кейін нұсқауды жіберіңіз.' },
      { title: 'Пайдаланушы компанияның жалпы кіру беті арқылы кірмейді', body: 'Мұнда қалпына келтіретін ештеңе жоқ. Құпиясөз пайдаланушы кіретін жерде қалпына келтіріледі.' },
      { title: 'Пайдаланушыда пошта мекенжайы жоқ', body: 'Мекенжайды қосып, сақтаңыз да, нұсқауды қайта жіберіңіз.' },
    ],
  },
  instanceReplay: {
    title: 'Анықтама: дананы қайталап көру',
    purpose: 'Дананың «Graph» қойындысындағы «Қайталап көру» режимі дананың нақты жүрген жолын қадамдап, әр қадамның уақытымен көрсетеді.',
    tasks: [
      'Дананы ашып, Graph қойындысын таңдаңыз да, көріністі «Қазір» күйінен «Қайталап көру» күйіне ауыстырыңыз.',
      '«Бірінші қадам», «Алдыңғы қадам», «Келесі қадам», «Соңғы қадам» түймелерімен жол бойымен жүріңіз; сызба сол қадамнан кейінгі күйді көрсетеді.',
      'Жазылған қадамдар тізімінен әр қадамның қашан болғанын және алдыңғысынан қанша уақыт өткенін көріңіз.',
    ],
    refusals: [
      { title: 'Бұл дана үшін жол жазылмаған', body: 'Ол қадамдарды жазу басталғанға дейін орындалған. «Қазір» көрінісі тапсырма оқиғаларынан шығарылған жолды көрсете береді.' },
      { title: 'Көрсетілген уақытқа дейінгі қадамдар жазылмаған', body: 'Тек сол уақыттан бастап қадамдарды қайталауға болады. Бұрынғы қадамдар болжанбайды.' },
      { title: 'Қадамдардың бәрі жүктелмеді', body: 'Қайталау оқылған қадамдарды көрсетеді. Өте ұзын жолдар тек белгілі шекке дейін көрсетіледі, дананы қайта ашу бұл шекті алып тастамайды. Жүктеу уақытша сәтсіз болса, жолақтағы «Қайталау» түймесін басыңыз.' },
    ],
  },
  moduleRollouts: {
    title: 'Анықтама: модульдерді тарату',
    purpose: 'Платформа операторларына арналған. Тарату модульдің жаңа нұсқасын компанияларға кезекпен орнатады және әр компания бойынша нәтижені көрсетеді.',
    tasks: [
      'Модуль идентификаторын енгізіп, «Таратуды бастау» түймесін басыңыз. Жаңа тарату тізімнің жоғарғы жағында шығады.',
      'Тізімнен таратуды таңдаңыз: әр компанияны, оның нәтижесін және қате болса, қате кодын көресіз.',
      'Тарату тоқтатылса, себебін жойып, сәтсіз компанияларды қайталау үшін «Жалғастыру» түймесін басыңыз.',
    ],
    refusals: [
      { title: 'Тарату тоқтатылды', body: 'Ол басқа компанияларды қорғау үшін қатарынан бірнеше қатеден кейін тоқтады. Оларға тиіспедік. «Жалғастыру» сәтсіздерін қайталайды.' },
      { title: 'Компания жаңарту терезесінен тыс', body: 'Компания тек өз терезесінде жаңартылады. Келесі бастау немесе жалғастыру кезінде қайталанады.' },
      { title: '«Жалғастыру» түймесі жоқ', body: 'Түйме тек тарату тоқтатылғанда, немесе қандай да бір компания қатемен аяқталғанда, күтіп тұрғанда не терезесінен тыс болғанда, немесе «орындалуда» күйінде 15 минуттан астам тұрып қалғанда көрінеді. Түйме жоқ болса, қайталайтын ештеңе жоқ.' },
    ],
  },
  createSignIn: {
    title: 'Анықтама: кіруді жасау',
    purpose: 'Компания пайдаланушысына кіру үшін алғашқы құпиясөзді береді. Құпиясөз сізге экранда бір рет қана көрсетіледі, қайта көрсетілмейді.',
    tasks: [
      'Тізімнен пайдаланушыны ашып, «Кіруді жасау» түймесін басыңыз.',
      'Көрсетілген құпиясөзді көшіріп, қауіпсіз тапсырыңыз: жеке өзіңіз немесе жеке хабармен, жалпы чатта емес.',
      'Пайдаланушыға алғашқы кіру кезінде жүйе құпиясөзді ауыстыруды сұрайтынын айтыңыз.',
    ],
    refusals: [
      { title: 'Құпиясөз жоғалды', body: 'Ол тек бір рет көрсетіледі, қайта көрсетілмейді. Кіруді екінші рет жасау мүмкін емес; осы пайдаланушы үшін құпиясөзді қалпына келтіру нұсқауын пайдаланыңыз.' },
      { title: 'Әрекет қолжетімсіз', body: 'Кіруді жасау сіздің компанияңыз үшін әлі қосылмаған. Ештеңе өзгерген жоқ; платформа операторына хабарласыңыз немесе құпиясөзді қалпына келтіру нұсқауын жіберіңіз.' },
      { title: 'Пайдаланушыға бас тартылды', body: 'Пайдаланушы белсенді емес немесе оның пошта мекенжайы жоқ. Мұны пайдаланушы бетінде түзетіп, қайталаңыз.' },
    ],
  },
  longLists: {
    title: 'Анықтама: ұзын тізімдер және «Алғашқылары көрсетілді» хабары',
    purpose: 'Жазбасы көп экрандар (негізгі құрал карточкалары, кодтар, позициялар, сақтау орындары, бөлімшелер, қойма құжаттары) оларды бөліп жүктейді. Тізім жүктелгеннен ұзын болса, хабар қанша жазба көрсетілгенін айтады.',
    tasks: [
      'Қажет жазба шыққанша тізім астындағы «Тағы жүктеу» түймесін басыңыз.',
      'Ұзын тізімді айналдырудың орнына оны сүзгілермен тарылтыңыз немесе іздеуге нөмірдің не атаудың көбірек әрпін енгізіңіз.',
      'Ашылмалы тізімде (позиция, орын, қызметкер) барлық жазба қолжетімді, әр түрден 10 000-ға дейін; хабар экранда тек тізім қысқартылғанда шығады.',
    ],
    refusals: [
      { title: '«Алғашқы ... көрсетілді» хабары', body: 'Тізім көрсетілгеннен ұзын. Ештеңе жоғалған жоқ: қалған жазбаларға «Тағы жүктеу», сүзгілер немесе іздеу арқылы жетуге болады.' },
      { title: 'Жазба ашылмалы тізімде жоқ', body: 'Ашылмалы тізімге әр түрден 10 000-ға дейін жазба сияды. Тізім ұзынырақ болса, экран хабарлайды және қалғандарын сол жерде таңдау мүмкін емес. Хабар жоқ болса, жазбаны көруге болатынын әкімшіден сұраңыз.' },
      { title: 'Іздеу күткеннен аз жазба табады', body: 'Сіз тек қолжетімді бөлімшелерді көресіз, ал іздеу тек алғашқы сәйкестіктерді көрсетеді. Нөмірдің немесе атаудың көбірек әрпін енгізіңіз.' },
    ],
  },
}

export const helpEn = flattenHelp('core', commonEn, en)
export const helpRu = flattenHelp('core', commonRu, ru)
export const helpKk = flattenHelp('core', commonKk, kk)

export const coreHelpMessages: Record<UiLocale, Record<string, string>> = { en: helpEn, ru: helpRu, kk: helpKk }
