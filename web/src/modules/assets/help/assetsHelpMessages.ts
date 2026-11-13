/** assetsHelpMessages — T-1560. Static help texts of the assets screens, en/ru/kk, flattened into catalogue ids
 *  `assets.help.<topic>.<part>`. Plain description only: no accounting or legal advice (the accountant confirms the
 *  money terms before pilot use). The ru and kk texts are written by the developer and need a native-speaker check. */
import { flattenHelp, type HelpCommonText, type HelpTopicText } from '@/components/help/helpTopicText'
import type { AssetsHelpTopic } from './assetsHelpTopics'

type Topics = Record<AssetsHelpTopic, HelpTopicText>

const commonEn: HelpCommonText = { link: 'Help', close: 'Close', back: 'Back to the screen', purpose: 'What this screen is for', tasks: 'Three common tasks', refusals: 'What a refusal means' }
const commonRu: HelpCommonText = { link: 'Справка', close: 'Закрыть', back: 'Назад к экрану', purpose: 'Для чего этот экран', tasks: 'Три частые задачи', refusals: 'Что значит отказ' }
const commonKk: HelpCommonText = { link: 'Анықтама', close: 'Жабу', back: 'Экранға оралу', purpose: 'Бұл экран не үшін', tasks: 'Үш жиі міндет', refusals: 'Бас тарту нені білдіреді' }

const en: Topics = {
  cards: {
    title: 'Help: asset cards',
    purpose: 'One card per asset: its inventory number, kind, org unit and acquisition facts. Cards are the list that documents refer to.',
    tasks: [
      'Press "New asset card", fill the inventory number, name and kind, and save.',
      'Pick a card in the list to see it, change its facts or its org unit, and save.',
      'Retire a card that is no longer used; turn on "Show retired" to see retired cards again.',
    ],
    refusals: [
      { title: 'The inventory number cannot be changed', body: 'After the first posted document the inventory number is fixed. Check the number before the first document is posted.' },
      { title: 'The kind cannot be changed', body: 'After the first posted document the kind is fixed. To change it, use a change of kind document on the Documents screen.' },
      { title: 'The card is retired and cannot be changed', body: 'A retired card is read-only. Create a new card if the asset is in use again.' },
    ],
  },
  documents: {
    title: 'Help: asset documents',
    purpose: 'Documents record what happens to an asset: commission, change of holder, hand over, change of kind and write off. A draft changes nothing until it is issued.',
    tasks: [
      'Choose a document kind, fill the header and the lines, and save the draft.',
      'Press "Issue" on a draft to post it to the register.',
      'Press "Reverse" on a posted document to undo it with a reversing entry.',
    ],
    refusals: [
      { title: 'Only a draft can be issued or discarded', body: 'A posted document is never edited. Reverse it, then create a new document with the correct data.' },
      { title: 'The document is already reversed', body: 'A document can be reversed once. If a reversal is still waiting, wait for it to finish.' },
      { title: 'A line refers to a retired card', body: 'Retired cards cannot be used in a line. Replace the card or create a new one.' },
    ],
  },
  balances: {
    title: 'Help: asset balances',
    purpose: 'The current state of the assets: who holds each one, where it is and its value as the register shows it. Information only; nothing is changed here.',
    tasks: [
      'Use the filters to find an asset by card, kind, org unit or holder.',
      'Pick a row to see the details of that balance.',
      'Remove a filter chip, or press "Clear filters", to see all balances again.',
    ],
    refusals: [
      { title: 'A balance you expect is missing', body: 'You see only the org units you have access to. Ask the administrator if you need another unit.' },
      { title: 'The data could not be loaded', body: 'Press "Retry". If it keeps failing, tell the administrator.' },
      { title: 'A number looks different from a document', body: 'Balances count only issued documents. A draft or a reversed document does not change them.' },
    ],
  },
  movements: {
    title: 'Help: asset movements',
    purpose: 'The journal of all posted changes to assets, one row per entry, newest first. It shows what happened and which document did it.',
    tasks: [
      'Use the filters to narrow the journal by asset, kind of document or period.',
      'Pick a row to see its details and the document behind it.',
      'Remove a filter chip, or press "Clear filters", to see the whole journal.',
    ],
    refusals: [
      { title: 'A movement you expect is missing', body: 'You see only the rows of org units you have access to. Ask the administrator if you need another unit.' },
      { title: 'A reversed document shows two rows', body: 'A reversal is a new entry that cancels the first one. Both stay in the journal.' },
      { title: 'The data could not be loaded', body: 'Press "Retry". If it keeps failing, tell the administrator.' },
    ],
  },
}

const ru: Topics = {
  cards: {
    title: 'Справка: карточки активов',
    purpose: 'Одна карточка на актив: инвентарный номер, вид, подразделение и данные о приобретении. На карточки ссылаются документы.',
    tasks: [
      'Нажмите «Новая карточка актива», заполните инвентарный номер, название и вид, сохраните.',
      'Выберите карточку в списке, чтобы увидеть её, измените данные или подразделение и сохраните.',
      'Выведите из использования ненужную карточку; включите «Показать выведенные», чтобы снова их увидеть.',
    ],
    refusals: [
      { title: 'Инвентарный номер нельзя изменить', body: 'После первого проведённого документа номер закреплён. Проверьте номер до проведения первого документа.' },
      { title: 'Вид нельзя изменить', body: 'После первого проведённого документа вид закреплён. Чтобы сменить его, используйте документ смены вида на экране «Документы».' },
      { title: 'Карточка выведена из использования и не меняется', body: 'Такая карточка доступна только для чтения. Если актив снова в работе, создайте новую карточку.' },
    ],
  },
  documents: {
    title: 'Справка: документы по активам',
    purpose: 'Документы фиксируют, что происходит с активом: ввод в эксплуатацию, смена держателя, передача, смена вида и списание. Черновик ничего не меняет, пока его не выпустят.',
    tasks: [
      'Выберите вид документа, заполните шапку и строки, сохраните черновик.',
      'Нажмите «Выпустить» на черновике, чтобы провести его в реестр.',
      'Нажмите «Сторнировать» на проведённом документе, чтобы отменить его сторно-записью.',
    ],
    refusals: [
      { title: 'Выпустить или удалить можно только черновик', body: 'Проведённый документ не редактируется. Сторнируйте его и создайте новый документ с верными данными.' },
      { title: 'Документ уже сторнирован', body: 'Документ сторнируется один раз. Если сторно ещё ожидает, дождитесь его завершения.' },
      { title: 'В строке указана выбывшая карточка', body: 'Выбывшие карточки нельзя использовать в строках. Замените карточку или создайте новую.' },
    ],
  },
  balances: {
    title: 'Справка: остатки активов',
    purpose: 'Текущее состояние активов: кто держатель, где актив и его стоимость по данным реестра. Только просмотр, здесь ничего не меняется.',
    tasks: [
      'Найдите актив фильтрами: по карточке, виду, подразделению или держателю.',
      'Выберите строку, чтобы увидеть подробности остатка.',
      'Уберите фильтр или нажмите «Сбросить фильтры», чтобы снова увидеть все остатки.',
    ],
    refusals: [
      { title: 'Нужного остатка нет в списке', body: 'Вы видите только подразделения, к которым у вас есть доступ. Если нужно другое, обратитесь к администратору.' },
      { title: 'Данные не удалось загрузить', body: 'Нажмите «Повторить». Если ошибка остаётся, сообщите администратору.' },
      { title: 'Число отличается от документа', body: 'Остатки учитывают только выпущенные документы. Черновик или сторнированный документ их не меняет.' },
    ],
  },
  movements: {
    title: 'Справка: движения активов',
    purpose: 'Журнал всех проведённых изменений по активам: одна строка на запись, новые сверху. Показывает, что произошло и каким документом.',
    tasks: [
      'Сузьте журнал фильтрами: по активу, виду документа или периоду.',
      'Выберите строку, чтобы увидеть подробности и документ-основание.',
      'Уберите фильтр или нажмите «Сбросить фильтры», чтобы увидеть весь журнал.',
    ],
    refusals: [
      { title: 'Нужного движения нет в журнале', body: 'Вы видите только строки подразделений, к которым у вас есть доступ. Если нужно другое, обратитесь к администратору.' },
      { title: 'У сторнированного документа две строки', body: 'Сторно — это новая запись, которая отменяет первую. Обе остаются в журнале.' },
      { title: 'Данные не удалось загрузить', body: 'Нажмите «Повторить». Если ошибка остаётся, сообщите администратору.' },
    ],
  },
}

const kk: Topics = {
  cards: {
    title: 'Анықтама: актив карточкалары',
    purpose: 'Әр активке бір карточка: инвентарлық нөмір, түр, бөлімше және сатып алу деректері. Құжаттар карточкаларға сілтейді.',
    tasks: [
      '«Жаңа актив карточкасы» батырмасын басып, инвентарлық нөмірді, атауды және түрді толтырып, сақтаңыз.',
      'Тізімнен карточканы таңдап, оны көріңіз, деректерін немесе бөлімшесін өзгертіп, сақтаңыз.',
      'Қолданылмайтын карточканы шығарыңыз; оларды қайта көру үшін «Шығарылғандарды көрсету» опциясын қосыңыз.',
    ],
    refusals: [
      { title: 'Инвентарлық нөмірді өзгертуге болмайды', body: 'Алғашқы өткізілген құжаттан кейін нөмір бекітіледі. Нөмірді бірінші құжат өткізілмей тұрып тексеріңіз.' },
      { title: 'Түрді өзгертуге болмайды', body: 'Алғашқы өткізілген құжаттан кейін түр бекітіледі. Оны ауыстыру үшін «Құжаттар» экранындағы түр ауыстыру құжатын пайдаланыңыз.' },
      { title: 'Карточка шығарылған, өзгертуге болмайды', body: 'Мұндай карточка тек оқуға арналған. Актив қайта қолданылса, жаңа карточка жасаңыз.' },
    ],
  },
  documents: {
    title: 'Анықтама: актив құжаттары',
    purpose: 'Құжаттар активке не болатынын тіркейді: пайдалануға беру, ұстаушыны ауыстыру, тапсыру, түрді ауыстыру және есептен шығару. Жоба шығарылғанша ештеңені өзгертпейді.',
    tasks: [
      'Құжат түрін таңдап, тақырыбы мен жолдарын толтырып, жобаны сақтаңыз.',
      'Жобаны тізілімге өткізу үшін «Шығару» батырмасын басыңыз.',
      'Өткізілген құжатты кері жазбамен болдырмау үшін «Сторнолау» батырмасын басыңыз.',
    ],
    refusals: [
      { title: 'Тек жобаны шығаруға немесе жоюға болады', body: 'Өткізілген құжат өңделмейді. Оны қайта жазып, дұрыс деректермен жаңа құжат жасаңыз.' },
      { title: 'Құжат әлдеқашан қайта жазылған', body: 'Құжатты бір рет қана қайта жазуға болады. Қайта жазу әлі күтіп тұрса, оның аяқталуын күтіңіз.' },
      { title: 'Жолда шығарылған карточка көрсетілген', body: 'Шығарылған карточкаларды жолдарда қолдануға болмайды. Карточканы ауыстырыңыз немесе жаңасын жасаңыз.' },
    ],
  },
  balances: {
    title: 'Анықтама: актив қалдықтары',
    purpose: 'Активтердің ағымдағы жағдайы: ұстаушы кім, актив қайда және тізілім бойынша құны. Тек қарау үшін, мұнда ештеңе өзгермейді.',
    tasks: [
      'Активті сүзгілермен табыңыз: карточка, түр, бөлімше немесе ұстаушы бойынша.',
      'Қалдықтың егжей-тегжейін көру үшін жолды таңдаңыз.',
      'Барлық қалдықты қайта көру үшін сүзгіні алыңыз немесе «Сүзгілерді тазалау» батырмасын басыңыз.',
    ],
    refusals: [
      { title: 'Күткен қалдық жоқ', body: 'Сіз тек қолжетімді бөлімшелерді көресіз. Басқасы керек болса, әкімшіге хабарласыңыз.' },
      { title: 'Деректерді жүктеу мүмкін болмады', body: '«Қайталау» батырмасын басыңыз. Қате қала берсе, әкімшіге хабарлаңыз.' },
      { title: 'Сан құжаттағыдан өзгеше', body: 'Қалдықтар тек шығарылған құжаттарды ескереді. Жоба немесе қайта жазылған құжат оларды өзгертпейді.' },
    ],
  },
  movements: {
    title: 'Анықтама: актив қозғалыстары',
    purpose: 'Активтер бойынша барлық өткізілген өзгерістер журналы: әр жазбаға бір жол, жаңалары жоғарыда. Не болғанын және қай құжатпен болғанын көрсетеді.',
    tasks: [
      'Журналды сүзгілермен тарылтыңыз: актив, құжат түрі немесе кезең бойынша.',
      'Егжей-тегжейін және негіздеме құжатын көру үшін жолды таңдаңыз.',
      'Бүкіл журналды көру үшін сүзгіні алыңыз немесе «Сүзгілерді тазалау» батырмасын басыңыз.',
    ],
    refusals: [
      { title: 'Күткен қозғалыс жоқ', body: 'Сіз тек қолжетімді бөлімшелердің жолдарын көресіз. Басқасы керек болса, әкімшіге хабарласыңыз.' },
      { title: 'Қайта жазылған құжатта екі жол бар', body: 'Қайта жазу — біріншісін болдырмайтын жаңа жазба. Екеуі де журналда қалады.' },
      { title: 'Деректерді жүктеу мүмкін болмады', body: '«Қайталау» батырмасын басыңыз. Қате қала берсе, әкімшіге хабарлаңыз.' },
    ],
  },
}

export const helpEn = flattenHelp('assets', commonEn, en)
export const helpRu = flattenHelp('assets', commonRu, ru)
export const helpKk = flattenHelp('assets', commonKk, kk)
