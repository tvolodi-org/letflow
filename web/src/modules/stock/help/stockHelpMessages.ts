/** stockHelpMessages — T-1560. Static help texts of the stock screens, en/ru/kk, flattened into catalogue ids
 *  `stock.help.<topic>.<part>`. Plain description only: no accounting or legal advice (the accountant confirms the
 *  money terms before pilot use). Stock is NOT frozen during a count (`counts.posting.noFreeze`); the counts help says
 *  so. The ru and kk texts are written by the developer and need a native-speaker check. */
import { flattenHelp, type HelpCommonText, type HelpTopicText } from '@/components/help/helpTopicText'
import type { StockHelpTopic } from './stockHelpTopics'

type Topics = Record<StockHelpTopic, HelpTopicText>

const commonEn: HelpCommonText = { link: 'Help', back: 'Back to the screen', purpose: 'What this screen is for', tasks: 'Three common tasks', refusals: 'What a refusal means' }
const commonRu: HelpCommonText = { link: 'Справка', back: 'Назад к экрану', purpose: 'Для чего этот экран', tasks: 'Три частые задачи', refusals: 'Что значит отказ' }
const commonKk: HelpCommonText = { link: 'Анықтама', back: 'Экранға оралу', purpose: 'Бұл экран не үшін', tasks: 'Үш жиі міндет', refusals: 'Бас тарту нені білдіреді' }

const en: Topics = {
  documents: {
    title: 'Help: stock documents',
    purpose: 'Stock documents (receipt, issue, write off, transfer, hand over, return, opening balance) are the only way stock changes. A draft changes nothing until it is issued and posted.',
    tasks: [
      'Press "New document", choose the kind, fill the header and the lines, and save the draft.',
      'Press "Issue" on a draft; the document is then posted to the stock register.',
      'Press "Reverse" on a posted document to undo it, then make a new document with the right data.',
    ],
    refusals: [
      { title: 'The document is posted', body: 'A posted document is not edited. Reverse it instead and create a new one.' },
      { title: 'Posting is still pending', body: 'The document is waiting for the posting task. Wait a moment; if it stays, press "Retry posting".' },
      { title: 'The event time is in the future, or an item needs a lot', body: 'Set the event time to now or earlier. For items that are tracked by lot, give the lot on the line.' },
    ],
  },
  balances: {
    title: 'Help: stock balances',
    purpose: 'How much of each item lies at each org unit, location, responsible employee and lot now. Information only; nothing is changed here.',
    tasks: [
      'Use the filters to find an item, org unit, location or lot.',
      'Pick "Show the history of this balance" on a row to see the movements behind it.',
      'Choose an earlier date to see the balances as they were then; export the table to Excel if needed.',
    ],
    refusals: [
      { title: 'A balance you expect is missing', body: 'You see only the org units you have access to. Ask the administrator if you need another unit.' },
      { title: 'This view is not available to you', body: 'Your access does not include this view. Ask the administrator.' },
      { title: 'The date cannot be in the future', body: 'Balances are shown as of today or an earlier date.' },
    ],
  },
  movements: {
    title: 'Help: stock movements',
    purpose: 'The journal of all posted stock changes, one row per entry. It shows what moved, where, when and with which document.',
    tasks: [
      'Narrow the journal with the filters: item, org unit, location, period.',
      'Pick a row to see its details and the document behind it.',
      'Remove a filter chip, or press "Clear filters", to see the whole journal.',
    ],
    refusals: [
      { title: 'A movement you expect is missing', body: 'You see only the movements of org units you may see. Ask the administrator if you need another unit.' },
      { title: 'A reversed document shows two rows', body: 'A reversal is a new entry that cancels the first one. Both stay in the journal.' },
      { title: 'This view is not available to you', body: 'Your access does not include this view. Ask the administrator.' },
    ],
  },
  counts: {
    title: 'Help: stock counts',
    purpose: 'A count compares the stock on the shelves with the books: order a count, enter the counted quantities on the sheet, and post the differences.',
    tasks: [
      'Press "New count", choose what to count, and save; then press "Issue".',
      'Press "Open for counting", enter the counted quantity on each line, and press "Close sheet".',
      'Mark the sheet and the differences sheet as signed, then post the count.',
    ],
    refusals: [
      { title: 'Stock is not blocked during a count', body: 'Stock movements during counting are not blocked. Each difference is posted as a change: counted minus book quantity at the cut-off.' },
      { title: 'A reversed count cannot be posted again', body: 'Order a new count instead.' },
      { title: 'A closed sheet cannot be edited', body: 'After "Close sheet" the quantities are fixed. A signed count cannot be cancelled: post it and reverse it, or order a new count.' },
    ],
  },
}

const ru: Topics = {
  documents: {
    title: 'Справка: складские документы',
    purpose: 'Складские документы (поступление, выдача, списание, перемещение, передача, возврат, начальный остаток) — единственный способ изменить остатки. Черновик ничего не меняет, пока его не выпустят и не проведут.',
    tasks: [
      'Нажмите «Новый документ», выберите вид, заполните шапку и строки, сохраните черновик.',
      'Нажмите «Выпустить» на черновике; документ будет проведён в складской регистр.',
      'Нажмите «Сторнировать» на проведённом документе, чтобы отменить его, и создайте новый с верными данными.',
    ],
    refusals: [
      { title: 'Документ проведён', body: 'Проведённый документ не редактируется. Сторнируйте его и создайте новый.' },
      { title: 'Проведение ещё не завершено', body: 'Документ ждёт задачу проведения. Подождите; если не меняется, нажмите «Повторить проведение».' },
      { title: 'Время события в будущем или нужна партия', body: 'Укажите время события не позже текущего. Для товаров с учётом по партиям укажите партию в строке.' },
    ],
  },
  balances: {
    title: 'Справка: складские остатки',
    purpose: 'Сколько каждого товара лежит сейчас в каждом подразделении, месте хранения, у ответственного и в каждой партии. Только просмотр, здесь ничего не меняется.',
    tasks: [
      'Найдите товар, подразделение, место или партию фильтрами.',
      'Выберите в строке «Показать историю остатка», чтобы увидеть движения за ним.',
      'Выберите более раннюю дату, чтобы увидеть остатки на тот день; при необходимости выгрузите таблицу в Excel.',
    ],
    refusals: [
      { title: 'Нужного остатка нет в списке', body: 'Вы видите только подразделения, к которым у вас есть доступ. Если нужно другое, обратитесь к администратору.' },
      { title: 'Этот просмотр вам недоступен', body: 'Ваши права не включают этот просмотр. Обратитесь к администратору.' },
      { title: 'Дата не может быть в будущем', body: 'Остатки показываются на сегодня или на более раннюю дату.' },
    ],
  },
  movements: {
    title: 'Справка: движения товара',
    purpose: 'Журнал всех проведённых изменений остатков: одна строка на запись. Показывает, что, куда, когда и каким документом двигалось.',
    tasks: [
      'Сузьте журнал фильтрами: товар, подразделение, место, период.',
      'Выберите строку, чтобы увидеть подробности и документ-основание.',
      'Уберите фильтр или нажмите «Сбросить фильтры», чтобы увидеть весь журнал.',
    ],
    refusals: [
      { title: 'Нужного движения нет в журнале', body: 'Вы видите только движения подразделений, которые вам доступны. Если нужно другое, обратитесь к администратору.' },
      { title: 'У сторнированного документа две строки', body: 'Сторно — это новая запись, которая отменяет первую. Обе остаются в журнале.' },
      { title: 'Этот просмотр вам недоступен', body: 'Ваши права не включают этот просмотр. Обратитесь к администратору.' },
    ],
  },
  counts: {
    title: 'Справка: инвентаризации',
    purpose: 'Инвентаризация сверяет товар на полках с учётом: назначьте её, введите фактические количества в ведомости и проведите расхождения.',
    tasks: [
      'Нажмите «Новая инвентаризация», выберите, что считать, сохраните; затем нажмите «Выпустить».',
      'Нажмите «Открыть для подсчёта», введите фактическое количество в каждой строке и нажмите «Закрыть ведомость».',
      'Отметьте ведомость и ведомость расхождений подписанными, затем проведите инвентаризацию.',
    ],
    refusals: [
      { title: 'Остатки во время подсчёта не блокируются', body: 'Движения товара во время подсчёта не блокируются. Каждое расхождение проводится как изменение: факт минус учёт на момент отсечки.' },
      { title: 'Сторнированную инвентаризацию нельзя провести повторно', body: 'Назначьте новую инвентаризацию.' },
      { title: 'Закрытую ведомость нельзя изменить', body: 'После «Закрыть ведомость» количества зафиксированы. Подписанную инвентаризацию нельзя отменить: проведите и сторнируйте её или назначьте новую.' },
    ],
  },
}

const kk: Topics = {
  documents: {
    title: 'Анықтама: қойма құжаттары',
    purpose: 'Қойма құжаттары (түсім, шығыс, есептен шығару, ауыстыру, тапсыру, қайтару, бастапқы қалдық) қалдықты өзгертудің жалғыз жолы. Жоба шығарылып, өткізілгенше ештеңені өзгертпейді.',
    tasks: [
      '«Жаңа құжат» батырмасын басып, түрін таңдап, тақырыбы мен жолдарын толтырып, жобаны сақтаңыз.',
      'Жобада «Шығару» батырмасын басыңыз; құжат қойма тізіліміне өткізіледі.',
      'Өткізілген құжатты болдырмау үшін «Қайта жазу» батырмасын басып, дұрыс деректермен жаңасын жасаңыз.',
    ],
    refusals: [
      { title: 'Құжат өткізілген', body: 'Өткізілген құжат өңделмейді. Оны сторнолап, жаңасын жасаңыз.' },
      { title: 'Өткізу әлі аяқталмаған', body: 'Құжат өткізу тапсырмасын күтіп тұр. Күте тұрыңыз; өзгермесе, «Өткізуді қайталау» батырмасын басыңыз.' },
      { title: 'Оқиға уақыты болашақта немесе партия керек', body: 'Оқиға уақытын қазіргіден кешірек етпеңіз. Партия бойынша есептелетін тауарларға жолда партияны көрсетіңіз.' },
    ],
  },
  balances: {
    title: 'Анықтама: қойма қалдықтары',
    purpose: 'Әр тауардың әр бөлімшеде, сақтау орнында, жауапты адамда және партияда қазір қанша екені. Тек қарау үшін, мұнда ештеңе өзгермейді.',
    tasks: [
      'Тауарды, бөлімшені, орынды немесе партияны сүзгілермен табыңыз.',
      'Қалдықтың артындағы қозғалыстарды көру үшін жолда «Қалдық тарихын көрсету» таңдаңыз.',
      'Сол күнгі қалдықты көру үшін ертерек күнді таңдаңыз; қажет болса, кестені Excel-ге жүктеңіз.',
    ],
    refusals: [
      { title: 'Күткен қалдық жоқ', body: 'Сіз тек қолжетімді бөлімшелерді көресіз. Басқасы керек болса, әкімшіге хабарласыңыз.' },
      { title: 'Бұл көрініс сізге қолжетімсіз', body: 'Сіздің құқықтарыңыз бұл көріністі қамтымайды. Әкімшіге хабарласыңыз.' },
      { title: 'Күн болашақта болмауы керек', body: 'Қалдықтар бүгінге немесе ертерек күнге көрсетіледі.' },
    ],
  },
  movements: {
    title: 'Анықтама: тауар қозғалыстары',
    purpose: 'Қалдықтардың барлық өткізілген өзгерістері журналы: әр жазбаға бір жол. Не, қайда, қашан және қай құжатпен қозғалғанын көрсетеді.',
    tasks: [
      'Журналды сүзгілермен тарылтыңыз: тауар, бөлімше, орын, кезең.',
      'Егжей-тегжейін және негіздеме құжатын көру үшін жолды таңдаңыз.',
      'Бүкіл журналды көру үшін сүзгіні алыңыз немесе «Сүзгілерді тазалау» батырмасын басыңыз.',
    ],
    refusals: [
      { title: 'Күткен қозғалыс жоқ', body: 'Сіз тек өзіңізге қолжетімді бөлімшелердің қозғалыстарын көресіз. Басқасы керек болса, әкімшіге хабарласыңыз.' },
      { title: 'Сторнолған құжатта екі жол бар', body: 'Сторно — біріншісін болдырмайтын жаңа жазба. Екеуі де журналда қалады.' },
      { title: 'Бұл көрініс сізге қолжетімсіз', body: 'Сіздің құқықтарыңыз бұл көріністі қамтымайды. Әкімшіге хабарласыңыз.' },
    ],
  },
  counts: {
    title: 'Анықтама: түгендеулер',
    purpose: 'Түгендеу сөредегі тауарды есеппен салыстырады: оны тағайындаңыз, тізімдемеге нақты мөлшерді енгізіңіз және айырмашылықтарды өткізіңіз.',
    tasks: [
      '«Жаңа түгендеу» батырмасын басып, нені санайтынын таңдап, сақтаңыз; содан кейін «Шығару» басыңыз.',
      '«Санауға ашу» батырмасын басып, әр жолға нақты мөлшерді енгізіп, «Тізімдемені жабу» басыңыз.',
      'Тізімдемені және айырмашылықтар тізімдемесін қол қойылған деп белгілеп, түгендеуді өткізіңіз.',
    ],
    refusals: [
      { title: 'Санау кезінде қалдық бұғатталмайды', body: 'Санау кезіндегі тауар қозғалыстары бұғатталмайды. Әр айырмашылық өзгеріс ретінде өткізіледі: үзу сәтіндегі нақты мөлшер минус есеп.' },
      { title: 'Сторнолған түгендеуді қайта өткізуге болмайды', body: 'Жаңа түгендеу тағайындаңыз.' },
      { title: 'Жабылған тізімдемені өзгертуге болмайды', body: '«Тізімдемені жабу» басылғаннан кейін мөлшерлер бекітіледі. Қол қойылған түгендеуден бас тартуға болмайды: оны өткізіп, сторнолаңыз немесе жаңасын тағайындаңыз.' },
    ],
  },
}

export const helpEn = flattenHelp('stock', commonEn, en)
export const helpRu = flattenHelp('stock', commonRu, ru)
export const helpKk = flattenHelp('stock', commonKk, kk)
