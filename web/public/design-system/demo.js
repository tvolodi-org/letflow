/* Demo helper for the static style guide and example pages. Not part of the design system API.
   - injects the Lucide icon sprite (stroke icons, used as <svg class="lf-icon"><use href="#i-name"/></svg>)
   - ?theme=dark|light sets data-theme on <html>; ?lang=ru|kk swaps [data-t] texts from window.LF_STRINGS
   - tree toggles, language menu links, theme button */
(function () {
  var I = {
    'chevron-right': '<path d="m9 18 6-6-6-6"/>',
    'back': '<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>',
    'chevron-down': '<path d="m6 9 6 6 6-6"/>',
    'chevron-left': '<path d="m15 18-6-6 6-6"/>',
    'search': '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
    'plus': '<path d="M5 12h14"/><path d="M12 5v14"/>',
    'x': '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    'check': '<path d="M20 6 9 17l-5-5"/>',
    'upload': '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m17 8-5-5-5 5"/><path d="M12 3v12"/>',
    'download': '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
    'alert': '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    'info': '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
    'check-circle': '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
    'building': '<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/><path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/><path d="M10 18h4"/>',
    'map-pin': '<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>',
    'users': '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    'briefcase': '<rect width="20" height="14" x="2" y="7" rx="2"/><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>',
    'network': '<rect x="16" y="16" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="9" y="2" width="6" height="6" rx="1"/><path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/><path d="M12 12V8"/>',
    'barcode': '<path d="M3 5v14"/><path d="M8 5v14"/><path d="M12 5v14"/><path d="M17 5v14"/><path d="M21 5v14"/>',
    'package': '<path d="m7.5 4.27 9 5.15"/><path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>',
    'link': '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    'sheet': '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M8 13h2"/><path d="M14 13h2"/><path d="M8 17h2"/><path d="M14 17h2"/>',
    'globe': '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
    'menu': '<path d="M4 12h16"/><path d="M4 6h16"/><path d="M4 18h16"/>',
    'more': '<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>',
    'sort': '<path d="m21 16-4 4-4-4"/><path d="M17 20V4"/><path d="m3 8 4-4 4 4"/><path d="M7 4v16"/>',
    'arrow-up': '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
    'arrow-down': '<path d="M12 5v14"/><path d="m19 12-7 7-7-7"/>',
    'moon': '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
    'history': '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
    'move': '<path d="m15 10 5 5-5 5"/><path d="M4 4v7a4 4 0 0 0 4 4h12"/>',
    'pencil': '<path d="M21.17 6.81a1 1 0 0 0-3.99-3.99L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5z"/><path d="m15 5 4 4"/>',
    'archive': '<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
    'tag': '<path d="M12.59 2.59A2 2 0 0 0 11.17 2H4a2 2 0 0 0-2 2v7.17a2 2 0 0 0 .59 1.42l8.7 8.7a2.43 2.43 0 0 0 3.42 0l6.58-6.58a2.43 2.43 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r="1.2"/>',
    'radio': '<path d="M4.9 19.1C1 15.2 1 8.8 4.9 4.9"/><path d="M7.8 16.2c-2.3-2.3-2.3-6.1 0-8.5"/><circle cx="12" cy="12" r="2"/><path d="M16.2 7.8c2.3 2.3 2.3 6.1 0 8.5"/><path d="M19.1 4.9C23 8.8 23 15.1 19.1 19"/>',
    'grid': '<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/>',
    'inbox': '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    'ruler': '<path d="M21.3 15.3a2.4 2.4 0 0 1 0 3.4l-2.6 2.6a2.4 2.4 0 0 1-3.4 0L2.7 8.7a2.41 2.41 0 0 1 0-3.4l2.6-2.6a2.41 2.41 0 0 1 3.4 0Z"/><path d="m14.5 12.5 2-2"/><path d="m11.5 9.5 2-2"/><path d="m8.5 6.5 2-2"/><path d="m17.5 15.5 2-2"/>',
    'handshake': '<path d="m11 17 2 2a1 1 0 1 0 3-3"/><path d="m14 14 2.5 2.5a1 1 0 1 0 3-3l-3.88-3.88a3 3 0 0 0-4.24 0l-.88.88a1 1 0 1 1-3-3l2.81-2.81a5.79 5.79 0 0 1 7.06-.87l.47.28a2 2 0 0 0 1.42.25L21 4"/><path d="m21 3 1 11h-2"/><path d="M3 3 2 14l6.5 6.5a1 1 0 1 0 3-3"/><path d="M3 4h8"/>',
    'layers': '<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/><path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/><path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>',
    'calendar': '<path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/>',
    'clock': '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
    'chevrons-left': '<path d="m11 17-5-5 5-5"/><path d="m18 17-5-5 5-5"/>',
    'chevrons-right': '<path d="m6 17 5-5-5-5"/><path d="m13 17 5-5-5-5"/>',
    'log-out': '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>'
  };
  var sprite = '<svg xmlns="http://www.w3.org/2000/svg" style="display:none">';
  for (var k in I) sprite += '<symbol id="i-' + k + '" viewBox="0 0 24 24">' + I[k] + '</symbol>';
  sprite += '</svg>';
  document.body.insertAdjacentHTML('afterbegin', sprite);

  var q = new URLSearchParams(location.search);
  var theme = q.get('theme');
  if (theme === 'dark' || theme === 'light') document.documentElement.setAttribute('data-theme', theme);
  var lang = q.get('lang');
  var S = window.LF_STRINGS || {};
  var N = window.LF_NAV || {};
  Object.keys(N).forEach(function (l) { S[l] = Object.assign({}, N[l], S[l] || {}); });
  if (lang && S[lang]) {
    document.documentElement.lang = lang;
    document.querySelectorAll('[data-t]').forEach(function (el) {
      var v = S[lang][el.getAttribute('data-t')];
      if (v != null) el.textContent = v;
    });
    document.querySelectorAll('[data-t-label]').forEach(function (el) {
      var v = S[lang][el.getAttribute('data-t-label')];
      if (v != null) el.setAttribute('data-label', v);
    });
    document.querySelectorAll('[data-t-ph]').forEach(function (el) {
      var v = S[lang][el.getAttribute('data-t-ph')];
      if (v != null) el.setAttribute('placeholder', v);
    });
  }
  document.querySelectorAll('.lf-lang__cur').forEach(function (el) { el.textContent = (lang || 'en').toUpperCase(); });
  document.querySelectorAll('[data-lang-link]').forEach(function (a) {
    var l = a.getAttribute('data-lang-link');
    var p = new URLSearchParams(location.search); p.set('lang', l);
    a.href = '?' + p.toString();
    if ((lang || 'en') === l) a.setAttribute('aria-current', 'true');
  });
  document.querySelectorAll('[data-theme-toggle]').forEach(function (b) {
    b.addEventListener('click', function () {
      var cur = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', cur);
      try { localStorage.setItem('lf-theme', cur); } catch (e) { /* storage blocked: theme lasts for this page only */ }
    });
  });
  document.querySelectorAll('.lf-tree__toggle').forEach(function (b) {
    b.addEventListener('click', function (e) {
      e.stopPropagation();
      var item = b.closest('[role="treeitem"]');
      item.setAttribute('aria-expanded', item.getAttribute('aria-expanded') === 'true' ? 'false' : 'true');
    });
  });
  document.querySelectorAll('[data-open]').forEach(function (b) {
    b.addEventListener('click', function () { document.getElementById(b.getAttribute('data-open')).hidden = false; });
  });
  document.querySelectorAll('[data-close]').forEach(function (b) {
    b.addEventListener('click', function () { b.closest('.lf-scrim').hidden = true; });
  });
  var openId = q.get('open');
  if (openId && document.getElementById(openId)) document.getElementById(openId).hidden = false;
  if (q.get('nav') === 'open') document.querySelector('.lf-app').classList.add('is-nav-open');
  var menuBtn = document.querySelector('.lf-topbar__menu');
  if (menuBtn) menuBtn.addEventListener('click', function () { document.querySelector('.lf-app').classList.toggle('is-nav-open'); });
})();

/* LFDT:begin ------------------------------------------------------------------------------------------------
   Date and time components: lf-date (calendar popup), lf-time (24-hour input + 15-minute list), lf-datetime (both).
   Vanilla, no dependencies, one global `LFDT`. This is the reference behaviour for the React components (NOTES.md,
   "Date and time"): port the DOM structure, the ARIA attributes and the keyboard rules, not this code.
   Value model: date = 'YYYY-MM-DD', time = 'HH:mm' (24 h), datetime = { date, time }. Both are plain strings with
   no time zone. The product combines them into one instant in the tenant time zone (LFDT.combine only joins the text).
   Texts: en is the source; ru, kk, uz are MACHINE DRAFTS and need a native-speaker check before the product uses them.
   Typed formats: ru kk uz DD-MM-YYYY (placeholder letters per language); en YYYY-MM-DD (ISO), shown as "Nov 5, 2026"
   in read-only views (LFDT.display). Weeks start on Monday. */
var LFDT = (function () {
  'use strict';

  var L = {
    en: {
      order: 'YMD', fmt: 'YYYY-MM-DD', tfmt: 'HH:mm',
      months: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
      monthsGen: null, short: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
      wd: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'], wdFull: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
      chooseDate: 'Choose date', chooseTime: 'Choose time', prevM: 'Previous month', nextM: 'Next month', prevY: 'Previous year', nextY: 'Next year',
      today: 'Today', clear: 'Clear', close: 'Close', date: 'date', time: 'time', sel: 'selected', tod: 'today', off: 'not available',
      eFormat: 'enter a date as {fmt}', eNone: 'the date does not exist', eMin: 'must be on or after {d}', eMax: 'must be on or before {d}',
      tFormat: 'enter a time as {fmt}', tRange: 'hours are 00 to 23, minutes are 00 to 59',
      tz: 'Time in the tenant time zone ({tz})', optional: '(optional)'
    },
    ru: { /* machine draft */
      order: 'DMY', fmt: 'ДД-ММ-ГГГГ', tfmt: 'ЧЧ:мм',
      months: ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'],
      monthsGen: ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'],
      short: ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'],
      wd: ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'], wdFull: ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'],
      chooseDate: 'Выбрать дату', chooseTime: 'Выбрать время', prevM: 'Предыдущий месяц', nextM: 'Следующий месяц', prevY: 'Предыдущий год', nextY: 'Следующий год',
      today: 'Сегодня', clear: 'Очистить', close: 'Закрыть', date: 'дата', time: 'время', sel: 'выбрано', tod: 'сегодня', off: 'недоступно',
      eFormat: 'введите дату в формате {fmt}', eNone: 'такой даты не существует', eMin: 'не раньше {d}', eMax: 'не позже {d}',
      tFormat: 'введите время в формате {fmt}', tRange: 'часы от 00 до 23, минуты от 00 до 59',
      tz: 'Время в часовом поясе организации ({tz})', optional: '(необязательно)'
    },
    kk: { /* machine draft */
      order: 'DMY', fmt: 'КК-АА-ЖЖЖЖ', tfmt: 'СС:мм',
      months: ['қаңтар', 'ақпан', 'наурыз', 'сәуір', 'мамыр', 'маусым', 'шілде', 'тамыз', 'қыркүйек', 'қазан', 'қараша', 'желтоқсан'],
      monthsGen: null, short: ['қаң', 'ақп', 'нау', 'сәу', 'мам', 'мау', 'шіл', 'там', 'қыр', 'қаз', 'қар', 'жел'],
      wd: ['Дс', 'Сс', 'Ср', 'Бс', 'Жм', 'Сб', 'Жс'], wdFull: ['дүйсенбі', 'сейсенбі', 'сәрсенбі', 'бейсенбі', 'жұма', 'сенбі', 'жексенбі'],
      chooseDate: 'Күнді таңдау', chooseTime: 'Уақытты таңдау', prevM: 'Алдыңғы ай', nextM: 'Келесі ай', prevY: 'Алдыңғы жыл', nextY: 'Келесі жыл',
      today: 'Бүгін', clear: 'Тазалау', close: 'Жабу', date: 'күні', time: 'уақыты', sel: 'таңдалған', tod: 'бүгін', off: 'қолжетімсіз',
      eFormat: 'күнді {fmt} пішімінде енгізіңіз', eNone: 'мұндай күн жоқ', eMin: '{d} күнінен бұрын болмауы керек', eMax: '{d} күнінен кеш болмауы керек',
      tFormat: 'уақытты {fmt} пішімінде енгізіңіз', tRange: 'сағат 00-ден 23-ке дейін, минут 00-ден 59-ға дейін',
      tz: 'Уақыт ұйымның уақыт белдеуінде ({tz})', optional: '(міндетті емес)'
    },
    uz: { /* machine draft */
      order: 'DMY', fmt: 'KK-OO-YYYY', tfmt: 'SS:DD',
      months: ['yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun', 'iyul', 'avgust', 'sentabr', 'oktabr', 'noyabr', 'dekabr'],
      monthsGen: null, short: ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'],
      wd: ['Du', 'Se', 'Ch', 'Pa', 'Ju', 'Sh', 'Ya'], wdFull: ['dushanba', 'seshanba', 'chorshanba', 'payshanba', 'juma', 'shanba', 'yakshanba'],
      chooseDate: 'Sanani tanlash', chooseTime: 'Vaqtni tanlash', prevM: 'Oldingi oy', nextM: 'Keyingi oy', prevY: 'Oldingi yil', nextY: 'Keyingi yil',
      today: 'Bugun', clear: 'Tozalash', close: 'Yopish', date: 'sana', time: 'vaqt', sel: 'tanlangan', tod: 'bugun', off: 'mavjud emas',
      eFormat: 'sanani {fmt} shaklida kiriting', eNone: 'bunday sana mavjud emas', eMin: '{d} dan oldin bo‘lmasligi kerak', eMax: '{d} dan keyin bo‘lmasligi kerak',
      tFormat: 'vaqtni {fmt} shaklida kiriting', tRange: 'soat 00 dan 23 gacha, daqiqa 00 dan 59 gacha',
      tz: 'Vaqt tashkilotning vaqt mintaqasida ({tz})', optional: '(ixtiyoriy)'
    }
  };
  function lg(l) { return L[l] || L.en; }
  function docLang() { try { var l = (document.documentElement.lang || 'en').slice(0, 2); return L[l] ? l : 'en'; } catch (e) { return 'en'; } }

  /* ---------- pure date helpers (ISO strings, UTC arithmetic: no local time zone enters) ---------- */
  function p2(n) { return (n < 10 ? '0' : '') + n; }
  function p4(n) { return ('000' + n).slice(-4); }
  function dim(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate(); } // m is 1..12
  function mk(y, m, d) { return p4(y) + '-' + p2(m) + '-' + p2(d); }
  function split(s) { var r = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || ''); return r ? { y: +r[1], m: +r[2], d: +r[3] } : null; }
  function isDate(s) { var p = split(s); return !!p && p.y >= 1000 && p.m >= 1 && p.m <= 12 && p.d >= 1 && p.d <= dim(p.y, p.m); }
  function addDays(s, n) { var p = split(s), t = new Date(Date.UTC(p.y, p.m - 1, p.d + n)); return mk(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()); }
  function addMonths(s, n) { var p = split(s), i = p.y * 12 + (p.m - 1) + n, y = Math.floor(i / 12), m = i - y * 12 + 1; return mk(y, m, Math.min(p.d, dim(y, m))); }
  function weekday(s) { var p = split(s); return (new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay() + 6) % 7; } // 0 = Monday
  function monthGrid(y, m) { // 6 weeks x 7 days from the Monday on or before the 1st; m is 1..12
    var first = mk(y, m, 1), start = addDays(first, -weekday(first)), out = [];
    for (var i = 0; i < 42; i++) out.push(addDays(start, i));
    return out;
  }
  function clamp(s, min, max) { if (min && s < min) return min; if (max && s > max) return max; return s; }
  function todayLocal() { var t = new Date(); return mk(t.getFullYear(), t.getMonth() + 1, t.getDate()); }

  /* typed text <-> ISO */
  function fmtDate(s, lang) {
    var p = split(s); if (!p) return '';
    return lg(lang).order === 'DMY' ? p2(p.d) + '-' + p2(p.m) + '-' + p4(p.y) : p4(p.y) + '-' + p2(p.m) + '-' + p2(p.d);
  }
  function parseDate(text, lang) { // -> {ok:true, iso} | {ok:false, code:'empty'|'format'|'nonexistent'}
    var s = String(text == null ? '' : text).trim();
    if (!s) return { ok: false, code: 'empty' };
    var a, b, c, m = /^(\d{1,4})[-.\/ ](\d{1,2})[-.\/ ](\d{1,4})$/.exec(s);
    if (m) { a = m[1]; b = m[2]; c = m[3]; }
    else if ((m = /^(\d{8})$/.exec(s))) { // digits only: cut by the order of the language
      if (lg(lang).order === 'DMY') { a = s.slice(0, 2); b = s.slice(2, 4); c = s.slice(4); } else { a = s.slice(0, 4); b = s.slice(4, 6); c = s.slice(6); }
    } else return { ok: false, code: 'format' };
    var y, mo, d;
    if (a.length === 4) { y = a; mo = b; d = c; } // year first is never ambiguous, any language
    else if (lg(lang).order === 'DMY') { d = a; mo = b; y = c; }
    else return { ok: false, code: 'format' }; // en: no silent MM/DD or DD/MM reading
    if (y.length !== 4 || d.length > 2 || mo.length > 2) return { ok: false, code: 'format' };
    y = +y; mo = +mo; d = +d;
    if (y < 1000 || mo < 1 || mo > 12 || d < 1 || d > dim(y, mo)) return { ok: false, code: 'nonexistent' };
    return { ok: true, iso: mk(y, mo, d) };
  }
  /* mask: keep digits, insert separators, pad a one-digit day or month when a separator is typed or the first digit
     cannot start a valid number (4 -> 04). `deleting` stops a trailing separator from coming back while backspacing. */
  function maskDate(raw, lang, deleting) {
    var kinds = lg(lang).order === 'DMY' ? ['d', 'm', 'y'] : ['y', 'm', 'd'], size = { d: 2, m: 2, y: 4 }, lim = { d: 3, m: 1 };
    var groups = [], cur = '', i, c, k;
    raw = String(raw == null ? '' : raw);
    var pasted = /^(\d{4})[-.\/ ](\d{1,2})[-.\/ ](\d{1,2})$/.exec(raw); // an ISO date pasted into a day-first field
    if (pasted && kinds[0] === 'd') raw = p2(+pasted[3]) + '-' + p2(+pasted[2]) + '-' + pasted[1];
    for (i = 0; i < raw.length; i++) {
      c = raw.charAt(i);
      if (/\d/.test(c)) {
        k = kinds[groups.length];
        if (cur.length === size[k]) { groups.push(cur); cur = ''; k = kinds[groups.length]; }
        if (groups.length >= 3) break;
        if (cur === '' && !deleting && lim[k] != null && +c > lim[k]) { cur = '0' + c; if (groups.length < 2) { groups.push(cur); cur = ''; } continue; }
        cur += c;
      } else if (cur !== '' && groups.length < 2) {
        if (size[kinds[groups.length]] === 2 && cur.length === 1) cur = '0' + cur;
        groups.push(cur); cur = '';
      }
    }
    var parts = cur !== '' ? groups.concat([cur]) : groups, out = parts.join('-');
    if (!deleting && groups.length < 3) {
      if (cur === '' && groups.length > 0) out += '-';
      else if (cur.length === size[kinds[groups.length]] && groups.length < 2) out += '-';
    }
    return out;
  }

  /* ---------- pure time helpers ---------- */
  function fmtTime(min) { return p2(Math.floor(min / 60)) + ':' + p2(min % 60); }
  function parseTime(text) { // -> {ok:true, time, min} | {ok:false, code:'empty'|'format'|'range'}
    var s = String(text == null ? '' : text).trim();
    if (!s) return { ok: false, code: 'empty' };
    var m = /^(\d{1,2})[:.hH ](\d{2})$/.exec(s), h, mi;
    if (m) { h = +m[1]; mi = +m[2]; }
    else if ((m = /^(\d{1,2})(\d{2})$/.exec(s)) && s.length >= 3) { h = +m[1]; mi = +m[2]; }
    else return { ok: false, code: 'format' };
    if (h > 23 || mi > 59) return { ok: false, code: 'range' };
    return { ok: true, time: p2(h) + ':' + p2(mi), min: h * 60 + mi };
  }
  function maskTime(raw, deleting) {
    var h = '', mi = '', sep = false, i, c;
    raw = String(raw == null ? '' : raw);
    for (i = 0; i < raw.length; i++) {
      c = raw.charAt(i);
      if (/\d/.test(c)) {
        if (h.length < 2 && !sep) {
          if (h === '' && !deleting && +c > 2) { h = '0' + c; sep = true; } else h += c;
          if (h.length === 2) sep = true;
        } else if (mi.length < 2) mi += c;
        else break;
      } else if (h.length === 1) { h = '0' + h; sep = true; }
      else if (h.length === 2) sep = true;
    }
    return h + (h.length === 2 && sep && (mi !== '' || !deleting) ? ':' + mi : '');
  }
  function stepTime(curMin, delta, nowMin) { // clamps at 00:00 and 23:59; empty field starts from the current time
    if (curMin == null) return Math.max(0, Math.min(1439, nowMin == null ? 0 : nowMin));
    return Math.max(0, Math.min(1439, curMin + delta));
  }
  function combine(date, time) { return date && time ? date + 'T' + time : ''; }
  function display(iso, lang, time) { // read-only text: en "Nov 5, 2026 09:30", ru kk uz "05-11-2026 09:30"
    var p = split(iso); if (!p) return '';
    var d = lg(lang).order === 'DMY' ? fmtDate(iso, lang) : lg(lang).short[p.m - 1] + ' ' + p.d + ', ' + p.y;
    return d + (time ? ' ' + time : '');
  }

  /* ---------- DOM helpers (not used by the pure functions above) ---------- */
  var seq = 0;
  function uid(p) { seq += 1; return p + '-' + seq; }
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function ico(n) { return '<svg class="lf-icon" aria-hidden="true"><use href="#i-' + n + '"/></svg>'; }
  function tpl(s, o) { return String(s).replace(/\{(\w+)\}/g, function (_, k) { return o[k] != null ? o[k] : ''; }); }
  function narrow() { return !!(window.matchMedia && window.matchMedia('(max-width: 640px)').matches); }
  function fire(host, name, detail) { try { host.dispatchEvent(new CustomEvent(name, { bubbles: true, detail: detail })); } catch (e) { /* old engine: callbacks still work */ } }
  function visible(el) { return el.getClientRects().length > 0; }
  var ACTIVE = null; // the one open popup: { close(refocus), place() }
  function closeActive() { if (ACTIVE) ACTIVE.close(false); }
  function inPopup(el) { return !!(el && el.closest && el.closest('.lf-cal, .lf-timelist, .lf-cal-scrim')); }

  function place(pop, anchor, matchWidth) { // fixed position under the control, flipped above when there is no room
    if (pop.classList.contains('is-sheet') || pop.classList.contains('lf-cal--static')) return;
    var r = anchor.getBoundingClientRect(), vw = document.documentElement.clientWidth, vh = window.innerHeight, gap = 4;
    if (matchWidth) pop.style.minWidth = r.width + 'px';
    var h = pop.offsetHeight, w = pop.offsetWidth, below = vh - r.bottom - gap, above = r.top - gap, up = h > below && above > below;
    var top = up ? Math.max(gap, r.top - h - gap) : r.bottom + gap;
    pop.style.top = top + 'px';
    pop.style.left = Math.max(gap, Math.min(r.left, vw - w - gap)) + 'px';
    pop.setAttribute('data-placement', up ? 'above' : 'below');
  }

  /* shared field shell. bare = no label, hint or error of its own (used inside lf-datetime) */
  function shell(o, id, kind, inputHtml, btnHtml) {
    var opt = o.required || o.bare ? '' : ' <span class="lf-label__opt">' + esc(lg(o.lang).optional) + '</span>';
    return (o.bare ? '' : '<label class="lf-label" id="' + id + '-l" for="' + id + '">' + esc(o.name || '') + opt + '</label>') +
      '<div class="lf-control lf-control--mono lf-' + kind + '__control' + (o.readOnly ? ' lf-control--readonly' : '') + '"' + (o.disabled ? ' aria-disabled="true"' : '') + '>' + inputHtml + btnHtml + '</div>' +
      (o.bare ? '' : (o.hint ? '<div class="lf-hint" id="' + id + '-h">' + esc(o.hint) + '</div>' : '') + '<div class="lf-error" id="' + id + '-e" hidden></div>');
  }

  /* ================================================ lf-date ================================================ */
  function date(host, o) {
    o = Object.assign({}, o || {});
    o.lang = o.lang || docLang();
    var S = lg(o.lang), id = o.id || uid('lf-date'), name = o.name || '';
    var st = { value: '', min: o.min || '', max: o.max || '', minMsg: o.minMessage || '', required: !!o.required, ext: o.error || '', shown: false, sig: null, open: false, view: null, focus: null, code: null };
    var ctrl = {}, input, ctl, btn, errEl, pop = null, scrim = null, onDoc, onWin;

    host.classList.add('lf-field', 'lf-date');
    if (o.bare) host.classList.add('lf-date--bare'); else host.classList.add('lf-field--s');
    host.innerHTML = shell(o, id, 'date',
      '<input id="' + id + '" type="text" inputmode="numeric" autocomplete="off" spellcheck="false" maxlength="10" placeholder="' + esc(S.fmt) + '"' +
        (o.readOnly ? ' readonly' : '') + (o.disabled ? ' disabled' : '') +
        (o.bare ? ' aria-label="' + esc(name + ', ' + S.date) + '"' : '') + ' role="combobox" aria-haspopup="dialog" aria-expanded="false" aria-controls="' + id + '-cal" aria-autocomplete="none">',
      '<button type="button" class="lf-date__btn" tabindex="-1" aria-haspopup="dialog" aria-label="' + esc(S.chooseDate + (name ? ': ' + name : '')) + '"' + (o.disabled ? ' disabled' : '') + '>' + ico('calendar') + '</button>');
    input = host.querySelector('input'); ctl = host.querySelector('.lf-control'); btn = host.querySelector('.lf-date__btn'); errEl = host.querySelector('.lf-error');
    if (!o.bare && o.hint) input.setAttribute('aria-describedby', id + '-h');

    /* ----- value and errors ----- */
    function msgFor(code) {
      var b;
      if (code === 'format' || code === 'empty' || code === 'required') b = tpl(S.eFormat, { fmt: S.fmt });
      else if (code === 'nonexistent') b = S.eNone;
      else if (code === 'min') b = st.minMsg || tpl(S.eMin, { d: fmtDate(st.min, o.lang) });
      else if (code === 'max') b = tpl(S.eMax, { d: fmtDate(st.max, o.lang) });
      else b = code; // free text from setError
      return (name ? name + ': ' : '') + b;
    }
    function evalText(text) {
      var r = parseDate(text, o.lang);
      if (!r.ok) return r.code === 'empty' ? (st.required ? { code: 'required', value: '' } : { code: null, value: '' }) : { code: r.code, value: '' };
      if (st.min && r.iso < st.min) return { code: 'min', value: '' };
      if (st.max && r.iso > st.max) return { code: 'max', value: '' };
      return { code: null, value: r.iso };
    }
    function paintError() {
      var code = st.shown && st.code ? st.code : null, text = code ? msgFor(code) : (st.ext ? (name ? name + ': ' : '') + st.ext : '');
      host.classList.toggle('lf-field--error', !!text);
      if (text) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
      if (errEl) {
        errEl.hidden = !text;
        errEl.innerHTML = text ? ico('alert') + '<span>' + esc(text) + '</span>' : '';
        var d = (o.hint ? id + '-h ' : '') + (text ? id + '-e' : '');
        if (d.trim()) input.setAttribute('aria-describedby', d.trim()); else input.removeAttribute('aria-describedby');
      }
      if (o.onError) o.onError(text || '', code);
    }
    function detail(raw) { return { value: st.value, raw: raw, valid: !st.code, error: st.code, message: st.code ? msgFor(st.code) : '' }; }
    function emit(raw) {
      var sig = st.value + '|' + (st.code || '') + '|' + raw;
      if (sig === st.sig) return; st.sig = sig;
      var d = detail(raw); if (o.onChange) o.onChange(d); fire(host, 'lf-change', d);
    }
    function apply(text, show) { // evaluate typed text into state
      var ev = evalText(text); st.value = ev.value; st.code = ev.code;
      if (show) st.shown = true; else if (!ev.code) st.shown = false;
      paintError(); emit(text);
      return detail(text);
    }
    function commit() {
      var text = input.value, d = apply(text, true);
      if (st.value) input.value = fmtDate(st.value, o.lang);
      return d;
    }
    function setValue(iso, silent) {
      st.value = isDate(iso) ? iso : ''; input.value = st.value ? fmtDate(st.value, o.lang) : '';
      var ev = evalText(input.value); st.code = ev.code; st.shown = false; paintError();
      if (!silent) emit(input.value); else st.sig = st.value + '|' + (st.code || '') + '|' + input.value;
    }

    input.addEventListener('input', function (e) {
      var v = input.value, prev = input._prev == null ? '' : input._prev, del = v.length < prev.length, atEnd = input.selectionStart === v.length, caret = input.selectionStart;
      var digitsBefore = v.slice(0, caret).replace(/\D/g, '').length, m = maskDate(v, o.lang, del);
      if (m !== v) {
        input.value = m;
        if (!atEnd) { var n = 0, pos = 0; while (pos < m.length && n < digitsBefore) { if (/\d/.test(m.charAt(pos))) n++; pos++; } try { input.setSelectionRange(pos, pos); } catch (er) { /* ignore */ } }
      }
      input._prev = input.value;
      apply(input.value, st.shown);
    });
    input.addEventListener('blur', function (e) {
      if (st.open && inPopup(e.relatedTarget)) return;
      if (e.relatedTarget === btn) return;
      if (st.open && !o.static) close(false);
      commit();
    });
    input.addEventListener('keydown', function (e) {
      if (o.readOnly || o.disabled) return;
      if (e.key === 'ArrowDown' || (e.altKey && e.key === 'ArrowDown')) { e.preventDefault(); if (!st.open) open(); else focusDay(); }
      else if (e.key === 'Enter') { commit(); }
      else if (e.key === 'Tab' && st.open && !o.static) close(false);
      else if (e.key === 'Escape' && st.open) { e.preventDefault(); close(true); }
    });
    btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
    btn.addEventListener('click', function () { if (st.open) close(true); else open(); });

    /* ----- calendar ----- */
    function today() { return o.today || todayLocal(); }
    function inRange(s) { return (!st.min || s >= st.min) && (!st.max || s <= st.max); }
    function label(s) { // spoken name of a day cell
      var p = split(s), l = S.monthsGen || S.months, t = S.wdFull[weekday(s)] + ', ' + (S.monthsGen ? p.d + ' ' + l[p.m - 1] + ' ' + p.y : (o.lang === 'en' ? l[p.m - 1] + ' ' + p.d + ', ' + p.y : p.d + ' ' + l[p.m - 1] + ' ' + p.y));
      if (s === st.value) t += ', ' + S.sel; if (s === today()) t += ', ' + S.tod; if (!inRange(s)) t += ', ' + S.off;
      return t;
    }
    function buildPop() {
      var h = '<div class="lf-cal__head">' +
        '<button type="button" class="lf-cal__nav" data-nav="-12" aria-label="' + esc(S.prevY) + '">' + ico('chevrons-left') + '</button>' +
        '<button type="button" class="lf-cal__nav" data-nav="-1" aria-label="' + esc(S.prevM) + '">' + ico('chevron-left') + '</button>' +
        '<div class="lf-cal__title" id="' + id + '-t" aria-live="polite"></div>' +
        '<button type="button" class="lf-cal__nav" data-nav="1" aria-label="' + esc(S.nextM) + '">' + ico('chevron-right') + '</button>' +
        '<button type="button" class="lf-cal__nav" data-nav="12" aria-label="' + esc(S.nextY) + '">' + ico('chevrons-right') + '</button></div>' +
        '<table class="lf-cal__grid" role="grid" aria-labelledby="' + id + '-t"><thead><tr>';
      S.wd.forEach(function (w, i) { h += '<th scope="col" abbr="' + esc(S.wdFull[i]) + '">' + esc(w) + '</th>'; });
      h += '</tr></thead><tbody></tbody></table>' +
        '<div class="lf-cal__foot"><button type="button" class="lf-btn lf-btn--ghost lf-btn--s" data-cal="today">' + esc(S.today) + '</button>' +
        '<button type="button" class="lf-btn lf-btn--ghost lf-btn--s" data-cal="clear">' + esc(S.clear) + '</button>' +
        '<button type="button" class="lf-btn lf-btn--secondary lf-btn--s lf-cal__close" data-cal="close">' + esc(S.close) + '</button></div>';
      var el = document.createElement('div');
      el.className = 'lf-cal'; el.id = id + '-cal'; el.setAttribute('role', 'dialog'); el.setAttribute('aria-modal', o.static ? 'false' : 'true');
      el.setAttribute('aria-label', S.chooseDate + (name ? ': ' + name : ''));
      el.innerHTML = h; return el;
    }
    function paint() {
      var v = st.view, grid = monthGrid(v.y, v.m), td = today(), h = '', i, j, s, cls, p;
      pop.querySelector('.lf-cal__title').textContent = S.months[v.m - 1] + ' ' + v.y;
      for (i = 0; i < 6; i++) {
        h += '<tr>';
        for (j = 0; j < 7; j++) {
          s = grid[i * 7 + j]; p = split(s);
          cls = 'lf-cal__day' + (p.m !== v.m ? ' is-out' : '') + (s === td ? ' is-today' : '') + (s === st.value ? ' is-selected' : '') + (inRange(s) ? '' : ' is-off');
          h += '<td role="gridcell" aria-selected="' + (s === st.value) + '"' + (inRange(s) ? '' : ' aria-disabled="true"') + '>' +
            '<button type="button" class="' + cls + '" data-iso="' + s + '" tabindex="' + (s === st.focus ? 0 : -1) + '"' + (s === td ? ' aria-current="date"' : '') + (inRange(s) ? '' : ' aria-disabled="true"') + ' aria-label="' + esc(label(s)) + '">' + p.d + '</button></td>';
        }
        h += '</tr>';
      }
      pop.querySelector('tbody').innerHTML = h;
      var t = pop.querySelector('[data-cal="today"]'); t.disabled = !inRange(td);
    }
    function focusDay() { var b = pop && pop.querySelector('.lf-cal__day[data-iso="' + st.focus + '"]'); if (b) b.focus(); }
    function moveFocus(s) {
      s = clamp(s, st.min, st.max); var p = split(s); st.focus = s;
      if (p.y !== st.view.y || p.m !== st.view.m) st.view = { y: p.y, m: p.m };
      paint(); focusDay();
    }
    function navMonths(n) {
      var f = addMonths(st.focus, n); f = clamp(f, st.min, st.max); st.focus = f;
      var p = split(addMonths(mk(st.view.y, st.view.m, 1), n)); st.view = { y: p.y, m: p.m }; paint();
    }
    function pick(s) {
      if (!isDate(s) || !inRange(s)) return;
      input.value = fmtDate(s, o.lang); input._prev = input.value; apply(input.value, true); close(true);
    }
    function open() {
      if (o.readOnly || o.disabled || st.open) return;
      closeActive();
      var base = isDate(st.value) ? st.value : clamp(today(), st.min, st.max), p = split(base);
      st.open = true; st.focus = base; st.view = { y: p.y, m: p.m };
      pop = buildPop(); paint();
      if (o.static) { host.appendChild(pop); pop.classList.add('lf-cal--static'); }
      else {
        if (narrow()) { pop.classList.add('is-sheet'); scrim = document.createElement('div'); scrim.className = 'lf-cal-scrim'; document.body.appendChild(scrim); scrim.addEventListener('mousedown', function () { close(false); }); }
        document.body.appendChild(pop); place(pop, ctl);
      }
      input.setAttribute('aria-expanded', 'true'); btn.setAttribute('aria-expanded', 'true');
      pop.addEventListener('click', onClick); pop.addEventListener('keydown', onKey);
      pop.addEventListener('mousedown', function (e) { if (!e.target.closest('button')) e.preventDefault(); else if (document.activeElement === input) e.preventDefault(); });
      if (!o.static) {
        onDoc = function (e) { if (pop && !pop.contains(e.target) && !host.contains(e.target)) close(false); };
        onWin = function (e) { if (pop && !(e && e.target && e.target.nodeType === 1 && pop.contains(e.target))) place(pop, ctl); };
        document.addEventListener('mousedown', onDoc); window.addEventListener('resize', onWin); window.addEventListener('scroll', onWin, true);
        ACTIVE = { close: close, place: onWin };
        focusDay();
      }
      fire(host, 'lf-open', {});
    }
    function close(refocus) {
      if (!st.open || o.static) return;
      st.open = false;
      if (pop) { pop.remove(); pop = null; } if (scrim) { scrim.remove(); scrim = null; }
      document.removeEventListener('mousedown', onDoc); window.removeEventListener('resize', onWin); window.removeEventListener('scroll', onWin, true);
      if (ACTIVE && ACTIVE.close === close) ACTIVE = null;
      input.setAttribute('aria-expanded', 'false'); btn.setAttribute('aria-expanded', 'false');
      if (refocus) input.focus();
      fire(host, 'lf-close', {});
    }
    function onClick(e) {
      var b = e.target.closest('button'); if (!b || !pop.contains(b)) return;
      if (b.hasAttribute('data-nav')) { navMonths(+b.getAttribute('data-nav')); return; }
      var a = b.getAttribute('data-cal');
      if (a === 'today') pick(today());
      else if (a === 'clear') { input.value = ''; input._prev = ''; apply('', true); close(true); }
      else if (a === 'close') close(true);
      else if (b.hasAttribute('data-iso') && !b.hasAttribute('aria-disabled')) pick(b.getAttribute('data-iso'));
    }
    function onKey(e) {
      var k = e.key, t = e.target, day = t.classList && t.classList.contains('lf-cal__day');
      if (k === 'Escape') { e.preventDefault(); e.stopPropagation(); close(true); return; }
      if (k === 'Tab') {
        var f = Array.prototype.filter.call(pop.querySelectorAll('button:not([disabled]):not([tabindex="-1"])'), visible), first = f[0], last = f[f.length - 1];
        if (!f.length) return;
        if (e.shiftKey && (t === first || !pop.contains(t))) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && (t === last || !pop.contains(t))) { e.preventDefault(); first.focus(); }
        return;
      }
      if (!day) return;
      var s = t.getAttribute('data-iso'), to = null;
      if (k === 'ArrowLeft') to = addDays(s, -1);
      else if (k === 'ArrowRight') to = addDays(s, 1);
      else if (k === 'ArrowUp') to = addDays(s, -7);
      else if (k === 'ArrowDown') to = addDays(s, 7);
      else if (k === 'Home') to = addDays(s, -weekday(s));
      else if (k === 'End') to = addDays(s, 6 - weekday(s));
      else if (k === 'PageUp') to = addMonths(s, e.shiftKey ? -12 : -1);
      else if (k === 'PageDown') to = addMonths(s, e.shiftKey ? 12 : 1);
      if (to) { e.preventDefault(); moveFocus(to); }
    }

    /* ----- public ----- */
    ctrl.el = host; ctrl.input = input; ctrl.id = id;
    ctrl.getValue = function () { return st.value; };
    ctrl.getText = function () { return input.value; };
    ctrl.setValue = setValue;
    ctrl.validate = function (show) { return show === false ? detail(input.value) : commit(); };
    ctrl.setError = function (body) { st.ext = body || ''; paintError(); };
    ctrl.setMin = function (iso, msg) { st.min = iso || ''; st.minMsg = msg || ''; var ev = evalText(input.value); st.code = ev.code; st.value = ev.value; paintError(); emit(input.value); if (pop) paint(); };
    ctrl.setMax = function (iso) { st.max = iso || ''; var ev = evalText(input.value); st.code = ev.code; st.value = ev.value; paintError(); emit(input.value); if (pop) paint(); };
    ctrl.setRequired = function (b) { st.required = !!b; };
    ctrl.open = open; ctrl.close = close;
    ctrl.isOpen = function () { return st.open; };
    ctrl.destroy = function () { close(false); host.innerHTML = ''; };

    /* initial value: an ISO value, or raw text that failed to parse earlier (kept so the user can fix it) */
    if (o.value && isDate(o.value)) setValue(o.value, true);
    else if (o.raw) { input.value = o.raw; input._prev = o.raw; var ev0 = evalText(o.raw); st.code = ev0.code; st.value = ev0.value; st.sig = st.value + '|' + (st.code || '') + '|' + o.raw; }
    else st.sig = '||';
    if (o.showErrors) { st.shown = true; if (!input.value && st.required) st.code = 'required'; }
    paintError();
    if (o.open) open();
    return ctrl;
  }

  /* ================================================ lf-time ================================================ */
  function time(host, o) {
    o = Object.assign({}, o || {});
    o.lang = o.lang || docLang();
    var S = lg(o.lang), id = o.id || uid('lf-time'), name = o.name || '', useList = o.list !== false && !o.readOnly && !o.disabled, step = o.step || 15;
    var st = { value: '', required: !!o.required, ext: o.error || '', shown: false, sig: null, open: false, active: -1, code: null };
    var ctrl = {}, input, ctl, btn, errEl, pop = null, onDoc, onWin;

    host.classList.add('lf-field', 'lf-time');
    if (o.bare) host.classList.add('lf-time--bare');
    host.innerHTML = shell(o, id, 'time',
      '<input id="' + id + '" type="text" inputmode="numeric" autocomplete="off" spellcheck="false" maxlength="5" placeholder="' + esc(S.tfmt) + '"' +
        (o.readOnly ? ' readonly' : '') + (o.disabled ? ' disabled' : '') + (o.bare ? ' aria-label="' + esc(name + ', ' + S.time) + '"' : '') +
        (useList ? ' role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-controls="' + id + '-list" aria-autocomplete="none"' : '') + '>',
      '<button type="button" class="lf-time__btn" tabindex="-1" aria-label="' + esc(S.chooseTime + (name ? ': ' + name : '')) + '"' + (o.disabled || !useList ? ' disabled' : '') + '>' + ico('clock') + '</button>');
    input = host.querySelector('input'); ctl = host.querySelector('.lf-control'); btn = host.querySelector('.lf-time__btn'); errEl = host.querySelector('.lf-error');
    if (!useList) btn.hidden = true;
    if (!o.bare && o.hint) input.setAttribute('aria-describedby', id + '-h');

    function msgFor(code) {
      var b = code === 'range' ? S.tRange : (code === 'format' || code === 'required' || code === 'empty') ? tpl(S.tFormat, { fmt: S.tfmt }) : code;
      return (name ? name + ': ' : '') + b;
    }
    function evalText(text) {
      var r = parseTime(text);
      if (!r.ok) return r.code === 'empty' ? (st.required ? { code: 'required', value: '' } : { code: null, value: '' }) : { code: r.code, value: '' };
      return { code: null, value: r.time };
    }
    function paintError() {
      var code = st.shown && st.code ? st.code : null, text = code ? msgFor(code) : (st.ext ? (name ? name + ': ' : '') + st.ext : '');
      host.classList.toggle('lf-field--error', !!text);
      if (text) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
      if (errEl) {
        errEl.hidden = !text; errEl.innerHTML = text ? ico('alert') + '<span>' + esc(text) + '</span>' : '';
        var d = (o.hint ? id + '-h ' : '') + (text ? id + '-e' : '');
        if (d.trim()) input.setAttribute('aria-describedby', d.trim()); else input.removeAttribute('aria-describedby');
      }
      if (o.onError) o.onError(text || '', code);
    }
    function detail(raw) { return { value: st.value, raw: raw, valid: !st.code, error: st.code, message: st.code ? msgFor(st.code) : '' }; }
    function emit(raw) {
      var sig = st.value + '|' + (st.code || '') + '|' + raw;
      if (sig === st.sig) return; st.sig = sig;
      var d = detail(raw); if (o.onChange) o.onChange(d); fire(host, 'lf-change', d);
    }
    function apply(text, show) {
      var ev = evalText(text); st.value = ev.value; st.code = ev.code;
      if (show) st.shown = true; else if (!ev.code) st.shown = false;
      paintError(); emit(text); return detail(text);
    }
    function commit() { var d = apply(input.value, true); if (st.value) input.value = st.value; return d; }
    function setText(t, show) { input.value = t; input._prev = t; apply(t, show); }
    function setValue(t, silent) {
      var r = parseTime(t); st.value = r.ok ? r.time : ''; input.value = st.value; input._prev = st.value;
      var ev = evalText(input.value); st.code = ev.code; st.shown = false; paintError();
      if (!silent) emit(input.value); else st.sig = st.value + '|' + (st.code || '') + '|' + input.value;
    }
    function nowMin() { if (o.now != null) return o.now; var d = new Date(); return d.getHours() * 60 + d.getMinutes(); }
    function bump(delta) {
      var r = parseTime(input.value), cur = r.ok ? r.min : null;
      setText(fmtTime(stepTime(cur, delta, nowMin())), true);
    }

    input.addEventListener('input', function () {
      var v = input.value, prev = input._prev == null ? '' : input._prev, m = maskTime(v, v.length < prev.length);
      if (m !== v) input.value = m;
      input._prev = input.value; apply(input.value, st.shown);
    });
    input.addEventListener('blur', function (e) {
      if (st.open && inPopup(e.relatedTarget)) return;
      if (e.relatedTarget === btn) return;
      if (st.open) closeList(false);
      commit();
    });
    input.addEventListener('keydown', function (e) {
      if (o.readOnly || o.disabled) return;
      var k = e.key;
      if (st.open) {
        if (k === 'ArrowDown') { e.preventDefault(); setActive(Math.min(st.active + 1, options().length - 1)); }
        else if (k === 'ArrowUp') { e.preventDefault(); setActive(Math.max(st.active - 1, 0)); }
        else if (k === 'PageDown') { e.preventDefault(); setActive(Math.min(st.active + 60 / step, options().length - 1)); }
        else if (k === 'PageUp') { e.preventDefault(); setActive(Math.max(st.active - 60 / step, 0)); }
        else if (k === 'Home') { e.preventDefault(); setActive(0); }
        else if (k === 'End') { e.preventDefault(); setActive(options().length - 1); }
        else if (k === 'Enter') { e.preventDefault(); chooseActive(); }
        else if (k === 'Escape') { e.preventDefault(); closeList(true); }
        else if (k === 'Tab') closeList(false);
        return;
      }
      if (k === 'ArrowUp') { e.preventDefault(); bump(1); }
      else if (k === 'ArrowDown' && e.altKey && useList) { e.preventDefault(); openList(); }
      else if (k === 'ArrowDown') { e.preventDefault(); bump(-1); }
      else if (k === 'PageUp') { e.preventDefault(); bump(15); }
      else if (k === 'PageDown') { e.preventDefault(); bump(-15); }
      else if (k === 'Enter') commit();
    });
    btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
    btn.addEventListener('click', function () { input.focus(); if (st.open) closeList(true); else openList(); });

    /* ----- list of steps ----- */
    function options() { return pop ? pop.querySelectorAll('.lf-timelist__opt') : []; }
    function openList() {
      if (!useList || st.open) return; closeActive();
      var h = '', i, n = Math.floor(1440 / step), cur = parseTime(input.value), curMin = cur.ok ? cur.min : null, near = -1;
      pop = document.createElement('div'); pop.className = 'lf-timelist'; pop.id = id + '-list'; pop.setAttribute('role', 'listbox'); pop.setAttribute('aria-label', S.chooseTime + (name ? ': ' + name : ''));
      for (i = 0; i < n; i++) h += '<div class="lf-timelist__opt" role="option" id="' + id + '-o' + i + '" data-min="' + (i * step) + '" aria-selected="' + (curMin === i * step) + '">' + fmtTime(i * step) + ico('check') + '</div>';
      pop.innerHTML = h;
      near = curMin == null ? Math.floor(nowMin() / step) : Math.floor(curMin / step);
      if (o.static) { host.appendChild(pop); pop.classList.add('lf-timelist--static'); pop.style.maxHeight = 'calc(var(--row-h) * 4)'; }
      else { document.body.appendChild(pop); place(pop, ctl, true); }
      st.open = true; input.setAttribute('aria-expanded', 'true'); setActive(near);
      if (!o.static) { var no = options()[near]; if (no) pop.scrollTop = Math.max(0, no.offsetTop - (pop.clientHeight - no.offsetHeight) / 2); }
      pop.addEventListener('mousedown', function (e) { e.preventDefault(); });
      pop.addEventListener('click', function (e) { var op = e.target.closest('.lf-timelist__opt'); if (op) { setText(fmtTime(+op.getAttribute('data-min')), true); closeList(true); } });
      if (o.static) { fire(host, 'lf-open', {}); return; }
      onDoc = function (e) { if (pop && !pop.contains(e.target) && !host.contains(e.target)) closeList(false); };
      onWin = function (e) { if (pop && !(e && e.target && e.target.nodeType === 1 && pop.contains(e.target))) place(pop, ctl, true); };
      document.addEventListener('mousedown', onDoc); window.addEventListener('resize', onWin); window.addEventListener('scroll', onWin, true);
      ACTIVE = { close: closeList, place: onWin };
      fire(host, 'lf-open', {});
    }
    function setActive(i) {
      var os = options(); if (!os.length) return; i = Math.max(0, Math.min(os.length - 1, i)); st.active = i;
      Array.prototype.forEach.call(os, function (o2, j) { o2.classList.toggle('is-active', j === i); });
      input.setAttribute('aria-activedescendant', os[i].id);
      var op = os[i]; if (pop.scrollTop > op.offsetTop - 2) pop.scrollTop = op.offsetTop - 2; else if (op.offsetTop + op.offsetHeight > pop.scrollTop + pop.clientHeight) pop.scrollTop = op.offsetTop + op.offsetHeight - pop.clientHeight + 2;
    }
    function chooseActive() { var op = options()[st.active]; if (op) setText(fmtTime(+op.getAttribute('data-min')), true); closeList(true); }
    function closeList(refocus) {
      if (!st.open || o.static) return; st.open = false;
      if (pop) { pop.remove(); pop = null; }
      document.removeEventListener('mousedown', onDoc); window.removeEventListener('resize', onWin); window.removeEventListener('scroll', onWin, true);
      if (ACTIVE && ACTIVE.close === closeList) ACTIVE = null;
      input.setAttribute('aria-expanded', 'false'); input.removeAttribute('aria-activedescendant');
      if (refocus) input.focus();
      fire(host, 'lf-close', {});
    }

    ctrl.el = host; ctrl.input = input; ctrl.id = id;
    ctrl.getValue = function () { return st.value; };
    ctrl.getText = function () { return input.value; };
    ctrl.setValue = setValue;
    ctrl.validate = function (show) { return show === false ? detail(input.value) : commit(); };
    ctrl.setError = function (body) { st.ext = body || ''; paintError(); };
    ctrl.setRequired = function (b) { st.required = !!b; };
    ctrl.open = openList; ctrl.close = closeList;
    ctrl.isOpen = function () { return st.open; };
    ctrl.destroy = function () { closeList(false); host.innerHTML = ''; };

    if (o.value && parseTime(o.value).ok) setValue(o.value, true);
    else if (o.raw) { input.value = o.raw; input._prev = o.raw; var ev0 = evalText(o.raw); st.code = ev0.code; st.value = ev0.value; st.sig = st.value + '|' + (st.code || '') + '|' + o.raw; }
    else st.sig = '||';
    if (o.showErrors) { st.shown = true; if (!input.value && st.required) st.code = 'required'; }
    paintError();
    if (o.open) openList();
    return ctrl;
  }

  /* ============================================== lf-datetime ============================================== */
  function datetime(host, o) {
    o = Object.assign({}, o || {});
    o.lang = o.lang || docLang();
    var S = lg(o.lang), id = o.id || uid('lf-datetime'), name = o.name || '';
    var hint = o.hint != null ? o.hint : tpl(S.tz, { tz: o.tz || 'Asia/Almaty' });
    var errs = { date: '', time: '' }, ctrl = {}, dc, tc, errEl, sig = null;

    host.classList.add('lf-field', 'lf-datetime');
    host.setAttribute('role', 'group'); host.setAttribute('aria-labelledby', id + '-l'); host.setAttribute('aria-describedby', id + '-h');
    host.innerHTML = '<span class="lf-label" id="' + id + '-l">' + esc(name) + (o.required ? '' : ' <span class="lf-label__opt">' + esc(S.optional) + '</span>') + '</span>' +
      '<div class="lf-datetime__row"><div class="lf-datetime__date"></div><div class="lf-datetime__time"></div></div>' +
      '<div class="lf-hint" id="' + id + '-h">' + esc(hint) + '</div><div class="lf-error" id="' + id + '-e" hidden></div>';
    errEl = host.querySelector('.lf-error');

    function paint() {
      var text = errs.date || errs.time || '';
      host.classList.toggle('lf-datetime--error', !!text);
      errEl.hidden = !text; errEl.innerHTML = text ? ico('alert') + '<span>' + esc(text) + '</span>' : '';
      host.setAttribute('aria-describedby', id + '-h' + (text ? ' ' + id + '-e' : ''));
    }
    function value() { return { date: dc.getValue(), time: tc.getValue() }; }
    function emit() {
      var v = value(), s = v.date + 'T' + v.time + '|' + errs.date + '|' + errs.time; if (s === sig) return; sig = s;
      var bad = errs.date ? 'date' : errs.time ? 'time' : null;
      var d = { value: v, iso: combine(v.date, v.time), valid: !bad, error: bad ? { part: bad, message: errs[bad] } : null };
      if (o.onChange) o.onChange(d); fire(host, 'lf-change', d);
    }
    var common = { lang: o.lang, name: name, bare: true, required: !!o.required, readOnly: o.readOnly, disabled: o.disabled, showErrors: o.showErrors };
    dc = date(host.querySelector('.lf-datetime__date'), Object.assign({}, common, {
      id: id + '-d', value: o.value && o.value.date, raw: o.rawDate, min: o.min, max: o.max, today: o.today,
      onError: function (t) { errs.date = t; paint(); }, onChange: emit
    }));
    tc = time(host.querySelector('.lf-datetime__time'), Object.assign({}, common, {
      id: id + '-t', value: o.value && o.value.time, raw: o.rawTime, list: o.list, step: o.step, now: o.now,
      onError: function (t) { errs.time = t; paint(); }, onChange: emit
    }));
    // leaving the whole group: a half-filled value is an error on the part that is missing
    host.addEventListener('focusout', function (e) {
      var to = e.relatedTarget; if (to && (host.contains(to) || inPopup(to))) return;
      setTimeout(function () {
        if (host.contains(document.activeElement) || inPopup(document.activeElement)) return;
        var d = dc.getValue(), t = tc.getText().trim() !== '' || tc.getValue() !== '', dd = dc.getText().trim() !== '' || d !== '';
        dc.setRequired(!!o.required || t); tc.setRequired(!!o.required || dd);
        dc.validate(true); tc.validate(true);
      }, 0);
    });

    ctrl.el = host; ctrl.date = dc; ctrl.time = tc; ctrl.id = id;
    ctrl.getValue = value;
    ctrl.getIso = function () { return combine(dc.getValue(), tc.getValue()); };
    ctrl.setValue = function (v, silent) { dc.setValue(v && v.date, true); tc.setValue(v && v.time, true); if (!silent) emit(); };
    ctrl.validate = function () {
      var dd = dc.getText().trim() !== '' || dc.getValue() !== '', t = tc.getText().trim() !== '' || tc.getValue() !== '';
      dc.setRequired(!!o.required || t); tc.setRequired(!!o.required || dd); dc.validate(true); tc.validate(true);
      return { value: value(), iso: ctrl.getIso(), valid: !(errs.date || errs.time) };
    };
    ctrl.setError = function (body) { dc.setError(''); tc.setError(body); };
    ctrl.destroy = function () { dc.destroy(); tc.destroy(); host.innerHTML = ''; };
    if (o.showErrors) ctrl.validate();
    return ctrl;
  }

  /* data-attribute mounting, for static pages (style guide) and for hosts rendered as HTML strings */
  function mountAll(root, defaults) {
    var out = [];
    Array.prototype.forEach.call((root || document).querySelectorAll('[data-lf-date],[data-lf-time],[data-lf-datetime]'), function (h) {
      if (h._lf) return;
      var g = function (k) { return h.getAttribute('data-' + k); }, has = function (k) { return h.hasAttribute('data-' + k); };
      var o = Object.assign({}, defaults || {}, {
        id: g('id') || undefined, name: g('name') || '', lang: g('lang') || (defaults && defaults.lang) || undefined, hint: g('hint') != null ? g('hint') : undefined,
        min: g('min') || undefined, max: g('max') || undefined, minMessage: g('min-msg') || undefined, today: g('today') || undefined, now: g('now') != null ? +g('now') : undefined,
        required: has('required'), disabled: has('disabled'), readOnly: has('readonly'), showErrors: has('show-errors'), open: has('open'), static: has('static'),
        error: g('error') || undefined, list: g('list') === 'off' ? false : undefined, tz: g('tz') || undefined
      });
      var c;
      if (has('lf-datetime')) {
        o.value = { date: g('date') || '', time: g('time') || '' }; o.rawDate = g('raw-date') || undefined; o.rawTime = g('raw-time') || undefined;
        c = datetime(h, o);
      } else if (has('lf-time')) { o.value = g('value') || ''; o.raw = g('raw') || undefined; c = time(h, o); }
      else { o.value = g('value') || ''; o.raw = g('raw') || undefined; c = date(h, o); }
      if (has('focus-ring')) Array.prototype.forEach.call(h.querySelectorAll('.lf-control'), function (x) { x.classList.add('is-focus'); });
      h._lf = c; out.push(c);
    });
    return out;
  }

  return {
    date: date, time: time, datetime: datetime, mountAll: mountAll, closeAll: closeActive, strings: L,
    parseDate: parseDate, fmtDate: fmtDate, maskDate: maskDate, parseTime: parseTime, fmtTime: fmtTime, maskTime: maskTime, stepTime: stepTime,
    addDays: addDays, addMonths: addMonths, monthGrid: monthGrid, weekday: weekday, isDate: isDate, combine: combine, display: display, clamp: clamp
  };
})();
/* LFDT:end */

/* LFLAYOUT:begin ---------------------------------------------------------------------------------------------
   Layout registry of the document form (lf-doc). The owner chose PREPARED templates, not free arrangement (D-100).
   A layout is an entry in LFDocLayout.layouts: its name is the value of data-layout on .lf-doc, its CSS hook is
   `.lf-doc[data-layout="<name>"]` in components.css, `panes` says what is on screen, `tabs` (optional) lists the panes that
   share one area and are switched by a tab block, `defaultTab` is the tab shown first: a string, or {new, existing} (a new document opens on the header, an existing one on the lines). It is a PARAMETER: apply() takes `tab` (explicit choice) and `state` ('new'|'existing').
   To add a layout: (1) register({...}) here, (2) write the CSS under its hook (grid areas per breakpoint), (3) add the row to
   the table in NOTES.md "Layouts". The form's markup and behaviour do not change.
   apply(el, name, opts): sets data-layout and data-tab, builds the tab block (role=tablist) before the panels when the layout
   has tabs, links tabs and panels (aria-controls, aria-labelledby), wires arrow keys. opts: tab, state, labels {pane: text},
   badges {pane: number of problems}, counts {pane: number}, label (tablist name), problems (word for the badge's
   accessible name), onTab(id). Call it after every (re)render of the form. */
var LFDocLayout = (function () {
  'use strict';
  var R = {};
  function register(def) { R[def.name] = def; return def; }
  register({
    name: 'row', hook: '.lf-doc[data-layout="row"]', panes: ['list', 'header', 'lines'], tabs: null,
    breakpoints: '>= 1440: list | header | lines on one row (action bar above header and lines); 900-1439: list | header, lines below; < 900: one column, a selected document replaces the list'
  });
  register({
    name: 'tabs', hook: '.lf-doc[data-layout="tabs"]', panes: ['list', 'tabs'], defaultTab: { 'new': 'header', existing: 'lines' },
    tabs: [{ id: 'header', panel: '.lf-doc__header' }, { id: 'lines', panel: '.lf-doc__lines' }],
    breakpoints: '>= 901: list on the left; on the right the action bar, then the tab block (Header | Lines, one panel visible); < 900: one column, a selected document replaces the list, tab block directly under the document title'
  });
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function select(el, id, focus) {
    var lay = R[el.getAttribute('data-layout')]; if (!lay || !lay.tabs) return;
    el.setAttribute('data-tab', id);
    Array.prototype.forEach.call(el.querySelectorAll('.lf-doc__tablist [role=tab]'), function (b) {
      var on = b.getAttribute('data-tab') === id; b.setAttribute('aria-selected', on ? 'true' : 'false'); b.tabIndex = on ? 0 : -1; if (on && focus) b.focus();
    });
  }
  function apply(el, name, o) {
    o = o || {}; var lay = R[name] || R.row, old = el.querySelector('.lf-doc__tablist'), i;
    if (old) old.remove();
    Array.prototype.forEach.call(el.querySelectorAll('[role=tabpanel]'), function (p) { p.removeAttribute('role'); p.removeAttribute('aria-labelledby'); p.removeAttribute('tabindex'); });
    el.setAttribute('data-layout', lay.name);
    if (!lay.tabs) { el.removeAttribute('data-tab'); return lay; }
    var panels = lay.tabs.map(function (t) { return el.querySelector(':scope > ' + t.panel); });
    var top = el.querySelector(':scope > .lf-doc__top');
    if (!top || panels.some(function (p) { return !p; })) { el.removeAttribute('data-tab'); return lay; } // empty, error: nothing to switch
    var dt = lay.defaultTab, id = el.id || 'lf-doc', cur = o.tab, ids = lay.tabs.map(function (t) { return t.id; });
    if (ids.indexOf(cur) < 0) cur = (dt && typeof dt === 'object' ? dt[o.state === 'new' ? 'new' : 'existing'] : dt) || ids[0];
    var h = '<div class="lf-doc__tablist lf-tabs" role="tablist" aria-label="' + esc(o.label || '') + '">';
    lay.tabs.forEach(function (t) {
      var b = o.badges && o.badges[t.id], c = o.counts && o.counts[t.id];
      h += '<button type="button" class="lf-tab" role="tab" id="' + id + '-tab-' + t.id + '" data-tab="' + t.id + '" aria-controls="' + id + '-panel-' + t.id + '" aria-selected="false" tabindex="-1">' + esc((o.labels || {})[t.id] || t.id) +
        (c != null ? ' <span class="lf-count">' + c + '</span>' : '') +
        (b ? ' <span class="lf-count lf-count--danger" role="img" aria-label="' + b + ' ' + esc(o.problems || '') + '"><svg class="lf-icon" aria-hidden="true"><use href="#i-alert"/></svg>' + b + '</span>' : '') + '</button>';
    });
    top.insertAdjacentHTML('afterend', h + '</div>');
    lay.tabs.forEach(function (t, k) { var p = panels[k]; p.setAttribute('role', 'tabpanel'); p.id = id + '-panel-' + t.id; p.setAttribute('aria-labelledby', id + '-tab-' + t.id); p.tabIndex = 0; });
    var list = el.querySelector('.lf-doc__tablist');
    list.addEventListener('click', function (e) { var b = e.target.closest('[role=tab]'); if (!b) return; select(el, b.getAttribute('data-tab'), false); if (o.onTab) o.onTab(b.getAttribute('data-tab')); });
    list.addEventListener('keydown', function (e) {
      var k = e.key, n = ids.length, at = ids.indexOf(el.getAttribute('data-tab')), to = -1;
      if (k === 'ArrowRight') to = (at + 1) % n; else if (k === 'ArrowLeft') to = (at - 1 + n) % n; else if (k === 'Home') to = 0; else if (k === 'End') to = n - 1;
      if (to < 0) return; e.preventDefault(); select(el, ids[to], true); if (o.onTab) o.onTab(ids[to]);
    });
    select(el, cur, false);
    return lay;
  }
  return { layouts: R, register: register, apply: apply, select: select, names: function () { return Object.keys(R); } };
})();
/* LFLAYOUT:end */
