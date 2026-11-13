/// EN / RU / KK switch shown on the slug-entry screen and in the app bar
/// after sign-in. Applied at once ([userUiLocale] drives a redraw in
/// `app.dart`) and remembered on the device (`writeUiLocalePref`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth.dart' show writeUiLocalePref;
import '../i18n/i18n.dart';
import 'navigation_bootstrap.dart' show tenantTokenStoreProvider;

class LanguageSwitcher extends ConsumerWidget {
  const LanguageSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<String?>(
      valueListenable: userUiLocale,
      builder: (context, _, _) {
        final current = resolveUiLocale();
        return Semantics(
          label: tr('language.label'),
          child: SegmentedButton<String>(
            key: const Key('language-switcher'),
            showSelectedIcon: false,
            segments: [
              for (final code in kEntitiesUiLocales)
                ButtonSegment<String>(
                  value: code,
                  label: Text(tr('language.$code'), key: Key('language-$code')),
                ),
            ],
            selected: {current},
            onSelectionChanged: (picked) {
              final code = picked.first;
              setUserUiLocale(code);
              writeUiLocalePref(ref.read(tenantTokenStoreProvider), code);
            },
          ),
        );
      },
    );
  }
}
