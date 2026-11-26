/** Plain-language messages for the validation and API error codes the process designer can receive (T-2813, D3).
 *  One table, en/ru/kk, so a code cannot miss a language. Ids: `processDiagram.edit.err.<code>`; `fallback` is
 *  used for any code not listed, and never shows a raw code or an HTTP status name. */
type Triple = readonly [en: string, ru: string, kk: string]

export const DESIGNER_ERROR_MESSAGES: Record<string, Triple> = {
  // Notify step
  notify_malformed: ['The notification step is not filled in correctly. Open the step and check its fields.', 'Шаг уведомления заполнен неверно. Откройте шаг и проверьте поля.', 'Хабарлама қадамы дұрыс толтырылмаған. Қадамды ашып, өрістерді тексеріңіз.'],
  notify_channel_unknown: ['This notification channel does not exist. Pick a channel from the list.', 'Такого канала уведомлений нет. Выберите канал из списка.', 'Мұндай хабарлама арнасы жоқ. Тізімнен арнаны таңдаңыз.'],
  notify_conflicting_route: ['This step is set up as a notification and as another kind of call at once. Keep only one.', 'Шаг настроен и как уведомление, и как другой вызов. Оставьте что-то одно.', 'Қадам бір мезгілде хабарлама және басқа шақыру ретінде бапталған. Біреуін ғана қалдырыңыз.'],
  notify_file_name_invalid: ['The attached file name is not valid. Use a plain file name.', 'Недопустимое имя вложенного файла. Укажите простое имя файла.', 'Тіркелген файл атауы жарамсыз. Қарапайым файл атауын жазыңыз.'],
  notify_file_name_not_allowed: ['This file name is not allowed for attachments. Choose another file.', 'Это имя файла нельзя использовать во вложении. Выберите другой файл.', 'Бұл файл атауын тіркемеде қолдануға болмайды. Басқа файлды таңдаңыз.'],
  notify_input_source_refused: ['A value for this notification cannot be taken from that source. Pick another source.', 'Значение для уведомления нельзя взять из этого источника. Выберите другой источник.', 'Хабарлама мәнін бұл көзден алуға болмайды. Басқа көзді таңдаңыз.'],
  notify_node_type_not_supported: ['Notifications can only be set up on a notification step. Change the step type.', 'Уведомление можно настроить только на шаге-уведомлении. Смените тип шага.', 'Хабарламаны тек хабарлама қадамында бапталуға болады. Қадам түрін ауыстырыңыз.'],
  notify_recipient_invalid: ['The recipient is not valid. Check the address or the person.', 'Получатель указан неверно. Проверьте адрес или сотрудника.', 'Алушы дұрыс емес. Мекенжайды немесе қызметкерді тексеріңіз.'],
  notify_recipient_not_allowed: ['You cannot send to this recipient. Choose someone from your company.', 'Нельзя отправлять этому получателю. Выберите сотрудника вашей компании.', 'Бұл алушыға жіберуге болмайды. Компания қызметкерін таңдаңыз.'],
  notify_template_unknown: ['The notification template does not exist. Pick a template from the list.', 'Шаблона уведомления нет. Выберите шаблон из списка.', 'Хабарлама үлгісі жоқ. Тізімнен үлгіні таңдаңыз.'],
  notify_unknown_key: ['The step has a setting the notification does not know. Remove it.', 'В шаге есть настройка, которой нет у уведомления. Удалите её.', 'Қадамда хабарлама білмейтін параметр бар. Оны алып тастаңыз.'],
  notify_value_missing: ['A required value of the notification is empty. Fill it in.', 'Не заполнено обязательное значение уведомления. Заполните его.', 'Хабарламаның міндетті мәні толтырылмаған. Оны толтырыңыз.'],
  notify_value_source_invalid: ['A value of the notification has an unusable source. Pick the source again.', 'У значения уведомления неверный источник. Выберите источник заново.', 'Хабарлама мәнінің көзі жарамсыз. Көзді қайта таңдаңыз.'],
  notify_value_unknown: ['The notification uses a value its template does not have. Remove it.', 'Уведомление использует значение, которого нет в шаблоне. Удалите его.', 'Хабарлама үлгіде жоқ мәнді қолданады. Оны алып тастаңыз.'],
  // Platform call step
  platform_call_malformed: ['The platform call step is not filled in correctly. Open the step and check its fields.', 'Шаг вызова платформы заполнен неверно. Откройте шаг и проверьте поля.', 'Платформа шақыру қадамы дұрыс толтырылмаған. Қадамды ашып, өрістерді тексеріңіз.'],
  platform_call_activator_required: ['Only a platform administrator can activate this process. Ask one to do it.', 'Активировать этот процесс может только администратор платформы. Попросите его об этом.', 'Бұл процесті тек платформа әкімшісі іске қоса алады. Одан сұраңыз.'],
  platform_call_arg_missing: ['A required input of the function is empty. Fill it in.', 'Не заполнен обязательный параметр функции. Заполните его.', 'Функцияның міндетті параметрі толтырылмаған. Оны толтырыңыз.'],
  platform_call_arg_source_invalid: ['An input of the function has an unusable source. Pick the source again.', 'У параметра функции неверный источник. Выберите источник заново.', 'Функция параметрінің көзі жарамсыз. Көзді қайта таңдаңыз.'],
  platform_call_arg_sys_reference: ['An input refers to an internal system value that is not available here. Use a process variable.', 'Параметр ссылается на внутреннее системное значение, которое здесь недоступно. Используйте переменную процесса.', 'Параметр мұнда қолжетімсіз ішкі жүйелік мәнге сілтейді. Процесс айнымалысын қолданыңыз.'],
  platform_call_arg_unknown: ['The step passes an input the function does not have. Remove it.', 'Шаг передаёт параметр, которого нет у функции. Удалите его.', 'Қадам функцияда жоқ параметрді береді. Оны алып тастаңыз.'],
  platform_call_foreign_source_refused: ['An input is taken from another record this step may not use. Pick another source.', 'Параметр взят из чужой записи, которую этот шаг использовать не может. Выберите другой источник.', 'Параметр бұл қадам қолдана алмайтын бөтен жазбадан алынған. Басқа көзді таңдаңыз.'],
  platform_call_function_unknown: ['The chosen function does not exist. Pick a function from the list.', 'Выбранной функции нет. Выберите функцию из списка.', 'Таңдалған функция жоқ. Тізімнен функцияны таңдаңыз.'],
  platform_call_input_source_refused: ['An input cannot be taken from that source. Pick another source.', 'Параметр нельзя взять из этого источника. Выберите другой источник.', 'Параметрді бұл көзден алуға болмайды. Басқа көзді таңдаңыз.'],
  platform_call_node_missing: ['The step refers to a platform call that is not set up. Open the step and choose a function.', 'Шаг ссылается на вызов платформы, который не настроен. Откройте шаг и выберите функцию.', 'Қадам бапталмаған платформа шақыруына сілтейді. Қадамды ашып, функцияны таңдаңыз.'],
  platform_call_node_not_declared: ['This step is not declared as a platform call. Change the step type.', 'Этот шаг не объявлен как вызов платформы. Смените тип шага.', 'Бұл қадам платформа шақыруы ретінде жарияланбаған. Қадам түрін ауыстырыңыз.'],
  platform_call_node_type_not_supported: ['A platform call can only be set up on a service step. Change the step type.', 'Вызов платформы можно настроить только на служебном шаге. Смените тип шага.', 'Платформа шақыруын тек қызметтік қадамда бапталуға болады. Қадам түрін ауыстырыңыз.'],
  platform_call_not_allowed: ['This function is not allowed in your company. Pick another one.', 'Эта функция не разрешена в вашей компании. Выберите другую.', 'Бұл функцияға сіздің компанияңызда рұқсат жоқ. Басқасын таңдаңыз.'],
  platform_call_permission_required: ['You do not have the right to use this function. Ask an administrator.', 'У вас нет права использовать эту функцию. Обратитесь к администратору.', 'Бұл функцияны қолдануға құқығыңыз жоқ. Әкімшіге хабарласыңыз.'],
  platform_call_unknown_key: ['The step has a setting the platform call does not know. Remove it.', 'В шаге есть настройка, которой нет у вызова платформы. Удалите её.', 'Қадамда платформа шақыруы білмейтін параметр бар. Оны алып тастаңыз.'],
  // HTTP-level answers
  http_409: ['The definition was changed or is no longer a draft. Reload it and try again.', 'Определение было изменено или уже не черновик. Перезагрузите его и повторите.', 'Анықтама өзгерген немесе енді жоба емес. Қайта жүктеп, қайталап көріңіз.'],
  conflict_module_owned: ['This process belongs to a module and cannot be edited here.', 'Этот процесс принадлежит модулю и не редактируется здесь.', 'Бұл процесс модульге тиесілі және мұнда өзгертілмейді.'],
  conflict_duplicate: ['A process with this name and version already exists. Change the version and try again.', 'Процесс с таким именем и версией уже есть. Измените версию и повторите.', 'Мұндай атау мен нұсқасы бар процесс бұрыннан бар. Нұсқаны өзгертіп, қайталаңыз.'],
  http_422: ['Some fields of the process are not valid. Fix the marked steps and try again.', 'Некоторые поля процесса заполнены неверно. Исправьте отмеченные шаги и повторите.', 'Процестің кейбір өрістері дұрыс емес. Белгіленген қадамдарды түзетіп, қайталаңыз.'],
  fallback: ['Something went wrong. Check the process and try again; if it repeats, contact your administrator.', 'Что-то пошло не так. Проверьте процесс и повторите; если не помогает, обратитесь к администратору.', 'Бір нәрсе дұрыс болмады. Процесті тексеріп, қайталаңыз; қайталанса, әкімшіге хабарласыңыз.'],
  details: ['Details', 'Подробности', 'Мәліметтер'],
}

export const DESIGNER_ERROR_PREFIX = 'processDiagram.edit.err.'

/** Message key (without prefix) for a code and status: a known code, else the status class, else the fallback. */
export function designerErrorKey(code: string | undefined, status?: number): string {
  if (code && Object.prototype.hasOwnProperty.call(DESIGNER_ERROR_MESSAGES, code) && code !== 'fallback' && code !== 'details') return code
  if (status === 409) return 'http_409'
  if (status === 422) return 'http_422'
  return 'fallback'
}
