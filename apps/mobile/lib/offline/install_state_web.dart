import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'install_state.dart';

@JS('matchMedia')
external _MediaQueryList _matchMedia(String query);

extension type _MediaQueryList(JSObject _) implements JSObject {
  external bool get matches;
}

@JS('navigator.standalone')
external JSBoolean? get _iosStandalone;

@JS('navigator.storage')
external JSObject? get _storage;

InstallState currentInstallState() {
  try {
    if (_matchMedia('(display-mode: standalone)').matches) {
      return InstallState.installed;
    }
    if (_iosStandalone?.toDart ?? false) return InstallState.installed;
  } on Object {
    // Unknown: treat as a browser tab (the warning is shown).
  }
  return InstallState.browser;
}

/// Best effort `navigator.storage.persist()`; the answer is ignored.
Future<void> requestPersistentStorage() async {
  try {
    final storage = _storage;
    if (storage == null) return;
    await (storage.callMethod<JSPromise<JSAny?>>('persist'.toJS)).toDart;
  } on Object {
    // Not supported: nothing to do.
  }
}
