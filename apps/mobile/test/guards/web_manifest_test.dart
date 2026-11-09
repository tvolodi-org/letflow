// PWA M1 (D-112): the web/ folder carries an installable manifest and an
// index.html with the iOS tags. Runs from apps/mobile (as CI does).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest.json: name, brand colours, standalone, icons exist', () {
    final m =
        jsonDecode(File('web/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(m['name'], 'Letflow');
    expect(m['short_name'], 'Letflow');
    expect(m['display'], 'standalone');
    expect(m['theme_color'], '#0c6b5f');
    expect(m['background_color'], '#0c6b5f');
    final icons = (m['icons'] as List).cast<Map<String, dynamic>>();
    expect(icons.any((i) => i['sizes'] == '512x512'), isTrue);
    expect(icons.any((i) => i['purpose'] == 'maskable'), isTrue);
    for (final i in icons) {
      expect(
        File('web/${i['src']}').existsSync(),
        isTrue,
        reason: '${i['src']}',
      );
    }
  });

  test('index.html: apple tags, viewport, manifest link, base href', () {
    final h = File('web/index.html').readAsStringSync();
    expect(h, contains('apple-mobile-web-app-capable'));
    expect(h, contains('apple-mobile-web-app-title'));
    expect(h, contains('rel="apple-touch-icon"'));
    expect(h, contains('name="viewport"'));
    expect(h, contains('rel="manifest"'));
    expect(h, contains(r'$FLUTTER_BASE_HREF'));
    final touch = RegExp(
      r'rel="apple-touch-icon" href="([^"]+)"',
    ).firstMatch(h)!.group(1)!;
    expect(File('web/$touch').existsSync(), isTrue);
  });
}
