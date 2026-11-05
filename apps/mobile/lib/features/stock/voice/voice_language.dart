/// The language hint of a spoken phrase (REQ-747): the app language when it is
/// Russian or Kazakh, else null and the user chooses.
library;

import '../../../i18n/i18n.dart';

String? appVoiceLang([String? ui]) {
  final l = ui ?? resolveUiLocale();
  return l == 'ru' || l == 'kk' ? l : null;
}
