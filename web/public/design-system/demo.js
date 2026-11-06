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
    var opt = o.required || o.bare || o.noOptional ? '' : ' <span class="lf-label__opt">' + esc(lg(o.lang).optional) + '</span>';
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

/* LFREGLAYOUT:begin ------------------------------------------------------------------------------------------
   Layout registry of the registry component (lf-registry), same idea as LFDocLayout: a layout is an entry in
   LFRegLayout.layouts, its name is the value of data-layout on .lf-reg, its CSS hook is `.lf-reg[data-layout="<name>"]`.
   `tabs` (optional) lists the details sections that share one place and are switched by a tab block; `defaultTab` is the first
   tab shown (a PARAMETER; apply() takes `tab`). apply(el, name, {tab, labels, counts, badges, label, problems, onTab}) sets
   data-layout and data-tab, inserts the tab block (role=tablist) after `.lf-reg__top`, links tabs and panels, wires the arrow keys.
   Add a layout: register({...}) + CSS under its hook + a row in NOTES.md "Layouts of the registry". */
var LFRegLayout = (function () {
  'use strict';
  var R = {};
  function register(def) { R[def.name] = def; return def; }
  register({ name: 'split', hook: '.lf-reg[data-layout="split"]', panes: ['list', 'details'], tabs: null,
    breakpoints: '>= 901: list | details (sections stacked in the details pane); < 900: list, a selected record replaces it, back button' });
  register({ name: 'tabs', hook: '.lf-reg[data-layout="tabs"]', panes: ['list', 'details'], defaultTab: 'overview',
    tabs: [{ id: 'overview', panel: '[data-pane="overview"]' }, { id: 'related', panel: '[data-pane="related"]' }, { id: 'history', panel: '[data-pane="history"]' }],
    breakpoints: '>= 901: narrow list on the left, details on the right with the sections as a tab block (Overview | Related | History); < 900: as split, tab block under the header card' });
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function select(el, id, focus) {
    el.setAttribute('data-tab', id);
    Array.prototype.forEach.call(el.querySelectorAll('.lf-reg__tablist [role=tab]'), function (b) {
      var on = b.getAttribute('data-tab') === id; b.setAttribute('aria-selected', on ? 'true' : 'false'); b.tabIndex = on ? 0 : -1; if (on && focus) b.focus();
    });
  }
  function apply(el, name, o) {
    o = o || {}; var lay = R[name] || R.split, old = el.querySelector('.lf-reg__tablist');
    if (old) old.remove();
    Array.prototype.forEach.call(el.querySelectorAll('[role=tabpanel]'), function (p) { p.removeAttribute('role'); p.removeAttribute('aria-labelledby'); p.removeAttribute('tabindex'); });
    el.setAttribute('data-layout', lay.name);
    if (!lay.tabs) { el.removeAttribute('data-tab'); return lay; }
    var panels = lay.tabs.map(function (t) { return el.querySelector(t.panel); }), top = el.querySelector('.lf-reg__top');
    if (!top || panels.some(function (p) { return !p; })) { el.removeAttribute('data-tab'); return lay; } // blank, loading, create: nothing to switch
    var id = el.id || 'lf-reg', ids = lay.tabs.map(function (t) { return t.id; }), cur = ids.indexOf(o.tab) >= 0 ? o.tab : (lay.defaultTab || ids[0]);
    var h = '<div class="lf-reg__tablist lf-tabs" role="tablist" aria-label="' + esc(o.label || '') + '">';
    lay.tabs.forEach(function (t) {
      var c = o.counts && o.counts[t.id], b = o.badges && o.badges[t.id];
      h += '<button type="button" class="lf-tab" role="tab" id="' + id + '-tab-' + t.id + '" data-tab="' + t.id + '" aria-controls="' + id + '-panel-' + t.id + '" aria-selected="false" tabindex="-1">' + esc((o.labels || {})[t.id] || t.id) +
        (c != null ? ' <span class="lf-count">' + c + '</span>' : '') +
        (b ? ' <span class="lf-count lf-count--danger" role="img" aria-label="' + b + ' ' + esc(o.problems || '') + '"><svg class="lf-icon" aria-hidden="true"><use href="#i-alert"/></svg>' + b + '</span>' : '') + '</button>';
    });
    top.insertAdjacentHTML('afterend', h + '</div>');
    lay.tabs.forEach(function (t, k) { var p = panels[k]; p.setAttribute('role', 'tabpanel'); p.id = id + '-panel-' + t.id; p.setAttribute('aria-labelledby', id + '-tab-' + t.id); p.tabIndex = 0; });
    var list = el.querySelector('.lf-reg__tablist');
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
/* LFREGLAYOUT:end */

/* LFJRNLAYOUT:begin ------------------------------------------------------------------------------------------
   Layout registry of the movement register (lf-journal), same idea as LFDocLayout and LFRegLayout. A layout is an entry in
   LFJrnLayout.layouts (name = value of data-layout on .lf-jrn, CSS hook `.lf-jrn[data-layout="<name>"]`); `split` = list | details.
   `variants` are the NARROW (<= 900 px) behaviours chosen with data-variant on .lf-jrn: v1 inline legs, v2 bottom sheet,
   v3 full screen. apply(el, name, variant) sets both attributes. Add a layout: register({...}) + CSS under its hook + a row in
   NOTES.md "Narrow variants of the journal". */
var LFJrnLayout = (function () {
  'use strict';
  var R = {}, V = {
    v1: { name: 'v1', title: 'Inline legs', detailsAs: 'full screen (v3)', note: 'a row expands in place into its legs; the Details button opens the full screen with previous/next' },
    v2: { name: 'v2', title: 'Bottom sheet', detailsAs: 'sheet', note: 'a tap opens the details in a sheet (85 % high) over the list, with previous/next, close, drag handle, Escape' },
    v3: { name: 'v3', title: 'Full screen', detailsAs: 'full screen', note: 'a tap replaces the list with the details, back button and previous/next' }
  };
  function register(def) { R[def.name] = def; return def; }
  register({ name: 'split', hook: '.lf-jrn[data-layout="split"]', panes: ['list', 'details'], breakpoints: '>= 1200: list | details; 901-1199: same, optional columns hidden; <= 900: narrow variant' });
  function apply(el, name, variant) { el.setAttribute('data-layout', (R[name] || R.split).name); el.setAttribute('data-variant', (V[variant] || V.v1).name); return R[name] || R.split; }
  return { layouts: R, variants: V, register: register, apply: apply };
})();
/* LFJRNLAYOUT:end */

/* LFPREFS:begin ----------------------------------------------------------------------------------------------
   Remembered layout per user: ONE JSON document stored under the user preference key `ui.layout` (product store, T-1389 L1)
   with a localStorage fallback (key `lf.prefs.ui.layout.v1`). The product supplies a backend {load(): string|null, save(json: string)};
   without it localStorage is used, and without that the values live in memory for the page only. Contract (all other keys are dropped):
   { "v": 1,
     "shell":   { "sidenav": { "collapsed": false, "w": 248 } },                    // global: side nav collapsed flag, width in px (160-420)
     "screens": { "<screenId>": {                                                   // screenId: [a-z0-9.-]{1,48}, e.g. stock.documents, stock.registry.items, stock.journal
         "panes":     { "<splitId>": [22.5, 18.0] },                                 // splitId: [a-z0-9-]{1,24}; one number per sized pane: percent of the container width (5-85)
         "collapsed": { "<splitId>": [0] },                                         // indexes of collapsed panes
         "cols":      { "<tableId>": { "<colId>": 14.5 } },                         // tableId, colId: [a-z0-9-]{1,24}; percent of the table width (3-80)
         "linesMode": "grid" } } }                                                  // lines editor mode of that screen: "grid" or "form" (line by line)
   Limits: 40 screens, 12 splits and 24 tables per screen, 12 panes per split, 40 columns per table, 8192 bytes of JSON. */
var LFPrefs = (function () {
  'use strict';
  var KEY = 'lf.prefs.ui.layout.v1', MAXB = 8192, mem = null, backend = null, timer = null;
  var ID = /^[a-z0-9.-]{1,48}$/, SID = /^[a-z0-9-]{1,24}$/;
  function num(v, lo, hi) { v = +v; return isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v * 10) / 10)) : null; }
  function keys(o, n) { return o && typeof o === 'object' && !Array.isArray(o) ? Object.keys(o).slice(0, n) : []; }
  function sanitize(o) {
    var out = { v: 1, shell: { sidenav: {} }, screens: {} };
    if (!o || typeof o !== 'object') return out;
    var sn = o.shell && o.shell.sidenav;
    if (sn && typeof sn === 'object') {
      if (typeof sn.collapsed === 'boolean') out.shell.sidenav.collapsed = sn.collapsed;
      var w = num(sn.w, 160, 420); if (w != null) out.shell.sidenav.w = Math.round(w);
    }
    keys(o.screens, 40).forEach(function (sid) {
      if (!ID.test(sid)) return; var s = o.screens[sid], r = {}; if (!s || typeof s !== 'object') return;
      keys(s.panes, 12).forEach(function (k) {
        if (!SID.test(k) || !Array.isArray(s.panes[k])) return;
        var a = s.panes[k].slice(0, 12).map(function (x) { return x == null ? null : num(x, 5, 85); });
        if (a.some(function (x) { return x != null; })) (r.panes = r.panes || {})[k] = a;
      });
      keys(s.collapsed, 12).forEach(function (k) {
        if (!SID.test(k) || !Array.isArray(s.collapsed[k])) return;
        var a = s.collapsed[k].slice(0, 12).filter(function (x) { return Number.isInteger(x) && x >= 0 && x < 12; });
        if (a.length) (r.collapsed = r.collapsed || {})[k] = a;
      });
      if (s.linesMode === 'grid' || s.linesMode === 'form') r.linesMode = s.linesMode;
      keys(s.cols, 24).forEach(function (t) {
        if (!SID.test(t)) return; var cs = s.cols[t], c = {};
        keys(cs, 40).forEach(function (cid) { if (SID.test(cid)) { var v = num(cs[cid], 3, 80); if (v != null) c[cid] = v; } });
        if (Object.keys(c).length) (r.cols = r.cols || {})[t] = c;
      });
      if (Object.keys(r).length) out.screens[sid] = r;
    });
    if (JSON.stringify(out).length > MAXB) out.screens = {};
    return out;
  }
  function load() {
    if (mem) return mem;
    var raw = null;
    try { raw = backend && backend.load ? backend.load() : localStorage.getItem(KEY); } catch (e) { raw = null; }
    try { mem = sanitize(raw ? JSON.parse(raw) : null); } catch (e) { mem = sanitize(null); }
    return mem;
  }
  function save() {
    clearTimeout(timer);
    timer = setTimeout(function () {
      var json = JSON.stringify(sanitize(mem));
      try { if (backend && backend.save) backend.save(json); else localStorage.setItem(KEY, json); } catch (e) { /* storage blocked: sizes last for this page only */ }
    }, 400);
  }
  function scr(id) { var m = load(); return m.screens[id] || (m.screens[id] = {}); }
  return {
    sanitize: sanitize, key: KEY, setBackend: function (b) { backend = b; mem = null; },
    get: function () { return load(); },
    json: function () { return JSON.stringify(sanitize(load())); },
    getPanes: function (sid, split) { var s = load().screens[sid]; return s && s.panes && s.panes[split] || null; },
    setPanes: function (sid, split, arr) { var s = scr(sid); (s.panes = s.panes || {})[split] = arr; save(); },
    getCollapsed: function (sid, split) { var s = load().screens[sid]; return s && s.collapsed && s.collapsed[split] || []; },
    setCollapsed: function (sid, split, arr) { var s = scr(sid); s.collapsed = s.collapsed || {}; if (arr.length) s.collapsed[split] = arr; else delete s.collapsed[split]; save(); },
    getCols: function (sid, table) { var s = load().screens[sid]; return s && s.cols && s.cols[table] || null; },
    setCols: function (sid, table, obj) { var s = scr(sid); s.cols = s.cols || {}; if (obj && Object.keys(obj).length) s.cols[table] = obj; else delete s.cols[table]; save(); },
    getLinesMode: function (sid) { var s = load().screens[sid]; return s && s.linesMode || null; },
    setLinesMode: function (sid, m) { var s = scr(sid); if (m === 'grid' || m === 'form') s.linesMode = m; save(); },
    getShell: function () { return load().shell.sidenav; },
    setShell: function (patch) { var m = load(); Object.keys(patch).forEach(function (k) { if (patch[k] == null) delete m.shell.sidenav[k]; else m.shell.sidenav[k] = patch[k]; }); save(); },
    resetScreen: function (sid) { delete load().screens[sid]; save(); },
    flush: function () { clearTimeout(timer); var json = JSON.stringify(sanitize(mem || load())); try { if (backend && backend.save) backend.save(json); else localStorage.setItem(KEY, json); } catch (e) { /* ignore */ } }
  };
})();
/* LFPREFS:end */

/* LFSPLIT:begin ----------------------------------------------------------------------------------------------
   Splitter (lf-split): resizable panes in a CSS grid. The container's grid columns read `var(--lf-pane-N, <default>)`; a splitter
   sets that variable (percent of the container, or px for the side nav). Handles live in a layer (.lf-split-layer, absolutely
   positioned over the container's wrapper .lf-splitwrap) so the container may re-render its content freely: call refresh() after each
   render. Handle: div.lf-splitter[role=separator][aria-orientation=vertical][tabindex=0] with aria-valuenow/min/max (percent of the sized
   pane), aria-label and aria-controls. Mouse, touch (pointer events) and keyboard: Left/Right 1 % (Shift 5 %; side nav 8 px / 32 px),
   Home = smallest, End = largest, Enter = collapse/restore (collapsible pane) or reset, double click = reset to the default.
   attach(container, { id, screen, panes: () => [elements], sized: 'before'|'after', vars: ['--lf-pane-1', ...], unit: 'pct'|'px',
   min: [px,...], flexMin: px, enabled: () => bool, collapsible: [k,...], collapsedSize: px, labels: [text,...], layer: element,
   inside: bool, onCollapse: fn }). */
var LFSplit = (function () {
  'use strict';
  function el(tag, cls) { var e = document.createElement(tag); e.className = cls; return e; }
  function attach(container, o) {
    var vars = o.vars || ['--lf-pane-1'], unit = o.unit || 'pct', sized = o.sized || 'before', flexMin = o.flexMin || 280, collapsible = o.collapsible || [], csz = o.collapsedSize || 0;
    var layer = o.layer || (function () { var l = el('div', 'lf-split-layer'); (o.inside ? container : container.parentNode).appendChild(l); return l; })();
    var handles = [], sizes = [], collapsed = {}, drag = null, self = {};
    function scr() { return typeof o.screen === 'function' ? o.screen() : o.screen; }
    function stored() {
      if (o.shell) { var s = LFPrefs.getShell(); sizes = [s.w != null ? s.w : null]; collapsed = s.collapsed ? { 0: true } : {}; }
      else { var p = LFPrefs.getPanes(scr(), o.id); sizes = vars.map(function (_, i) { return p && p[i] != null ? p[i] : null; }); collapsed = {}; LFPrefs.getCollapsed(scr(), o.id).forEach(function (k) { collapsed[k] = true; }); }
    }
    function persist() {
      if (o.shell) { LFPrefs.setShell({ w: sizes[0] != null ? Math.round(sizes[0]) : null, collapsed: collapsed[0] ? true : null }); return; }
      LFPrefs.setPanes(scr(), o.id, sizes.slice()); LFPrefs.setCollapsed(scr(), o.id, Object.keys(collapsed).filter(function (k) { return collapsed[k]; }).map(Number));
    }
    function cw() { var cs = getComputedStyle(container); return container.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight); }
    function paneOf(k) { var p = o.panes(), i = sized === 'after' ? k + 1 : k; return p[i]; }
    function apply() {
      vars.forEach(function (v, k) {
        if (collapsed[k]) container.style.setProperty(v, csz + 'px');
        else if (sizes[k] != null) container.style.setProperty(v, unit === 'px' ? sizes[k] + 'px' : sizes[k] + '%');
        else container.style.removeProperty(v);
        var pn = paneOf(k); if (pn) pn.classList.toggle('is-collapsed', !!collapsed[k] && csz === 0);
      });
      if (o.onCollapse) o.onCollapse(collapsed);
    }
    function limits(k) { // [min, max] of the sized pane in px
      var W = cw(), panes = o.panes(), gap = 16, others = 0, n = panes.length;
      panes.forEach(function (p, i) { var idx = sized === 'after' ? i - 1 : i; if (idx !== k && idx >= 0 && idx < vars.length && p) others += p.getBoundingClientRect().width; });
      var min = (o.min && o.min[k]) || 160, max = unit === 'px' ? (o.max && o.max[k]) || 420 : Math.max(min, W - others - gap * (n - 1) - flexMin);
      return [min, Math.max(min, max)];
    }
    function px2val(px) { return unit === 'px' ? Math.round(px) : Math.round(px / cw() * 1000) / 10; }
    function set(k, px, final) {
      var l = limits(k); px = Math.min(l[1], Math.max(l[0], px)); collapsed[k] = false; sizes[k] = px2val(px); apply(); place();
      if (final) persist();
    }
    function curPx(k) { var p = paneOf(k); return p ? p.getBoundingClientRect().width : 0; }
    function reset(k) { sizes[k] = null; collapsed[k] = false; apply(); place(); persist(); }
    function toggle(k) { collapsed[k] = !collapsed[k]; apply(); place(); persist(); }
    function build() {
      var want = o.enabled() ? o.panes().length - 1 : 0; want = Math.max(0, Math.min(want, vars.length));
      while (handles.length > want) { handles.pop().remove(); }
      while (handles.length < want) {
        (function (k) {
          var h = el('div', 'lf-splitter'); h.setAttribute('role', 'separator'); h.setAttribute('aria-orientation', 'vertical'); h.tabIndex = 0; h.setAttribute('data-k', k);
          h.innerHTML = '<span class="lf-splitter__line"></span>' + (collapsible.indexOf(k) >= 0 ? '<button type="button" class="lf-splitter__btn" tabindex="-1"><svg class="lf-icon" aria-hidden="true"><use href="#i-chevrons-left"/></svg></button>' : '');
          h.addEventListener('pointerdown', function (e) { if (e.target.closest('.lf-splitter__btn')) return; e.preventDefault(); try { h.setPointerCapture(e.pointerId); } catch (x) { /* synthetic event */ } drag = { k: k, x: e.clientX, w: curPx(k), h: h }; h.classList.add('is-drag'); document.body.classList.add('lf-split-dragging'); });
          h.addEventListener('pointermove', function (e) { if (!drag || drag.h !== h) return; var dx = e.clientX - drag.x; set(k, drag.w + (sized === 'after' ? -dx : dx), false); });
          function end(e) { if (!drag || drag.h !== h) return; drag = null; h.classList.remove('is-drag'); document.body.classList.remove('lf-split-dragging'); persist(); }
          h.addEventListener('pointerup', end); h.addEventListener('pointercancel', end);
          h.addEventListener('dblclick', function (e) { if (e.target.closest('.lf-splitter__btn')) return; reset(k); });
          h.addEventListener('click', function (e) { if (e.target.closest('.lf-splitter__btn')) toggle(k); });
          h.addEventListener('keydown', function (e) {
            var key = e.key, step = unit === 'px' ? (e.shiftKey ? 32 : 8) : cw() * (e.shiftKey ? 0.05 : 0.01), l = limits(k), dir = sized === 'after' ? -1 : 1;
            if (key === 'ArrowRight') { e.preventDefault(); set(k, curPx(k) + dir * step, true); }
            else if (key === 'ArrowLeft') { e.preventDefault(); set(k, curPx(k) - dir * step, true); }
            else if (key === 'Home') { e.preventDefault(); set(k, l[0], true); }
            else if (key === 'End') { e.preventDefault(); set(k, l[1], true); }
            else if (key === 'Enter') { e.preventDefault(); if (collapsible.indexOf(k) >= 0) toggle(k); else reset(k); }
          });
          layer.appendChild(h); handles.push(h);
        })(handles.length);
      }
    }
    function place() {
      var panes = o.panes(), L = layer.getBoundingClientRect();
      handles.forEach(function (h, k) {
        var a = panes[k], b = panes[k + 1]; if (!a || !b) { h.hidden = true; return; } h.hidden = false;
        var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect(), gap = Math.max(0, rb.left - ra.right), mid = ra.right + gap / 2;
        var top = Math.min(ra.top, rb.top), bot = Math.max(ra.bottom, rb.bottom);
        if (o.shell) { top = L.top; bot = L.bottom; }
        h.style.left = (mid - L.left) + 'px'; h.style.top = (top - L.top) + 'px'; h.style.height = Math.max(0, bot - top) + 'px';
        var l = limits(k), px = curPx(k), pct = collapsed[k] ? 0 : (unit === 'px' ? px : px / cw() * 100), lo = unit === 'px' ? l[0] : l[0] / cw() * 100, hi = unit === 'px' ? l[1] : l[1] / cw() * 100;
        h.setAttribute('aria-valuenow', Math.round(pct)); h.setAttribute('aria-valuemin', Math.round(lo)); h.setAttribute('aria-valuemax', Math.round(hi));
        var pn = sized === 'after' ? b : a; if (pn) { if (!pn.id) pn.id = (o.id || 'pane') + '-pane-' + k; h.setAttribute('aria-controls', pn.id); }
        h.setAttribute('aria-label', (o.labels && o.labels[k]) || 'Resize'); var btn = h.querySelector('.lf-splitter__btn');
        if (btn) { btn.setAttribute('aria-label', (collapsed[k] ? 'Expand: ' : 'Collapse: ') + ((o.labels && o.labels[k]) || '')); btn.setAttribute('aria-expanded', !collapsed[k]); h.classList.toggle('is-collapsed', !!collapsed[k]); }
      });
    }
    var raf = 0; function later() { cancelAnimationFrame(raf); raf = requestAnimationFrame(place); }
    self.refresh = function () { stored(); build(); apply(); place(); };
    self.place = place; self.reset = function () { for (var k = 0; k < vars.length; k++) { sizes[k] = null; collapsed[k] = false; } apply(); place(); persist(); };
    self.set = set; self.toggle = toggle; self.handles = function () { return handles; }; self.state = function () { return { sizes: sizes.slice(), collapsed: collapsed }; };
    self.destroy = function () { handles.forEach(function (h) { h.remove(); }); window.removeEventListener('scroll', later, true); window.removeEventListener('resize', later); if (ro) ro.disconnect(); };
    window.addEventListener('scroll', later, true); window.addEventListener('resize', later);
    var ro = window.ResizeObserver ? new ResizeObserver(later) : null; if (ro) ro.observe(container);
    self.refresh();
    return self;
  }
  return { attach: attach };
})();
/* LFSPLIT:end */

/* LFCOLRESIZE:begin ------------------------------------------------------------------------------------------
   Resizable table columns (lf-colresize). The table gets class lf-colresize (table-layout: fixed); every resizable <th data-col="id">
   gets a width in PERCENT of the table width (default from opts.cols[].w, or the remembered value) and a handle
   span.lf-colhandle[role=separator][aria-orientation=vertical][tabindex=0][aria-valuenow/min/max]; the LAST resizable column is the
   flexible one and takes the rest (so the table always fills its container and never scrolls sideways). Drag the handle (mouse, touch),
   or focus it and press Left/Right (1 %, Shift 5 %), Home (smallest), End (largest), Enter or double click = default width.
   attach(table, { id, screen, cols: [{id, w, min}], label: (colId) => text, enabled: () => bool }); call again after the table is re-rendered. */
var LFColResize = (function () {
  'use strict';
  function attach(table, o) {
    var ths = Array.prototype.filter.call(table.querySelectorAll('thead th[data-col]'), function (t) { return t.getClientRects().length > 0 && o.cols.some(function (c) { return c.id === t.getAttribute('data-col'); }); });
    var def = {}; o.cols.forEach(function (c) { def[c.id] = c; });
    if (!ths.length && !(o.enabled && !o.enabled())) return;
    if (o.enabled && !o.enabled()) { table.classList.remove('lf-colresize'); ths.forEach(function (t) { t.style.width = ''; var h = t.querySelector('.lf-colhandle'); if (h) h.remove(); }); return; }
    var saved = LFPrefs.getCols(o.screen, o.id) || {}, vals = {}, last = ths[ths.length - 1];
    function tw() { return table.getBoundingClientRect().width || 1; }
    function limits(id) {
      var c = def[id], W = tw(), min = c.min || 3, others = 0;
      ths.forEach(function (t) { var i = t.getAttribute('data-col'); if (i !== id && t !== last) others += vals[i]; });
      var lastMin = Math.max(6, (def[last.getAttribute('data-col')].min || 60) / W * 100);
      return [Math.max(2, min / W * 100), Math.max(min / W * 100, 100 - others - lastMin - fixedPct())];
    }
    function fixedPct() { var W = tw(), s = 0; Array.prototype.forEach.call(table.querySelectorAll('thead th'), function (t) { if (ths.indexOf(t) < 0) s += t.getBoundingClientRect().width / W * 100; }); return s; }
    function paint() { ths.forEach(function (t) { var id = t.getAttribute('data-col'); t.style.width = t === last ? '' : vals[id] + '%'; }); positions(); }
    function positions() { ths.forEach(function (t) { var h = t.querySelector('.lf-colhandle'); if (!h) return; var id = t.getAttribute('data-col'), l = limits(id); h.setAttribute('aria-valuenow', Math.round(t.getBoundingClientRect().width / tw() * 100)); h.setAttribute('aria-valuemin', Math.round(l[0])); h.setAttribute('aria-valuemax', Math.round(l[1])); }); }
    function save() { var s = {}; ths.forEach(function (t) { var id = t.getAttribute('data-col'); if (t !== last && saved[id] != null) s[id] = saved[id]; }); LFPrefs.setCols(o.screen, o.id, s); }
    ths.forEach(function (t) { var id = t.getAttribute('data-col'); vals[id] = saved[id] != null ? saved[id] : def[id].w; });
    // the flexible column needs room: if the remembered widths leave less than 6 %, fall back to the defaults
    var sum = 0; ths.forEach(function (t) { if (t !== last) sum += vals[t.getAttribute('data-col')]; }); if (sum > 94) { ths.forEach(function (t) { vals[t.getAttribute('data-col')] = def[t.getAttribute('data-col')].w; }); saved = {}; }
    table.classList.add('lf-colresize');
    ths.forEach(function (t) {
      var id = t.getAttribute('data-col'); if (t === last) return;
      var old = t.querySelector('.lf-colhandle'); if (old) old.remove();
      var h = document.createElement('span'); h.className = 'lf-colhandle'; h.setAttribute('role', 'separator'); h.setAttribute('aria-orientation', 'vertical'); h.tabIndex = 0;
      h.setAttribute('aria-label', o.label ? o.label(id, t) : 'Resize column');
      var drag = null;
      function setW(pct, fin) { var l = limits(id); pct = Math.round(Math.min(l[1], Math.max(l[0], pct)) * 10) / 10; vals[id] = pct; saved[id] = pct; paint(); if (fin) save(); }
      h.addEventListener('pointerdown', function (e) { e.preventDefault(); e.stopPropagation(); try { h.setPointerCapture(e.pointerId); } catch (x) { /* synthetic event */ } drag = { x: e.clientX, w: t.getBoundingClientRect().width }; h.classList.add('is-drag'); document.body.classList.add('lf-split-dragging'); });
      h.addEventListener('pointermove', function (e) { if (drag) setW((drag.w + e.clientX - drag.x) / tw() * 100, false); });
      function end() { if (!drag) return; drag = null; h.classList.remove('is-drag'); document.body.classList.remove('lf-split-dragging'); save(); }
      h.addEventListener('pointerup', end); h.addEventListener('pointercancel', end);
      h.addEventListener('click', function (e) { e.stopPropagation(); });
      h.addEventListener('dblclick', function (e) { e.stopPropagation(); vals[id] = def[id].w; delete saved[id]; paint(); save(); });
      h.addEventListener('keydown', function (e) {
        var k = e.key, l = limits(id), cur = vals[id], st = e.shiftKey ? 5 : 1;
        if (k === 'ArrowRight') { e.preventDefault(); setW(cur + st, true); } else if (k === 'ArrowLeft') { e.preventDefault(); setW(cur - st, true); }
        else if (k === 'Home') { e.preventDefault(); setW(l[0], true); } else if (k === 'End') { e.preventDefault(); setW(l[1], true); }
        else if (k === 'Enter') { e.preventDefault(); vals[id] = def[id].w; delete saved[id]; paint(); save(); }
        e.stopPropagation();
      });
      t.appendChild(h);
    });
    paint();
    return { reset: function () { ths.forEach(function (t) { var id = t.getAttribute('data-col'); vals[id] = def[id].w; }); saved = {}; paint(); save(); }, values: function () { return vals; } };
  }
  return { attach: attach };
})();
/* LFCOLRESIZE:end */

/* LFSHELL:begin ----------------------------------------------------------------------------------------------
   Side nav of the preview pages, with the user's collapsed flag and width (remembered in LFPrefs.shell). html(current, lang) returns the nav
   markup; mount(app) wires the collapse button and a splitter on its edge. The collapsed nav shows icons only (labels stay for screen readers
   and as tooltips). */
var LFShell = (function () {
  'use strict';
  var TXT = {
    en: { tenant: 'Demo Holding', work: 'Stock', docs: 'Documents', jrn: 'Movements', items: 'Items', org: 'Org units', loc: 'Locations', codes: 'Codes', col: 'Collapse the side nav', exp: 'Expand the side nav', resize: 'Resize the side nav', nav: 'Main' },
    ru: { tenant: 'Demo Holding', work: 'Склад', docs: 'Документы', jrn: 'Движения', items: 'Номенклатура', org: 'Подразделения', loc: 'Места', codes: 'Коды', col: 'Свернуть меню', exp: 'Развернуть меню', resize: 'Ширина меню', nav: 'Главное меню' },
    kk: { tenant: 'Demo Holding', work: 'Қойма', docs: 'Құжаттар', jrn: 'Қозғалыстар', items: 'Тауарлар', org: 'Бөлімшелер', loc: 'Орындар', codes: 'Кодтар', col: 'Мәзірді жию', exp: 'Мәзірді жаю', resize: 'Мәзір ені', nav: 'Негізгі мәзір' }
  };
  var ITEMS = [['docs', 'sheet'], ['jrn', 'history'], ['items', 'package'], ['org', 'network'], ['loc', 'layers'], ['codes', 'barcode']];
  function html(current, lang) {
    var t = TXT[lang] || TXT.en, h = '<div class="lf-sidenav__brand"><span class="lf-sidenav__tenant">' + t.tenant + '</span><span class="lf-sidenav__ws">gate-b-demo</span></div><div class="lf-sidenav__group"><p class="lf-sidenav__label">' + t.work + '</p>';
    ITEMS.forEach(function (x) { h += '<a class="lf-sidenav__item" href="#" title="' + t[x[0]] + '"' + (x[0] === current ? ' aria-current="page"' : '') + '><svg class="lf-icon lf-icon--18" aria-hidden="true"><use href="#i-' + x[1] + '"/></svg><span>' + t[x[0]] + '</span></a>'; });
    return h + '</div><div class="lf-sidenav__foot"><button type="button" class="lf-sidenav__toggle" data-shell="toggle" aria-expanded="true"><svg class="lf-icon" aria-hidden="true"><use href="#i-chevrons-left"/></svg><span></span></button></div>';
  }
  function mount(app, current, lang, opts) {
    var nav = app.querySelector('.lf-sidenav'), t = TXT[lang] || TXT.en;
    nav.innerHTML = html(current, lang); nav.setAttribute('aria-label', t.nav);
    var btn = nav.querySelector('[data-shell=toggle]');
    function state(c) { app.setAttribute('data-nav', c ? 'collapsed' : 'expanded'); btn.setAttribute('aria-expanded', c ? 'false' : 'true'); btn.setAttribute('aria-label', c ? t.exp : t.col); btn.title = c ? t.exp : t.col; btn.querySelector('span').textContent = c ? '' : t.col; }
    if (!app._sp) {
      app._sp = LFSplit.attach(app, { id: 'sidenav', shell: true, unit: 'px', vars: ['--sidenav-width'], sized: 'before', min: [200], max: [360], flexMin: 320, collapsible: [0], collapsedSize: 64, inside: true, labels: [t.resize],
        panes: function () { return [app.querySelector('.lf-sidenav'), app.querySelector('.lf-main')]; }, enabled: function () { return !window.matchMedia || !window.matchMedia('(max-width: 900px)').matches; },
        onCollapse: function (c) { app._state && app._state(!!c[0]); if (opts && opts.onChange) opts.onChange(); } });
    }
    app._state = state; state(!!app._sp.state().collapsed[0]);
    btn.addEventListener('click', function () { app._sp.toggle(0); });
    return app._sp;
  }
  return { html: html, mount: mount, text: TXT };
})();
/* LFSHELL:end */

/* LFLINESEDITOR:begin ----------------------------------------------------------------------------------------
   Lines editor of the document form (lf-lines editor, class lf-le): the lines of a stock document at volume (1 to 1000 lines).
   Two modes, the choice is remembered per screen (LFPrefs.setLinesMode, key screens.<id>.linesMode):
   GRID (grid): rows are edited in place in a table; Enter and Tab move cell to cell, Enter or Tab in the last cell adds a row, arrows move
     between rows (and between cells at the edge of a text), Ctrl+D duplicates, Ctrl+Delete deletes, Excel (tab separated) text pasted into a cell
     fills rows and columns from there. Rows are VIRTUAL: only the visible rows plus an overscan exist in the DOM.
   LINE BY LINE (form): one line in a form (Save and add next, Save and close, Cancel, Delete) and the saved lines in a compact table; a click on a
     saved line edits it. This is the mode that works on a phone (under 700 px the grid is not offered).
   Both: a scan field (a code adds a line or adds 1 to the line of the same item), search inside the lines, per-line validation with a count that
   jumps to the next error, Import lines from Excel (entry and result only), a clear "maximum lines reached" state, and the states loading, error,
   empty, read-only (posted), no permission. The lines panel scrolls INSIDE itself: sticky column header, sticky totals row; the host decides the height
   (the panel fills its parent, which must have a definite height, e.g. flex: 1 and min-height: 0).
   VIRTUAL SCROLL CONTRACT: row height is fixed (token lines-row-h, 40 px; saved lines table lines-row-h-compact, 36 px); first = floor(scrollTop / rowH) - overscan,
   count = ceil(viewHeight / rowH) + 2 * overscan, overscan = 8; spacer rows above and below stand for the rows that are not mounted, so the scroll height is exact.
   FOCUS CONTRACT: the editor keeps {line id, column, caret} of the focused cell; after every re-render the cell is focused again when its row is mounted; when it is not
   (scrolled away), focus moves to the scroll container (tabindex 0, role grid), and Enter, Tab, arrows or F2 there bring the row into view and focus the cell again.
   Keys keep working because they are handled on the container.
   create(host, { id, screen, lang, catalog:[{c,t,u,lot,bc}], lots:{item:[codes]}, lines:[{item,lot,qty,price}], max, readOnly, noPermission, state:'ready'|'loading'|'error',
   mode, onChange(lines), onImport(ctrl), onSave(), t(key) }) returns { getLines, setLines, addLine, scan, importRows, validateAll, nextError, setMode, destroy, ... }. */
var LFLinesEditor = (function () {
  'use strict';
  var T = {
    en: {
      grid: 'Grid', form: 'Line by line', modeLabel: 'Entry mode', gridOff: 'The grid needs a wider screen', scan: 'Scan or type a code, press Enter', scanLabel: 'Scan field', search: 'Search in lines', searchLabel: 'Search in the lines',
      add: 'Add line', imp: 'Import lines from Excel', count: '{n} of {max} lines', countView: '{a} of {n} lines shown', errors1: '1 line has errors', errorsN: '{n} lines have errors', noErrors: 'No errors', next: 'Next error',
      'c.idx': 'Line', 'c.item': 'Item', 'c.lot': 'Lot', 'c.qty': 'Quantity', 'c.price': 'Unit price, ₸', 'c.value': 'Line value, ₸', 'c.act': 'Actions', totals: 'Totals', lines: 'Lines',
      dup: 'Duplicate line {n}', del: 'Delete line {n}', rowErr: 'Line {n} has errors', choose: 'Type a code or a name', pick: 'Search by code or name', noMatch: 'No item matches',
      'e.item': 'choose an item from the list', 'e.unknown': 'no item with this code or name', 'e.lot': 'this item needs a lot', 'e.qty': 'enter a quantity above zero (up to 3 decimals)', 'e.price': 'the price must be a number',
      max: 'Maximum of {max} lines reached', maxText: 'This document has {max} lines, the most it can have. Delete a line, or split the document.', maxHit: 'Line not added: the maximum of {max} lines is reached.',
      scanned: '{code}: quantity {q}', scannedNew: '{code}: line {n} added', scanUnknown: 'Code {code} was not found', scanFull: 'Not added: the maximum of {max} lines is reached',
      pasted: '{n} lines pasted', pastedRefused: '{n} lines pasted, {m} refused (maximum of {max} lines)', imported: '{n} lines added, {m} refused', importedAll: '{n} lines added', reasons: 'Reasons', row: 'row {n}',
      'r.unknown': 'item code "{x}" was not found', 'r.qty': 'quantity must be above zero', 'r.lot': 'a lot is required for this item', 'r.max': 'maximum lines reached',
      newLine: 'New line {n}', editLine: 'Editing line {n}', saveNext: 'Save and add next', saveClose: 'Save and close', cancel: 'Cancel', delete: 'Delete line', saved: 'Line {n} saved', deleted: 'Line {n} deleted',
      'f.item': 'Item', 'f.lot': 'Lot', 'f.qty': 'Quantity', 'f.price': 'Unit price, ₸', 'f.value': 'Line value, ₸', savedLines: 'Saved lines', pickLot: 'Choose a lot',
      'u.pcs': 'pcs', 'u.kg': 'kg', 'u.l': 'l', 'u.pack': 'pack', 'u.pair': 'pair',
      empty: 'No lines yet', emptyText: 'Scan a code, paste rows from Excel, add a line, or import lines from a file.', noMatchLines: 'No line matches', noMatchLinesText: 'Change the search.', clearSearch: 'Clear search',
      loading: 'Loading lines', errTitle: 'Could not load the lines', errText: 'The server did not answer. Nothing was lost. Check the connection and try again.', retry: 'Retry',
      noPerm: 'No access to the lines', noPermText: 'You need the stock permission to see the lines of this document.', readOnly: 'Posted document: the lines cannot be changed.', close: 'Close', gridHint: 'Enter or Tab: next cell. Enter in the last cell adds a row. Ctrl+D: duplicate. Ctrl+Delete: delete. Paste from Excel fills rows.'
    },
    ru: { /* machine draft */
      grid: 'Таблица', form: 'По одной строке', modeLabel: 'Режим ввода', gridOff: 'Таблице нужен более широкий экран', scan: 'Сканируйте или введите код, Enter', scanLabel: 'Поле сканера', search: 'Поиск в строках', searchLabel: 'Поиск в строках',
      add: 'Добавить строку', imp: 'Импорт строк из Excel', count: 'Строк: {n} из {max}', countView: 'Показано {a} из {n} строк', errors1: 'В 1 строке есть ошибки', errorsN: 'Строк с ошибками: {n}', noErrors: 'Ошибок нет', next: 'Следующая ошибка',
      'c.idx': 'Строка', 'c.item': 'Номенклатура', 'c.lot': 'Партия', 'c.qty': 'Количество', 'c.price': 'Цена, ₸', 'c.value': 'Сумма, ₸', 'c.act': 'Действия', totals: 'Итого', lines: 'Строк',
      dup: 'Дублировать строку {n}', del: 'Удалить строку {n}', rowErr: 'В строке {n} есть ошибки', choose: 'Введите код или название', pick: 'Поиск по коду или названию', noMatch: 'Ничего не найдено',
      'e.item': 'выберите номенклатуру из списка', 'e.unknown': 'нет позиции с таким кодом или названием', 'e.lot': 'для этой позиции нужна партия', 'e.qty': 'введите количество больше нуля (до 3 знаков)', 'e.price': 'цена должна быть числом',
      max: 'Достигнут максимум: {max} строк', maxText: 'В документе {max} строк, больше нельзя. Удалите строку или разделите документ.', maxHit: 'Строка не добавлена: достигнут максимум {max} строк.',
      scanned: '{code}: количество {q}', scannedNew: '{code}: добавлена строка {n}', scanUnknown: 'Код {code} не найден', scanFull: 'Не добавлено: достигнут максимум {max} строк',
      pasted: 'Вставлено строк: {n}', pastedRefused: 'Вставлено строк: {n}, отклонено: {m} (максимум {max} строк)', imported: 'Добавлено строк: {n}, отклонено: {m}', importedAll: 'Добавлено строк: {n}', reasons: 'Причины', row: 'строка {n}',
      'r.unknown': 'код позиции «{x}» не найден', 'r.qty': 'количество должно быть больше нуля', 'r.lot': 'для этой позиции нужна партия', 'r.max': 'достигнут максимум строк',
      newLine: 'Новая строка {n}', editLine: 'Правка строки {n}', saveNext: 'Сохранить и добавить следующую', saveClose: 'Сохранить и закрыть', cancel: 'Отмена', delete: 'Удалить строку', saved: 'Строка {n} сохранена', deleted: 'Строка {n} удалена',
      'f.item': 'Номенклатура', 'f.lot': 'Партия', 'f.qty': 'Количество', 'f.price': 'Цена, ₸', 'f.value': 'Сумма, ₸', savedLines: 'Сохранённые строки', pickLot: 'Выберите партию',
      'u.pcs': 'шт', 'u.kg': 'кг', 'u.l': 'л', 'u.pack': 'уп.', 'u.pair': 'пар.',
      empty: 'Строк пока нет', emptyText: 'Отсканируйте код, вставьте строки из Excel, добавьте строку или импортируйте строки из файла.', noMatchLines: 'Строк не найдено', noMatchLinesText: 'Измените поиск.', clearSearch: 'Сбросить поиск',
      loading: 'Загрузка строк', errTitle: 'Не удалось загрузить строки', errText: 'Сервер не ответил. Ничего не потеряно. Проверьте соединение и повторите.', retry: 'Повторить',
      noPerm: 'Нет доступа к строкам', noPermText: 'Чтобы видеть строки этого документа, нужно право на склад.', readOnly: 'Документ проведён: строки менять нельзя.', close: 'Закрыть', gridHint: 'Enter или Tab: следующая ячейка. Enter в последней ячейке добавляет строку. Ctrl+D: дублировать. Ctrl+Delete: удалить. Вставка из Excel заполняет строки.'
    },
    kk: { /* machine draft */
      grid: 'Кесте', form: 'Бір-бірден', modeLabel: 'Енгізу режимі', gridOff: 'Кестеге кеңірек экран керек', scan: 'Сканерлеңіз немесе кодты теріңіз, Enter', scanLabel: 'Сканер өрісі', search: 'Жолдардан іздеу', searchLabel: 'Жолдардан іздеу',
      add: 'Жол қосу', imp: 'Excel-ден жолдарды импорттау', count: 'Жол: {n} / {max}', countView: '{n} жолдың {a} көрсетілген', errors1: '1 жолда қате бар', errorsN: 'Қатесі бар жол: {n}', noErrors: 'Қате жоқ', next: 'Келесі қате',
      'c.idx': 'Жол', 'c.item': 'Тауар', 'c.lot': 'Партия', 'c.qty': 'Саны', 'c.price': 'Бағасы, ₸', 'c.value': 'Сомасы, ₸', 'c.act': 'Әрекеттер', totals: 'Барлығы', lines: 'Жол',
      dup: '{n}-жолды көшіру', del: '{n}-жолды жою', rowErr: '{n}-жолда қате бар', choose: 'Кодты немесе атауды теріңіз', pick: 'Код немесе атау бойынша іздеу', noMatch: 'Ештеңе табылмады',
      'e.item': 'тауарды тізімнен таңдаңыз', 'e.unknown': 'мұндай код немесе атау жоқ', 'e.lot': 'бұл тауарға партия керек', 'e.qty': 'нөлден үлкен санды енгізіңіз (3 таңбаға дейін)', 'e.price': 'баға сан болуы керек',
      max: 'Шекке жетті: {max} жол', maxText: 'Құжатта {max} жол бар, одан артық болмайды. Жолды жойыңыз немесе құжатты бөліңіз.', maxHit: 'Жол қосылмады: {max} жол шегіне жетті.',
      scanned: '{code}: саны {q}', scannedNew: '{code}: {n}-жол қосылды', scanUnknown: '{code} коды табылмады', scanFull: 'Қосылмады: {max} жол шегіне жетті',
      pasted: 'Қойылған жол: {n}', pastedRefused: 'Қойылған жол: {n}, қабылданбаған: {m} (шегі {max} жол)', imported: 'Қосылған жол: {n}, қабылданбаған: {m}', importedAll: 'Қосылған жол: {n}', reasons: 'Себептері', row: '{n}-жол',
      'r.unknown': '«{x}» тауар коды табылмады', 'r.qty': 'саны нөлден үлкен болуы керек', 'r.lot': 'бұл тауарға партия керек', 'r.max': 'жол шегіне жетті',
      newLine: 'Жаңа жол {n}', editLine: '{n}-жолды өңдеу', saveNext: 'Сақтап, келесіні қосу', saveClose: 'Сақтап, жабу', cancel: 'Бас тарту', delete: 'Жолды жою', saved: '{n}-жол сақталды', deleted: '{n}-жол жойылды',
      'f.item': 'Тауар', 'f.lot': 'Партия', 'f.qty': 'Саны', 'f.price': 'Бағасы, ₸', 'f.value': 'Сомасы, ₸', savedLines: 'Сақталған жолдар', pickLot: 'Партияны таңдаңыз',
      'u.pcs': 'дана', 'u.kg': 'кг', 'u.l': 'л', 'u.pack': 'жинақ', 'u.pair': 'жұп',
      empty: 'Жолдар әлі жоқ', emptyText: 'Кодты сканерлеңіз, Excel-ден жолдарды қойыңыз, жол қосыңыз немесе файлдан импорттаңыз.', noMatchLines: 'Жол табылмады', noMatchLinesText: 'Іздеуді өзгертіңіз.', clearSearch: 'Іздеуді тазалау',
      loading: 'Жолдар жүктелуде', errTitle: 'Жолдарды жүктеу мүмкін болмады', errText: 'Сервер жауап бермеді. Ештеңе жоғалған жоқ. Байланысты тексеріп, қайталаңыз.', retry: 'Қайталау',
      noPerm: 'Жолдарға қол жеткізу жоқ', noPermText: 'Бұл құжаттың жолдарын көру үшін қойма құқығы керек.', readOnly: 'Құжат өткізілген: жолдарды өзгертуге болмайды.', close: 'Жабу', gridHint: 'Enter немесе Tab: келесі ұяшық. Соңғы ұяшықта Enter жол қосады. Ctrl+D: көшіру. Ctrl+Delete: жою. Excel-ден қою жолдарды толтырады.'
    }
  };
  var COLS = ['item', 'lot', 'qty', 'price'], OVER = 8, uidn = 0;
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function ico(n, c) { return '<svg class="lf-icon' + (c ? ' ' + c : '') + '" aria-hidden="true"><use href="#i-' + n + '"/></svg>'; }
  function tpl(s, o) { return String(s).replace(/\{(\w+)\}/g, function (_, k) { return o && o[k] != null ? o[k] : ''; }); }
  function dec(s) { var x = String(s == null ? '' : s).replace(/[\s ]/g, '').replace(',', '.'); return /^\d+(\.\d{1,3})?$/.test(x) ? parseFloat(x) : NaN; }

  function create(host, o) {
    o = o || {}; o.screen = o.screen || 'lines-editor';
    var lang = T[o.lang] ? o.lang : 'en', id = o.id || 'lf-le-' + (++uidn), max = o.max || 100, cat = o.catalog || [], lots = o.lots || {};
    var byCode = {}, byBc = {}, byTitle = {};
    cat.forEach(function (x) { byCode[x.c.toUpperCase()] = x; if (x.bc) byBc[x.bc] = x; byTitle[x.t.toLowerCase()] = byTitle[x.t.toLowerCase()] ? null : x; });
    var S = { lines: [], mode: o.mode || LFPrefs.getLinesMode(o.screen) || 'grid', filter: '', showAll: false, focus: null, pop: null, notices: [], scanMsg: '', scanErr: false, live: '', errCursor: -1,
      form: { open: false, idx: -1, draft: null, errs: null }, flash: {}, rowH: 0, rowHc: 0, winKey: '' };
    var listeners = []; function on(t_, ty, fn, op) { t_.addEventListener(ty, fn, op); listeners.push([t_, ty, fn, op]); }
    var ctrl = {}, ro = null, raf = 0, sc, tb, popEl = null, flashTimer = null;
    function t(k, p) { var v = o.t ? o.t(k) : null; return tpl(v != null ? v : (T[lang][k] != null ? T[lang][k] : T.en[k] != null ? T.en[k] : k), p); }

    /* ---------- model ---------- */
    function norm(l) {
      var x = { id: 'l' + (++uidn), item: '', itemText: '', lot: l.lot || '', qty: l.qty == null ? '' : String(l.qty), price: l.price == null ? '' : String(l.price), t: !!l.t };
      var it = l.item ? resolve(l.item) : null; if (it) x.item = it.c; else x.itemText = l.item || l.itemText || '';
      return x;
    }
    function resolve(text) {
      var s = String(text == null ? '' : text).trim(); if (!s) return null;
      var up = s.toUpperCase(); if (byCode[up]) return byCode[up]; if (byBc[s]) return byBc[s];
      var i = s.indexOf(' – '); if (i > 0 && byCode[s.slice(0, i).toUpperCase()]) return byCode[s.slice(0, i).toUpperCase()];
      return byTitle[s.toLowerCase()] || null;
    }
    function search(q) {
      q = String(q || '').trim().toLowerCase(); if (!q) return cat.slice(0, 8);
      var a = cat.filter(function (x) { return x.c.toLowerCase().indexOf(q) >= 0 || x.t.toLowerCase().indexOf(q) >= 0; });
      a.sort(function (x, y) { return (x.c.toLowerCase().indexOf(q) === 0 ? 0 : 1) - (y.c.toLowerCase().indexOf(q) === 0 ? 0 : 1); });
      return a.slice(0, 8);
    }
    function unitOf(l) { var it = l.item && byCode[l.item.toUpperCase()]; return it ? it.u : ''; }
    function tracked(l) { var it = l.item && byCode[l.item.toUpperCase()]; return !!(it && it.lot); }
    function valueOf(l) { var q = dec(l.qty), p = dec(l.price); return isNaN(q) || isNaN(p) ? null : Math.round(q * p * 100) / 100; }
    function validate(l) {
      var e = [];
      if (!l.item) e.push({ col: 'item', k: l.itemText ? 'unknown' : 'item' });
      else if (tracked(l) && !l.lot) e.push({ col: 'lot', k: 'lot' });
      var q = dec(l.qty); if (isNaN(q) || q <= 0) e.push({ col: 'qty', k: 'qty' });
      if (String(l.price).trim() !== '' && isNaN(dec(l.price))) e.push({ col: 'price', k: 'price' });
      return e;
    }
    function shown(l) { return l.t || S.showAll; }
    function errLines() { var r = []; S.lines.forEach(function (l, i) { if (shown(l) && validate(l).length) r.push(i); }); return r; }
    function byId(i) { for (var k = 0; k < S.lines.length; k++) if (S.lines[k].id === i) return k; return -1; }
    function view() { var q = S.filter.trim().toLowerCase(), r = []; S.lines.forEach(function (l, i) { if (!q) { r.push(i); return; } var it = l.item && byCode[l.item.toUpperCase()], hay = ((it ? it.c + ' ' + it.t : l.itemText) + ' ' + l.lot).toLowerCase(); if (hay.indexOf(q) >= 0) r.push(i); }); return r; }
    function fmt(n) { return new Intl.NumberFormat({ en: 'en-US', ru: 'ru-RU', kk: 'kk-KZ' }[lang], { maximumFractionDigits: 2 }).format(n); }
    function disp(l) { var it = l.item && byCode[l.item.toUpperCase()]; return it ? it.c + ' – ' + it.t : l.itemText; }
    function changed() { if (o.onChange) o.onChange(S.lines.map(function (l) { return { item: l.item || l.itemText, lot: l.lot, qty: l.qty, price: l.price }; })); }
    function announce(s) { S.live = s; var el = host.querySelector('.lf-le__live'); if (el) el.textContent = s; }
    function eff() { return host.clientWidth && host.clientWidth < 700 ? 'form' : S.mode; }
    function measure(v) { var d = document.createElement('div'); d.style.cssText = 'position:absolute;visibility:hidden;height:var(' + v + ')'; host.appendChild(d); var h = d.getBoundingClientRect().height || 40; d.remove(); return h; }

    /* ---------- notices ---------- */
    function notice(n) { S.notices = S.notices.filter(function (x) { return x.key !== n.key; }); S.notices.push(n); paintNotices(); announce(n.text); }
    function dismiss(key) { S.notices = S.notices.filter(function (x) { return x.key !== key; }); paintNotices(); }
    function paintNotices() {
      var el = host.querySelector('.lf-le__notices'); if (!el) return; var h = '';
      if (S.lines.length >= max && !o.readOnly) h += '<div class="lf-banner lf-banner--warning" role="status" data-key="max">' + ico('alert', 'lf-icon--18') + '<div><strong>' + esc(t('max', { max: max })) + '</strong><p>' + esc(t('maxText', { max: max })) + '</p></div></div>';
      S.notices.forEach(function (n) {
        h += '<div class="lf-banner lf-banner--' + n.kind + '" role="status" data-key="' + n.key + '">' + ico(n.kind === 'success' ? 'check-circle' : n.kind === 'warning' ? 'alert' : 'info', 'lf-icon--18') + '<div><strong>' + esc(n.text) + '</strong>' +
          (n.details && n.details.length ? '<details class="lf-le__reasons"><summary>' + esc(t('reasons')) + ' (' + n.details.length + ')</summary><ul>' + n.details.slice(0, 50).map(function (d) { return '<li><span class="mono-s">' + esc(t('row', { n: d.row })) + '</span> ' + esc(d.reason) + '</li>'; }).join('') + (n.details.length > 50 ? '<li>…</li>' : '') + '</ul></details>' : '') + '</div>' +
          '<button type="button" class="lf-btn lf-btn--ghost lf-btn--icon" data-le="dismiss" data-key="' + n.key + '" aria-label="' + esc(t('close')) + '">' + ico('x') + '</button></div>';
      });
      el.innerHTML = h;
    }

    /* ---------- adding, changing, removing lines ---------- */
    function addLine(data, afterIdx, quiet) {
      if (S.lines.length >= max) { notice({ key: 'maxhit', kind: 'warning', text: t('maxHit', { max: max }) }); return null; }
      var l = norm(data || {}); if (afterIdx != null && afterIdx >= 0) S.lines.splice(afterIdx + 1, 0, l); else S.lines.push(l);
      if (S.filter) { S.filter = ''; var f = host.querySelector('[data-le="search"]'); if (f) f.value = ''; }
      dismiss('maxhit'); if (!quiet) { changed(); paintAll(); }
      return l;
    }
    function removeLine(i) { var l = S.lines[i]; S.lines.splice(i, 1); dismiss('maxhit'); changed(); announce(t('deleted', { n: i + 1 })); return l; }
    function setField(l, col, val) {
      if (col === 'item') { l.itemText = val; var it = resolve(val); l.item = it ? it.c : ''; if (it && !it.lot) l.lot = ''; if (it) l.itemText = ''; }
      else l[col] = val;
    }

    /* ---------- toolbar ---------- */
    function toolbar() {
      var m = eff(), h = '<div class="lf-le__toolbar">';
      if (!o.readOnly) {
        h += '<div class="lf-seg" role="group" aria-label="' + esc(t('modeLabel')) + '"><button type="button" data-le="mode" data-m="grid" aria-pressed="' + (m === 'grid') + '"' + (host.clientWidth && host.clientWidth < 700 ? ' disabled title="' + esc(t('gridOff')) + '"' : '') + '>' + esc(t('grid')) + '</button><button type="button" data-le="mode" data-m="form" aria-pressed="' + (m === 'form') + '">' + esc(t('form')) + '</button></div>';
        h += '<div class="lf-field lf-le__scanf"><label class="lf-label sr-only" for="' + id + '-scan">' + esc(t('scanLabel')) + '</label><div class="lf-control lf-control--mono"><span class="lf-control__lead">' + ico('barcode') + '</span><input id="' + id + '-scan" data-le="scan" autocomplete="off" spellcheck="false" placeholder="' + esc(t('scan')) + '"></div><div class="lf-error lf-le__scanmsg" hidden></div></div>';
      }
      h += '<div class="lf-field lf-le__searchf"><label class="lf-label sr-only" for="' + id + '-q">' + esc(t('searchLabel')) + '</label><div class="lf-control"><span class="lf-control__lead">' + ico('search') + '</span><input id="' + id + '-q" data-le="search" autocomplete="off" placeholder="' + esc(t('search')) + '" value="' + esc(S.filter) + '"></div></div>';
      h += '<div class="lf-le__tools"><button type="button" class="lf-btn lf-btn--secondary lf-btn--s lf-le__errbtn" data-le="nexterr" hidden></button>' +
        (!o.readOnly ? '<button type="button" class="lf-btn lf-btn--secondary lf-btn--s" data-le="import">' + ico('upload') + esc(t('imp')) + '</button><button type="button" class="lf-btn lf-btn--primary lf-btn--s" data-le="add" id="' + id + '-add">' + ico('plus') + esc(t('add')) + '</button>' : '') +
        '<span class="lf-le__count mono-s" aria-live="polite"></span></div></div>';
      return h;
    }
    function paintToolbar() {
      var n = S.lines.length, v = view().length, c = host.querySelector('.lf-le__count');
      if (c) c.textContent = S.filter.trim() ? t('countView', { a: v, n: n }) : t('count', { n: n, max: max });
      if (c) c.classList.toggle('is-max', n >= max);
      var e = errLines().length, b = host.querySelector('.lf-le__errbtn');
      if (b) { b.hidden = e === 0; b.innerHTML = ico('alert') + esc(e === 1 ? t('errors1') : t('errorsN', { n: e })) + ' · ' + esc(t('next')); b.setAttribute('aria-label', (e === 1 ? t('errors1') : t('errorsN', { n: e })) + '. ' + t('next')); }
      var a = host.querySelector('[data-le="add"]'); if (a) a.disabled = n >= max;
    }

    /* ---------- grid ---------- */
    function gridShell() {
      var h = '<div class="lf-le__scroll" tabindex="-1" role="grid" aria-label="' + esc(t('lines')) + '"><table class="lf-le__table lf-colresize" role="presentation"><thead><tr>' +
        '<th data-col="idx" class="is-idx" scope="col">#</th><th data-col="item" scope="col">' + esc(t('c.item')) + '</th><th data-col="lot" scope="col">' + esc(t('c.lot')) + '</th><th data-col="qty" scope="col" class="is-num">' + esc(t('c.qty')) + '</th><th data-col="price" scope="col" class="is-num">' + esc(t('c.price')) + '</th><th data-col="value" scope="col" class="is-num">' + esc(t('c.value')) + '</th>' + (o.readOnly ? '' : '<th data-col="act" class="is-act" scope="col"><span class="sr-only">' + esc(t('c.act')) + '</span></th>') + '</tr></thead>' +
        '<tbody></tbody><tfoot><tr><td colspan="' + (o.readOnly ? 5 : 5) + '" class="lf-le__tot-l"></td><td class="is-num lf-le__tot-v"></td>' + (o.readOnly ? '' : '<td></td>') + '</tr></tfoot></table></div><div class="lf-le__status" aria-live="polite"><span class="lf-faint">' + esc(o.readOnly ? '' : t('gridHint')) + '</span></div>';
      return h;
    }
    function sp(px, cols) { return px > 0 ? '<tr class="lf-le__sp" aria-hidden="true"><td colspan="' + cols + '" style="height:' + px + 'px"></td></tr>' : ''; }
    function rowHtml(l, i, vi) {
      var errs = shown(l) ? validate(l) : [], bad = {}; errs.forEach(function (e) { bad[e.col] = e.k; });
      var tr = tracked(l), v = valueOf(l), u = unitOf(l), ro_ = o.readOnly, n = i + 1;
      var h = '<tr class="lf-le__row' + (errs.length ? ' is-error' : '') + (S.flash[l.id] ? ' is-flash' : '') + '" role="row" aria-rowindex="' + (vi + 2) + '" data-id="' + l.id + '">' +
        '<td class="is-idx" role="gridcell">' + (errs.length ? '<span class="lf-le__errmark" title="' + esc(t('rowErr', { n: n })) + '" role="img" aria-label="' + esc(t('rowErr', { n: n })) + '">' + ico('alert') + '</span>' : '') + n + '</td>';
      if (ro_) {
        var it = l.item && byCode[l.item.toUpperCase()];
        h += '<td role="gridcell">' + (it ? '<span class="lf-ref lf-ref--trunc"><span class="lf-ref__code">' + esc(it.c) + '</span><span class="lf-ref__sep" aria-hidden="true">–</span><span class="lf-ref__title">' + esc(it.t) + '</span></span>' : esc(l.itemText)) + '</td><td role="gridcell">' + (tr ? esc(l.lot) : '—') + '</td>' +
          '<td class="is-num" role="gridcell">' + esc(fmt(dec(l.qty)) + ' ' + (u ? t('u.' + u) : '')) + '</td><td class="is-num" role="gridcell">' + (l.price === '' ? '—' : esc(fmt(dec(l.price)))) + '</td><td class="is-num" role="gridcell">' + (v == null ? '—' : esc(fmt(v))) + '</td></tr>';
        return h;
      }
      function inp(col, val, extra) { return '<div class="lf-control' + (col === 'qty' || col === 'price' ? ' lf-control--num' : '') + '"><input data-col="' + col + '" data-id="' + l.id + '" autocomplete="off" spellcheck="false" value="' + esc(val) + '" aria-label="' + esc(t('c.' + col) + ', ' + n) + '"' + (bad[col] ? ' aria-invalid="true" title="' + esc(t('c.' + col) + ': ' + t('e.' + bad[col])) + '"' : '') + (extra || '') + '></div>'; }
      h += '<td role="gridcell">' + inp('item', disp(l), ' role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="' + id + '-pop"') + '</td>';
      h += '<td role="gridcell">' + (tr ? inp('lot', l.lot) : '<span class="lf-faint">—</span>') + '</td>';
      h += '<td class="is-num" role="gridcell"><div class="lf-control lf-control--num"><input data-col="qty" data-id="' + l.id + '" inputmode="decimal" autocomplete="off" value="' + esc(l.qty) + '" aria-label="' + esc(t('c.qty') + ', ' + n) + '"' + (bad.qty ? ' aria-invalid="true" title="' + esc(t('c.qty') + ': ' + t('e.qty')) + '"' : '') + '>' + (u ? '<span class="lf-affix">' + esc(t('u.' + u)) + '</span>' : '') + '</div></td>';
      h += '<td class="is-num" role="gridcell">' + inp('price', l.price, ' inputmode="decimal"') + '</td><td class="is-num lf-le__val" role="gridcell">' + (v == null ? '—' : esc(fmt(v))) + '</td>' +
        '<td class="is-act" role="gridcell"><button type="button" class="lf-btn lf-btn--ghost lf-btn--icon lf-btn--s" data-le="dup" data-id="' + l.id + '" tabindex="-1" aria-label="' + esc(t('dup', { n: n })) + '" title="' + esc(t('dup', { n: n })) + '">' + ico('layers') + '</button><button type="button" class="lf-btn lf-btn--ghost lf-btn--icon lf-btn--s" data-le="del" data-id="' + l.id + '" tabindex="-1" aria-label="' + esc(t('del', { n: n })) + '" title="' + esc(t('del', { n: n })) + '">' + ico('x') + '</button></td></tr>';
      return h;
    }
    function renderRows(force) {
      if (!sc) return; var vw = view(), n = vw.length, rh = S.rowH || (S.rowH = measure('--lines-row-h')), cols = o.readOnly ? 6 : 7;
      var viewH = sc.clientHeight || 400, first = Math.max(0, Math.floor(sc.scrollTop / rh) - OVER), cnt = Math.ceil(viewH / rh) + OVER * 2, last = Math.min(n, first + cnt);
      var key = first + ':' + last + ':' + n; if (!force && key === S.winKey) return; S.winKey = key;
      var had = host.contains(document.activeElement) && document.activeElement.closest && document.activeElement.closest('.lf-le__row'), f = S.focus;
      var h = sp(first * rh, cols); for (var k = first; k < last; k++) h += rowHtml(S.lines[vw[k]], vw[k], k); h += sp((n - last) * rh, cols);
      tb.innerHTML = h; sc.setAttribute('aria-rowcount', n + 2);
      if (had && f) { var inpEl = tb.querySelector('input[data-col="' + f.col + '"][data-id="' + f.id + '"]'); if (inpEl) { inpEl.focus({ preventScroll: true }); try { if (f.s != null) inpEl.setSelectionRange(f.s, f.e); } catch (e) { /* not text */ } } else { sc.tabIndex = 0; sc.focus({ preventScroll: true }); } }
      if (!n) tb.innerHTML = '';
      var emp = host.querySelector('.lf-le__emptyview'); if (emp) emp.hidden = n > 0 || S.lines.length === 0;
    }
    function paintTotals() {
      var sum = 0; S.lines.forEach(function (l) { var v = valueOf(l); if (v != null) sum += v; });
      var l = host.querySelector('.lf-le__tot-l'), v = host.querySelector('.lf-le__tot-v'); if (l) l.innerHTML = '<span class="lf-le__totlab">' + esc(t('totals')) + '</span> · <span class="lf-le__totlab">' + esc(t('lines')) + '</span> <span class="mono">' + S.lines.length + '</span>'; if (v) v.textContent = fmt(sum) + ' ₸';
    }
    function ensureVisible(vi) {
      var rh = S.rowH || (S.rowH = measure('--lines-row-h')), hh = (sc.querySelector('thead') || {}).offsetHeight || 0, fh = (sc.querySelector('tfoot') || {}).offsetHeight || 0, top = vi * rh, bot = top + rh, st = sc.scrollTop, vh = sc.clientHeight - hh - fh;
      if (top < st) sc.scrollTop = top; else if (bot > st + vh) sc.scrollTop = bot - vh;
    }
    function focusCell(lineId, col, caret) {
      var i = byId(lineId); if (i < 0) return; var vw = view(), vi = vw.indexOf(i); if (vi < 0) return;
      if (o.readOnly) return; ensureVisible(vi); S.winKey = ''; S.focus = { id: lineId, col: col, s: caret === 'end' ? 999 : 0, e: caret === 'end' ? 999 : 999 }; renderRows(true);
      var el = tb.querySelector('input[data-col="' + col + '"][data-id="' + lineId + '"]'); if (el) { el.focus({ preventScroll: true }); el.select(); }
    }
    function cellsOf(l) { return COLS.filter(function (c) { return c !== 'lot' || tracked(l); }); }
    function move(lineId, col, dir) { // dir: +1 next cell, -1 previous cell, 'down', 'up'
      var i = byId(lineId), vw = view(), vi = vw.indexOf(i), l = S.lines[i], cs = cellsOf(l), ci = cs.indexOf(col), nl, nc;
      if (dir === 1) { if (ci < cs.length - 1) { nl = l; nc = cs[ci + 1]; } else if (vi < vw.length - 1) { nl = S.lines[vw[vi + 1]]; nc = cellsOf(nl)[0]; } else { var a = addLine({}, i); if (!a) return; nl = a; nc = 'item'; } }
      else if (dir === -1) { if (ci > 0) { nl = l; nc = cs[ci - 1]; } else if (vi > 0) { nl = S.lines[vw[vi - 1]]; var c2 = cellsOf(nl); nc = c2[c2.length - 1]; } else return false; }
      else if (dir === 'down') { if (vi >= vw.length - 1) return; nl = S.lines[vw[vi + 1]]; nc = cellsOf(nl).indexOf(col) >= 0 ? col : 'item'; }
      else { if (vi <= 0) return; nl = S.lines[vw[vi - 1]]; nc = cellsOf(nl).indexOf(col) >= 0 ? col : 'item'; }
      focusCell(nl.id, nc); return true;
    }
    function rowStatus(lineId) {
      var el = host.querySelector('.lf-le__status'); if (!el) return; var i = byId(lineId), l = S.lines[i], m = '';
      if (l && shown(l)) m = validate(l).map(function (e) { return t('c.' + e.col) + ': ' + t('e.' + e.k); }).join(' · ');
      el.innerHTML = m ? ico('alert') + '<span>' + esc(t('rowErr', { n: i + 1 }) + ' - ' + m) + '</span>' : '<span class="lf-faint">' + esc(o.readOnly ? '' : t('gridHint')) + '</span>'; el.classList.toggle('is-error', !!m);
    }

    /* ---------- item picker (shared by the grid and the form) ---------- */
    function closePop() { if (popEl) { popEl.remove(); popEl = null; } if (S.pop && S.pop.input) S.pop.input.setAttribute('aria-expanded', 'false'); S.pop = null; }
    function openPop(input, onPick) {
      if (S.pop && S.pop.input !== input) closePop();
      var ex = resolve(input.value), res = ex ? [ex].concat(search('').filter(function (x) { return x.c !== ex.c; })) : search(input.value);
      if (!popEl) { popEl = document.createElement('div'); popEl.className = 'lf-ref-pop lf-le__pop'; popEl.id = id + '-pop'; popEl.setAttribute('role', 'listbox'); popEl.addEventListener('mousedown', function (e) { e.preventDefault(); }); document.body.appendChild(popEl); }
      S.pop = { input: input, results: res, active: res.length ? 0 : -1, onPick: onPick };
      var h = '<div class="lf-ref-pop__list">';
      if (!res.length) h += '<div class="lf-ref-pop__state">' + esc(t('noMatch')) + '</div>';
      res.forEach(function (x, k) { h += '<div class="lf-ref-opt' + (k === 0 ? ' is-active' : '') + '" role="option" id="' + id + '-o' + k + '" data-k="' + k + '"><span class="lf-ref"><span class="lf-ref__code">' + esc(x.c) + '</span><span class="lf-ref__sep" aria-hidden="true">–</span><span class="lf-ref__title">' + esc(x.t) + '</span></span></div>'; });
      popEl.innerHTML = h + '</div>'; input.setAttribute('aria-expanded', 'true'); placePop(input);
      popEl.onclick = function (e) { var op = e.target.closest('.lf-ref-opt'); if (op) { var x = S.pop.results[+op.getAttribute('data-k')]; var cb = S.pop.onPick; closePop(); cb(x); } };
    }
    function placePop(input) { var r = input.getBoundingClientRect(), h = popEl.offsetHeight, below = window.innerHeight - r.bottom, up = h > below && r.top > below; popEl.style.minWidth = Math.max(r.width, 260) + 'px'; popEl.style.left = Math.max(8, Math.min(r.left, window.innerWidth - popEl.offsetWidth - 8)) + 'px'; popEl.style.top = (up ? r.top - h - 4 : r.bottom + 4) + 'px'; }
    function popKey(e) { // returns true when the key was used by the picker
      if (!S.pop) return false; var k = e.key, p = S.pop;
      if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); p.active = Math.max(0, Math.min(p.results.length - 1, p.active + (k === 'ArrowDown' ? 1 : -1))); Array.prototype.forEach.call(popEl.querySelectorAll('.lf-ref-opt'), function (x, i) { x.classList.toggle('is-active', i === p.active); }); p.input.setAttribute('aria-activedescendant', id + '-o' + p.active); return true; }
      if (k === 'Escape') { e.preventDefault(); closePop(); return true; }
      return false;
    }

    /* ---------- grid events ---------- */
    function onGridInput(e) {
      var el = e.target, col = el.getAttribute('data-col'); if (!col) return; var i = byId(el.getAttribute('data-id')), l = S.lines[i]; if (!l) return;
      setField(l, col, el.value);
      if (col === 'item') { S.pop = null; openPop(el, function (x) { setField(l, 'item', x.c); l.t = true; paintAll(); focusCell(l.id, cellsOf(l)[1] || 'qty'); }); S.pop.line = l; }
      var row = el.closest('.lf-le__row'), vc = row && row.querySelector('.lf-le__val'), v = valueOf(l); if (vc) vc.textContent = v == null ? '—' : fmt(v);
      if (shown(l)) { row.classList.toggle('is-error', validate(l).length > 0); }
      paintTotals(); paintToolbar(); changed();
    }
    function onGridKey(e) {
      var el = e.target, k = e.key;
      if (el === sc) { if (S.focus && (k === 'Enter' || k === 'Tab' || k === 'ArrowDown' || k === 'ArrowUp' || k === 'F2')) { e.preventDefault(); focusCell(S.focus.id, S.focus.col); } return; }
      var col = el.getAttribute && el.getAttribute('data-col'); if (!col) return; var lineId = el.getAttribute('data-id'), i = byId(lineId), l = S.lines[i];
      if (popKey(e)) return;
      if (k === 'Enter') { e.preventDefault(); if (S.pop && S.pop.active >= 0 && S.pop.results[S.pop.active]) { var x = S.pop.results[S.pop.active], cb = S.pop.onPick; closePop(); cb(x); return; } finishCell(l, col, el); move(lineId, col, 1); }
      else if (k === 'Tab') { if (e.shiftKey) { var pv = move(lineId, col, -1); if (pv) e.preventDefault(); } else { e.preventDefault(); finishCell(l, col, el); move(lineId, col, 1); } }
      else if (k === 'ArrowDown') { e.preventDefault(); move(lineId, col, 'down'); } else if (k === 'ArrowUp') { e.preventDefault(); move(lineId, col, 'up'); }
      else if (k === 'ArrowRight' && el.selectionStart === el.value.length && el.selectionEnd === el.value.length) { e.preventDefault(); finishCell(l, col, el); move(lineId, col, 1); }
      else if (k === 'ArrowLeft' && el.selectionStart === 0 && el.selectionEnd === 0) { if (move(lineId, col, -1)) e.preventDefault(); }
      else if ((e.ctrlKey || e.metaKey) && (k === 'd' || k === 'D')) { e.preventDefault(); duplicate(lineId, col); }
      else if ((e.ctrlKey || e.metaKey) && k === 'Delete') { e.preventDefault(); remove(lineId, col); }
    }
    function finishCell(l, col, el) { if (col === 'item') { var it = resolve(el.value); if (it) { setField(l, 'item', it.c); } } l.t = true; closePop(); paintToolbar(); rowRefresh(l); }
    function rowRefresh(l) { var row = tb.querySelector('.lf-le__row[data-id="' + l.id + '"]'); if (!row) return; var v = validate(l), ex = row.contains(document.activeElement); if (!ex) { S.winKey = ''; renderRows(true); } else { row.classList.toggle('is-error', shown(l) && v.length > 0); } paintTotals(); }
    function duplicate(lineId, col) { var i = byId(lineId), l = S.lines[i]; var c = addLine({ item: l.item || l.itemText, lot: l.lot, qty: l.qty, price: l.price, t: l.t }, i, true); if (!c) return; changed(); paintToolbar(); paintTotals(); S.winKey = ''; renderRows(true); focusCell(c.id, col || 'item'); announce(t('dup', { n: i + 1 })); }
    function remove(lineId, col) { var i = byId(lineId); removeLine(i); if (!S.lines.length) { paintBody(); paintToolbar(); return; } var vw = view(), nl = S.lines[Math.min(i, S.lines.length - 1)]; S.winKey = ''; paintToolbar(); paintTotals(); renderRows(true); paintNotices(); if (nl) focusCell(nl.id, col || 'item'); }
    function onPaste(e) {
      var el = e.target, col = el.getAttribute && el.getAttribute('data-col'); if (!col || o.readOnly) return;
      var text = (e.clipboardData || window.clipboardData).getData('text'); if (!text || (text.indexOf('\t') < 0 && text.indexOf('\n') < 0)) return;
      e.preventDefault(); var rows = text.replace(/\r/g, '').split('\n'); if (rows.length && rows[rows.length - 1] === '') rows.pop();
      var i0 = byId(el.getAttribute('data-id')), c0 = COLS.indexOf(col), added = 0, refused = 0, ok = 0;
      rows.forEach(function (r, k) {
        var vals = r.split('\t'), idx = i0 + k, l = S.lines[idx];
        if (!l) { l = addLine({}, null, true); if (!l) { refused++; return; } added++; idx = S.lines.length - 1; }
        vals.forEach(function (v, j) { var cn = COLS[c0 + j]; if (!cn) return; if (cn === 'lot' && !tracked(l)) { var itx = cn; } setField(l, cn, v.trim()); if (cn === 'qty' || cn === 'price') l[cn] = v.trim().replace(/[\s ]/g, ''); });
        l.t = true; ok++;
      });
      changed(); S.winKey = ''; paintToolbar(); paintTotals(); renderRows(true);
      notice({ key: 'paste', kind: refused ? 'warning' : 'success', text: refused ? t('pastedRefused', { n: ok, m: refused, max: max }) : t('pasted', { n: ok }) });
    }

    /* ---------- scan ---------- */
    function scan(code) {
      code = String(code || '').trim(); if (!code) return null; var it = resolve(code), msg = host.querySelector('.lf-le__scanmsg');
      function say(text, err) { S.scanMsg = text; S.scanErr = err; if (msg) { msg.hidden = false; msg.className = 'lf-error lf-le__scanmsg' + (err ? '' : ' is-ok'); msg.innerHTML = (err ? ico('alert') : ico('check-circle')) + '<span>' + esc(text) + '</span>'; } announce(text); }
      if (!it) { say(t('scanUnknown', { code: code }), true); return null; }
      var idx = -1; S.lines.forEach(function (l, i) { if (idx < 0 && l.item === it.c) idx = i; });
      var l;
      if (idx >= 0) { l = S.lines[idx]; var q = dec(l.qty); l.qty = String((isNaN(q) ? 0 : q) + 1); l.t = true; say(t('scanned', { code: it.c, q: l.qty }), false); }
      else { l = addLine({ item: it.c, qty: '1', t: true }, null, true); if (!l) { say(t('scanFull', { max: max }), true); return null; } idx = S.lines.length - 1; say(t('scannedNew', { code: it.c, n: idx + 1 }), false); }
      changed(); S.flash = {}; S.flash[l.id] = 1; clearTimeout(flashTimer); flashTimer = setTimeout(function () { S.flash = {}; S.winKey = ''; renderRows(true); renderSaved(true); }, 1500);
      scrollToLine(idx); paintAll(true); return l;
    }
    function scrollToLine(i) { var vw = view(), vi = vw.indexOf(i); if (vi < 0) return; if (sc) { ensureVisible(vi); S.winKey = ''; renderRows(true); } if (S.savedSc) { var rh = S.rowHc || (S.rowHc = measure('--lines-row-h-compact')); S.savedSc.scrollTop = Math.max(0, vi * rh - S.savedSc.clientHeight / 2); S.savedWin = ''; renderSaved(true); } }

    /* ---------- errors ---------- */
    function nextError() {
      var es = errLines(); if (!es.length) return; var cur = S.errCursor, nx = es.filter(function (i) { return i > cur; })[0]; if (nx == null) nx = es[0]; S.errCursor = nx;
      var l = S.lines[nx], e = validate(l)[0];
      if (eff() === 'grid') { S.filter = S.filter && view().indexOf(nx) < 0 ? '' : S.filter; scrollToLine(nx); focusCell(l.id, e.col); rowStatus(l.id); }
      else { openForm(nx, true); }
      announce(t('rowErr', { n: nx + 1 }));
    }
    function validateAll() { S.showAll = true; S.lines.forEach(function (l) { l.t = true; }); paintAll(true); return errLines().length; }

    /* ---------- form mode ---------- */
    function blankDraft() { return { item: '', itemText: '', lot: '', qty: '', price: '' }; }
    function openForm(idx, showErrs) { S.form.open = true; S.form.idx = idx == null ? -1 : idx; S.form.draft = idx == null || idx < 0 ? blankDraft() : (function (l) { return { item: l.item, itemText: l.itemText, lot: l.lot, qty: l.qty, price: l.price }; })(S.lines[idx]); S.form.errs = null; if (showErrs) { var fe = formErrs(S.form.draft); S.form.errs = Object.keys(fe).length ? fe : null; } paintBody(); var f = host.querySelector('[data-f="item"]'); if (f) f.focus(); }
    function formErrs(d) { var e = {}, l = d; if (!l.item) e.item = l.itemText ? 'unknown' : 'item'; else if (tracked(l) && !l.lot) e.lot = 'lot'; var q = dec(l.qty); if (isNaN(q) || q <= 0) e.qty = 'qty'; if (String(l.price).trim() !== '' && isNaN(dec(l.price))) e.price = 'price'; return e; }
    function formHtml() {
      var f = S.form, d = f.draft, n = f.idx >= 0 ? f.idx + 1 : S.lines.length + 1, e = f.errs || {}, it = d.item && byCode[d.item.toUpperCase()], tr = !!(it && it.lot), v = valueOf(d), atMax = f.idx < 0 && S.lines.length >= max;
      function fld(k, body, err) { return '<div class="lf-field' + (err ? ' lf-field--error' : '') + '"><label class="lf-label" for="' + id + '-f-' + k + '">' + esc(t('f.' + k)) + '</label>' + body + (err ? '<div class="lf-error" id="' + id + '-f-' + k + '-e">' + ico('alert') + '<span>' + esc(t('f.' + k) + ': ' + t('e.' + err)) + '</span></div>' : '') + '</div>'; }
      var h = '<form class="lf-le__form" data-le="form" novalidate><h3 class="lf-le__formtitle">' + esc(f.idx >= 0 ? t('editLine', { n: n }) : t('newLine', { n: n })) + '</h3>';
      h += fld('item', '<div class="lf-control"><input id="' + id + '-f-item" data-f="item" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="' + id + '-pop" autocomplete="off" spellcheck="false" placeholder="' + esc(t('choose')) + '" value="' + esc(it ? it.c + ' – ' + it.t : d.itemText) + '"' + (e.item ? ' aria-invalid="true" aria-describedby="' + id + '-f-item-e"' : '') + '></div>', e.item);
      if (tr) { var ls = lots[d.item] || []; h += fld('lot', '<div class="lf-control"><select id="' + id + '-f-lot" data-f="lot"' + (e.lot ? ' aria-invalid="true"' : '') + '><option value="">' + esc(t('pickLot')) + '</option>' + ls.map(function (x) { return '<option' + (d.lot === x ? ' selected' : '') + '>' + esc(x) + '</option>'; }).join('') + '</select>' + ico('chevron-down', 'lf-control__chev') + '</div>', e.lot); }
      h += '<div class="lf-le__formrow">' + fld('qty', '<div class="lf-control lf-control--num"><input id="' + id + '-f-qty" data-f="qty" inputmode="decimal" autocomplete="off" value="' + esc(d.qty) + '"' + (e.qty ? ' aria-invalid="true" aria-describedby="' + id + '-f-qty-e"' : '') + '>' + (it ? '<span class="lf-affix">' + esc(t('u.' + it.u)) + '</span>' : '') + '</div>', e.qty) +
        fld('price', '<div class="lf-control lf-control--num"><input id="' + id + '-f-price" data-f="price" inputmode="decimal" autocomplete="off" value="' + esc(d.price) + '"' + (e.price ? ' aria-invalid="true"' : '') + '></div>', e.price) + '</div>';
      h += '<div class="lf-field"><span class="lf-label">' + esc(t('f.value')) + '</span><span class="lf-le__fval mono">' + (v == null ? '—' : esc(fmt(v))) + '</span></div>';
      h += '<div class="lf-form__actions"><button type="submit" class="lf-btn lf-btn--primary" data-le="saveNext"' + (atMax ? ' disabled' : '') + '>' + esc(t('saveNext')) + '</button><button type="button" class="lf-btn lf-btn--secondary" data-le="saveClose"' + (atMax ? ' disabled' : '') + '>' + esc(t('saveClose')) + '</button><button type="button" class="lf-btn lf-btn--ghost" data-le="cancel">' + esc(t('cancel')) + '</button>' + (f.idx >= 0 ? '<button type="button" class="lf-btn lf-btn--danger lf-btn--s lf-le__del" data-le="formDel">' + esc(t('delete')) + '</button>' : '') + '</div></form>';
      return h;
    }
    function savedHtml() { return '<div class="lf-le__saved"><h3 class="lf-le__formtitle">' + esc(t('savedLines')) + '</h3><div class="lf-le__scroll lf-le__scroll--saved" tabindex="-1"><table class="lf-le__table lf-le__table--saved" role="presentation"><thead><tr><th class="is-idx" scope="col">#</th><th scope="col">' + esc(t('c.item')) + '</th><th class="is-num" scope="col">' + esc(t('c.qty')) + '</th><th class="is-num" scope="col">' + esc(t('c.value')) + '</th></tr></thead><tbody></tbody><tfoot><tr><td colspan="3" class="lf-le__tot-l"></td><td class="is-num lf-le__tot-v"></td></tr></tfoot></table></div></div>'; }
    function renderSaved(force) {
      var s = S.savedSc; if (!s) return; var tbd = s.querySelector('tbody'), vw = view(), n = vw.length, rh = S.rowHc || (S.rowHc = measure('--lines-row-h-compact'));
      var viewH = s.clientHeight || 300, first = Math.max(0, Math.floor(s.scrollTop / rh) - OVER), last = Math.min(n, first + Math.ceil(viewH / rh) + OVER * 2), key = first + ':' + last + ':' + n; if (!force && key === S.savedWin) return; S.savedWin = key;
      var h = sp(first * rh, 4); for (var k = first; k < last; k++) { var i = vw[k], l = S.lines[i], errs = shown(l) ? validate(l) : [], v = valueOf(l), u = unitOf(l), it = l.item && byCode[l.item.toUpperCase()];
        h += '<tr class="lf-le__row lf-le__row--saved' + (o.readOnly ? ' is-ro' : '') + (errs.length ? ' is-error' : '') + (S.form.open && S.form.idx === i ? ' is-sel' : '') + (S.flash[l.id] ? ' is-flash' : '') + '"' + (o.readOnly ? '' : ' data-le="pick" tabindex="0" role="button" aria-label="' + esc(t('editLine', { n: i + 1 })) + '"') + ' data-i="' + i + '"><td class="is-idx">' + (errs.length ? '<span class="lf-le__errmark" role="img" aria-label="' + esc(t('rowErr', { n: i + 1 })) + '">' + ico('alert') + '</span>' : '') + (i + 1) + '</td><td><span class="lf-le__cut">' + (it ? '<b class="mono-s">' + esc(it.c) + '</b> ' + esc(it.t) : esc(l.itemText)) + '</span></td><td class="is-num">' + (isNaN(dec(l.qty)) ? esc(l.qty) : esc(fmt(dec(l.qty)) + ' ' + (u ? t('u.' + u) : ''))) + '</td><td class="is-num">' + (v == null ? '—' : esc(fmt(v))) + '</td></tr>'; }
      h += sp((n - last) * rh, 4); tbd.innerHTML = h;
    }
    function saveForm(close) {
      var f = S.form, d = f.draft; var it = resolve(d.item || d.itemText); if (it) { d.item = it.c; d.itemText = ''; if (!it.lot) d.lot = ''; }
      var e = formErrs(d); f.errs = Object.keys(e).length ? e : null; if (f.errs) { paintBody(); var first = host.querySelector('.lf-le__form [aria-invalid="true"]'); if (first) first.focus(); announce(t('rowErr', { n: f.idx >= 0 ? f.idx + 1 : S.lines.length + 1 })); return; }
      var n;
      if (f.idx >= 0) { var l = S.lines[f.idx]; l.item = d.item; l.itemText = ''; l.lot = d.lot; l.qty = d.qty; l.price = d.price; l.t = true; n = f.idx + 1; }
      else { var nl = addLine({ item: d.item, lot: d.lot, qty: d.qty, price: d.price, t: true }, null, true); if (!nl) return; n = S.lines.length; f.idx = n - 1; }
      changed(); announce(t('saved', { n: n })); S.flash = {}; S.flash[S.lines[n - 1].id] = 1; clearTimeout(flashTimer); flashTimer = setTimeout(function () { S.flash = {}; renderSaved(true); }, 1500);
      if (close) { S.form.open = false; S.form.idx = -1; } else { S.form.idx = -1; S.form.draft = blankDraft(); S.form.errs = null; }
      paintBody(true); paintToolbar(); paintNotices(); if (!close) { var fi = host.querySelector('[data-f="item"]'); if (fi) fi.focus(); } scrollToLine(n - 1);
    }
    function formInput(e) {
      var el = e.target, k = el.getAttribute('data-f'); if (!k) return; var d = S.form.draft;
      if (k === 'item') { d.itemText = el.value; var it = resolve(el.value); d.item = it ? it.c : ''; S.pop = null; openPop(el, function (x) { d.item = x.c; d.itemText = ''; if (!x.lot) d.lot = ''; paintBody(); var q = host.querySelector('[data-f="' + (x.lot ? 'lot' : 'qty') + '"]'); if (q) q.focus(); }); S.pop.line = d; }
      else d[k] = el.value;
      var v = valueOf(d), fv = host.querySelector('.lf-le__fval'); if (fv) fv.textContent = v == null ? '—' : fmt(v);
    }

    /* ---------- composition ---------- */
    function bodyHtml() {
      if (o.noPermission) return '<div class="lf-le__state"><div class="lf-empty">' + ico('alert', 'lf-empty__icon') + '<p class="lf-empty__title">' + esc(t('noPerm')) + '</p><p class="lf-empty__text">' + esc(t('noPermText')) + '</p></div></div>';
      if (o.state === 'loading') { var h = '<div class="lf-le__state lf-le__skel" aria-busy="true" aria-label="' + esc(t('loading')) + '">'; for (var i = 0; i < 9; i++) h += '<span class="lf-skel"></span>'; return h + '</div>'; }
      if (o.state === 'error') return '<div class="lf-le__state"><div class="lf-banner lf-banner--danger" role="alert">' + ico('alert', 'lf-icon--18') + '<div><strong>' + esc(t('errTitle')) + '</strong><p>' + esc(t('errText')) + '</p></div><button type="button" class="lf-btn lf-btn--secondary" data-le="retry">' + esc(t('retry')) + '</button></div></div>';
      var m = eff();
      if (!S.lines.length && !(m === 'form' && S.form.open)) {
        return '<div class="lf-le__state"><div class="lf-empty">' + ico('layers', 'lf-empty__icon') + '<p class="lf-empty__title">' + esc(t('empty')) + '</p><p class="lf-empty__text">' + esc(o.readOnly ? t('readOnly') : t('emptyText')) + '</p>' + (o.readOnly ? '' : '<div class="lf-btn-row"><button type="button" class="lf-btn lf-btn--secondary" data-le="add2">' + ico('plus') + esc(t('add')) + '</button><button type="button" class="lf-btn lf-btn--secondary" data-le="import">' + ico('upload') + esc(t('imp')) + '</button></div>') + '</div></div>';
      }
      if (o.readOnly && m === 'form') return '<div class="lf-le__formwrap lf-le__formwrap--ro">' + savedHtml() + '</div>';
      if (m === 'grid') return gridShell() + '<div class="lf-le__emptyview lf-empty" hidden>' + ico('search', 'lf-empty__icon') + '<p class="lf-empty__title">' + esc(t('noMatchLines')) + '</p><p class="lf-empty__text">' + esc(t('noMatchLinesText')) + '</p><button type="button" class="lf-btn lf-btn--secondary" data-le="clearq">' + esc(t('clearSearch')) + '</button></div>';
      return '<div class="lf-le__formwrap">' + (S.form.open ? '<div class="lf-le__formcol">' + formHtml() + '</div>' : '<div class="lf-le__formcol lf-le__formcol--closed"><button type="button" class="lf-btn lf-btn--primary" data-le="add2"' + (S.lines.length >= max ? ' disabled' : '') + '>' + ico('plus') + esc(t('add')) + '</button></div>') + savedHtml() + '</div>';
    }
    function paintBody(keepScroll) {
      closePop(); var body = host.querySelector('.lf-le__body'); body.innerHTML = bodyHtml(); sc = body.querySelector('.lf-le__scroll:not(.lf-le__scroll--saved)'); tb = sc && sc.querySelector('tbody'); S.savedSc = body.querySelector('.lf-le__scroll--saved'); S.winKey = ''; S.savedWin = '';
      if (sc) { /* column widths are remembered by LFColResize */ LFColResize.attach(sc.querySelector('table'), { id: 'lines-grid', screen: o.screen || 'lines', cols: [{ id: 'item', w: 34, min: 120 }, { id: 'lot', w: 16, min: 80 }, { id: 'qty', w: 13, min: 80 }, { id: 'price', w: 13, min: 80 }, { id: 'value', w: 0, min: 80 }], label: function (cid, th) { return t('c.' + cid); }, enabled: function () { return true; } }); }
      S.hadLines = S.lines.length > 0; paintTotals(); renderRows(true); renderSaved(true); paintNotices();
    }
    function paintAll(keep) { if ((S.lines.length > 0) !== S.hadLines && !(eff() === 'form' && S.form.open)) { paintBody(); paintToolbar(); return; } paintToolbar(); paintTotals(); S.winKey = ''; S.savedWin = ''; renderRows(true); renderSaved(true); paintNotices(); }
    function build() {
      host.classList.add('lf-le'); host.setAttribute('data-mode', eff()); host.setAttribute('data-readonly', o.readOnly ? 'true' : 'false');
      var showTools = !o.noPermission && o.state !== 'loading' && o.state !== 'error';
      host.innerHTML = (showTools ? toolbar() : '') + '<div class="lf-le__notices"></div><div class="lf-le__body"></div><div class="lf-le__live sr-only" aria-live="polite"></div>';
      paintBody(); paintToolbar();
    }

    /* ---------- events ---------- */
    on(host, 'click', function (e) {
      var b = e.target.closest('[data-le]'); if (!b) return; var a = b.getAttribute('data-le');
      if (a === 'mode') { S.mode = b.getAttribute('data-m'); LFPrefs.setLinesMode(o.screen, S.mode); host.setAttribute('data-mode', eff()); build(); }
      else if (a === 'add') { if (eff() === 'grid') { var l = addLine({}); if (l) { scrollToLine(S.lines.length - 1); focusCell(l.id, 'item'); } } else openForm(null); }
      else if (a === 'add2') { if (eff() === 'grid' || o.readOnly) { var l2 = addLine({}); if (l2) { build(); focusCell(l2.id, 'item'); } } else { if (!S.lines.length) { S.form.open = true; build(); openForm(null); } else openForm(null); } }
      else if (a === 'dup') duplicate(b.getAttribute('data-id'), 'item');
      else if (a === 'del') remove(b.getAttribute('data-id'), 'item');
      else if (a === 'nexterr') nextError();
      else if (a === 'import') { if (o.onImport) o.onImport(ctrl); }
      else if (a === 'dismiss') dismiss(b.getAttribute('data-key'));
      else if (a === 'clearq') { S.filter = ''; var q = host.querySelector('[data-le="search"]'); if (q) q.value = ''; paintAll(); }
      else if (a === 'pick') { openForm(+b.getAttribute('data-i')); }
      else if (a === 'saveNext') { e.preventDefault(); saveForm(false); } else if (a === 'saveClose') { e.preventDefault(); saveForm(true); }
      else if (a === 'cancel') { S.form.open = false; S.form.idx = -1; S.form.errs = null; paintBody(); }
      else if (a === 'formDel') { var i = S.form.idx; removeLine(i); S.form.open = false; S.form.idx = -1; paintBody(); paintToolbar(); paintNotices(); }
      else if (a === 'retry') { if (o.onRetry) o.onRetry(); }
    });
    on(host, 'submit', function (e) { e.preventDefault(); saveForm(false); });
    on(host, 'input', function (e) {
      var el = e.target, a = el.getAttribute('data-le');
      if (a === 'search') { S.filter = el.value; S.errCursor = -1; paintAll(); }
      else if (el.hasAttribute('data-col')) onGridInput(e); else if (el.hasAttribute('data-f')) formInput(e);
    });
    on(host, 'change', function (e) { var el = e.target; if (el.getAttribute('data-f') === 'lot') S.form.draft.lot = el.value; });
    on(host, 'keydown', function (e) {
      var el = e.target;
      if (el.getAttribute && el.getAttribute('data-le') === 'scan' && e.key === 'Enter') { e.preventDefault(); scan(el.value); el.value = ''; return; }
      if (el === sc || (el.hasAttribute && el.hasAttribute('data-col'))) { onGridKey(e); return; }
      if (el.getAttribute && el.getAttribute('data-f') === 'item') { if (popKey(e)) return; if (e.key === 'Enter' && S.pop && S.pop.active >= 0 && S.pop.results[S.pop.active]) { e.preventDefault(); var x = S.pop.results[S.pop.active], cb = S.pop.onPick; closePop(); cb(x); } }
      if (el.getAttribute && el.getAttribute('data-le') === 'pick' && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); openForm(+el.getAttribute('data-i')); }
      if (e.key === 'Escape' && S.form.open && eff() === 'form' && !S.pop && el.closest && el.closest('.lf-le__form')) { S.form.open = false; paintBody(); }
    });
    on(host, 'focusin', function (e) {
      var el = e.target; if (el.hasAttribute && el.hasAttribute('data-col')) { S.focus = { id: el.getAttribute('data-id'), col: el.getAttribute('data-col'), s: el.selectionStart, e: el.selectionEnd }; rowStatus(S.focus.id); if (el.select && e.relatedTarget && el.getAttribute('data-col') === 'item') el.select(); }
    });
    on(host, 'focusout', function (e) {
      var el = e.target; if (el.hasAttribute && el.hasAttribute('data-col')) { var l = S.lines[byId(el.getAttribute('data-id'))]; if (l) { if (el.getAttribute('data-col') === 'item') { var it = resolve(el.value); if (it && it.c !== l.item) { setField(l, 'item', it.c); } } l.t = true; setTimeout(function () { var ae = document.activeElement, row = ae && ae.closest && ae.closest('.lf-le__row'); if (!row || row.getAttribute('data-id') !== l.id) { if (!ae || !ae.hasAttribute || !ae.hasAttribute('data-col')) closePop(); if (tb && tb.isConnected) { S.winKey = ''; renderRows(true); paintToolbar(); paintTotals(); } } }, 0); } }
    });
    on(host, 'paste', onPaste);
    on(host, 'scroll', function (e) { if (e.target === sc) { cancelAnimationFrame(raf); raf = requestAnimationFrame(function () { renderRows(false); if (S.pop && S.pop.input) placePop(S.pop.input); }); } else if (e.target === S.savedSc) { cancelAnimationFrame(raf); raf = requestAnimationFrame(function () { renderSaved(false); }); } }, true);
    on(document, 'mousedown', function docDown(e) { if (popEl && !popEl.contains(e.target) && !(S.pop && S.pop.input === e.target)) closePop(); });
    var lastEff = ''; function relayout() { var m = eff(); if (lastEff && m !== lastEff) { host.setAttribute('data-mode', m); build(); } lastEff = m; if (sc) { S.winKey = ''; renderRows(true); } if (S.savedSc) { S.savedWin = ''; renderSaved(true); } }
    if (window.ResizeObserver) { ro = new ResizeObserver(relayout); ro.observe(host); }

    /* ---------- public ---------- */
    ctrl.getLines = function () { return S.lines.map(function (l) { return { item: l.item || l.itemText, lot: l.lot, qty: l.qty, price: l.price }; }); };
    ctrl.setLines = function (arr) { S.lines = (arr || []).slice(0, max).map(norm); S.filter = ''; build(); };
    ctrl.addLine = function (d) { return addLine(d); };
    ctrl.scan = scan; ctrl.validateAll = function () { return validateAll(); }; ctrl.nextError = nextError; ctrl.errorCount = function () { return errLines().length; };
    ctrl.setMode = function (m) { S.mode = m; LFPrefs.setLinesMode(o.screen, m); build(); }; ctrl.mode = function () { return eff(); };
    ctrl.filter = function (q) { S.filter = q; var f = host.querySelector('[data-le="search"]'); if (f) f.value = q; paintAll(); };
    ctrl.scrollToLine = function (i) { scrollToLine(i); };
    ctrl.openForm = openForm; ctrl.focusCell = function (i, col) { focusCell(S.lines[i].id, col || 'item'); };
    ctrl.mountedRows = function () { return tb ? tb.querySelectorAll('.lf-le__row').length : 0; };
    ctrl.rowIds = function () { return S.lines.map(function (l) { return l.id; }); };
    ctrl.importRows = function (rows) { // rows: [{item, lot, qty, price}] from the product's xlsx import; returns { added, refused: [{row, reason}] }
      var added = 0, refused = [];
      rows.forEach(function (r, k) {
        var it = resolve(r.item), n = k + 1, q = dec(r.qty);
        if (!it) { refused.push({ row: n, reason: t('r.unknown', { x: r.item }) }); return; }
        if (isNaN(q) || q <= 0) { refused.push({ row: n, reason: t('r.qty') }); return; }
        if (it.lot && !r.lot) { refused.push({ row: n, reason: t('r.lot') }); return; }
        if (S.lines.length >= max) { refused.push({ row: n, reason: t('r.max') }); return; }
        var l = norm({ item: it.c, lot: it.lot ? r.lot : '', qty: r.qty, price: r.price, t: true }); S.lines.push(l); added++;
      });
      changed(); S.winKey = ''; S.savedWin = ''; paintToolbar(); paintTotals(); renderRows(true); renderSaved(true);
      notice({ key: 'import', kind: refused.length ? 'warning' : 'success', text: refused.length ? t('imported', { n: added, m: refused.length }) : t('importedAll', { n: added }), details: refused });
      return { added: added, refused: refused };
    };
    ctrl.destroy = function () { if (ro) ro.disconnect(); listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2], l[3]); }); listeners = []; clearTimeout(flashTimer); cancelAnimationFrame(raf); closePop(); host.innerHTML = ''; };
    ctrl.resolve = resolve; ctrl.relayout = relayout; ctrl.flush = function () { cancelAnimationFrame(raf); renderRows(false); renderSaved(false); };

    S.lines = (o.lines || []).slice(0, Math.max(max, (o.lines || []).length)).map(norm);
    if (o.showErrors) S.showAll = true;
    build();
    return ctrl;
  }
  return { create: create, strings: T, modes: ['grid', 'form'] };
})();
/* LFLINESEDITOR:end */
