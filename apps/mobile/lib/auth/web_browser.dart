/// Browser-backed seams for the web sign-in (PWA M2, D-112). Imported only
/// by `app_auth_platform_web.dart`.
library;

import 'package:web/web.dart' as web;

import 'kv_store.dart';
import 'web_app_auth_adapter.dart';

class BrowserStorage implements StringStorage {
  BrowserStorage._(this._s);

  /// Persistent: used only through `WebPointerKv`, which accepts one key.
  factory BrowserStorage.persistent() =>
      BrowserStorage._(web.window.localStorage);

  /// Tab-scoped: the one-use pending sign-in record.
  factory BrowserStorage.tab() => BrowserStorage._(web.window.sessionStorage);

  final web.Storage _s;

  @override
  String? getItem(String key) => _s.getItem(key);

  @override
  void setItem(String key, String value) => _s.setItem(key, value);

  @override
  void removeItem(String key) => _s.removeItem(key);
}

class BrowserLocation implements WebLocation {
  @override
  Uri get current => Uri.parse(web.window.location.href);

  @override
  String get redirectUri {
    final base = Uri.parse(web.document.baseURI);
    final path = base.path.endsWith('/') ? base.path : '${base.path}/';
    return '${base.scheme}://${base.authority}$path';
  }

  @override
  void assign(String url) => web.window.location.assign(url);

  @override
  void replaceState(String url) =>
      web.window.history.replaceState(null, '', url);
}
