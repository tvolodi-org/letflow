/// Browser implementation of [DeviceUnlockAuthenticator] (REQ-811): WebAuthn
/// platform passkey with the PRF extension. Browser only (imports
/// `package:web`); touches no storage.
///
/// Every security-relevant request parameter (rpId, userVerification,
/// authenticator attachment) arrives as an argument and is passed through;
/// none is hard-coded here. The challenges are random and local only: no
/// server verifies the assertion. Only the PRF output, which exists after the
/// device verified the user on the bound authenticator, opens the wrapping.
///
/// These calls can only be checked on a real device (the "device pass" of
/// `docs/runbooks/mobile-web-pwa-ready-check.md`); CI has no authenticator.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'device_unlock.dart';

Uint8List _random(int n) {
  final arr = Uint8List(n).toJS;
  web.window.crypto.getRandomValues(arr);
  return Uint8List.fromList(arr.toDart);
}

JSObject _obj(Map<String, JSAny> fields) {
  final o = JSObject();
  fields.forEach((k, v) => o.setProperty(k.toJS, v));
  return o;
}

JSObject _cred(int alg) => _obj({'type': 'public-key'.toJS, 'alg': alg.toJS});

JSObject _prfExtension(Uint8List evalInput) => _obj({
  'prf': _obj({
    'eval': _obj({'first': evalInput.toJS}),
  }),
});

Uint8List? _bytes(JSAny? v) {
  if (v == null || v.isUndefinedOrNull) return null;
  if (v.isA<JSArrayBuffer>()) {
    return Uint8List.fromList((v as JSArrayBuffer).toDart.asUint8List());
  }
  if (v.isA<JSUint8Array>()) {
    return Uint8List.fromList((v as JSUint8Array).toDart);
  }
  return null;
}

class WebDeviceUnlock implements DeviceUnlockAuthenticator {
  WebDeviceUnlock();

  JSObject get _credentials => (web.window.navigator as JSObject)
      .getProperty<JSObject>('credentials'.toJS);

  JSAny? _prfFirst(JSObject credential) {
    final results = credential.callMethod<JSObject>(
      'getClientExtensionResults'.toJS,
    );
    final prf = results.getProperty<JSAny?>('prf'.toJS);
    if (prf == null || prf.isUndefinedOrNull) return null;
    return prf as JSObject;
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final ctor = web.window.getProperty<JSAny?>('PublicKeyCredential'.toJS);
      if (ctor == null || ctor.isUndefinedOrNull) return false;
      final r = await (ctor as JSObject)
          .callMethod<JSPromise<JSBoolean>>(
            'isUserVerifyingPlatformAuthenticatorAvailable'.toJS,
          )
          .toDart;
      return r.toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DeviceCreateResult> create({
    required String rpId,
    required Uint8List evalInput,
    required String userVerification,
    required String authenticatorAttachment,
  }) async {
    final options = _obj({
      'publicKey': _obj({
        'rp': _obj({'id': rpId.toJS, 'name': 'Letflow'.toJS}),
        'user': _obj({
          'id': _random(16).toJS,
          'name': 'device'.toJS,
          'displayName': 'This device'.toJS,
        }),
        'challenge': _random(32).toJS,
        'pubKeyCredParams': [_cred(-7), _cred(-257)].toJS,
        'authenticatorSelection': _obj({
          'authenticatorAttachment': authenticatorAttachment.toJS,
          'userVerification': userVerification.toJS,
          'residentKey': 'discouraged'.toJS,
        }),
        'extensions': _prfExtension(evalInput),
      }),
    });
    final cred = await _credentials
        .callMethod<JSPromise<JSObject>>('create'.toJS, options)
        .toDart;
    final id = _bytes(cred.getProperty<JSAny?>('rawId'.toJS));
    if (id == null) throw StateError('no credential id');
    final prf = _prfFirst(cred) as JSObject?;
    final enabled = prf?.getProperty<JSAny?>('enabled'.toJS);
    final results = prf?.getProperty<JSAny?>('results'.toJS);
    Uint8List? out;
    if (results != null && !results.isUndefinedOrNull) {
      out = _bytes((results as JSObject).getProperty<JSAny?>('first'.toJS));
    }
    final isEnabled =
        out != null ||
        (enabled != null &&
            !enabled.isUndefinedOrNull &&
            (enabled as JSBoolean).toDart);
    return DeviceCreateResult(
      credentialId: id,
      prfEnabled: isEnabled,
      prfOutput: out,
    );
  }

  @override
  Future<Uint8List?> get({
    required String rpId,
    required Uint8List credentialId,
    required Uint8List evalInput,
    required String userVerification,
  }) async {
    final options = _obj({
      'publicKey': _obj({
        'challenge': _random(32).toJS,
        'rpId': rpId.toJS,
        'allowCredentials': [
          _obj({'type': 'public-key'.toJS, 'id': credentialId.toJS}),
        ].toJS,
        'userVerification': userVerification.toJS,
        'extensions': _prfExtension(evalInput),
      }),
    });
    final cred = await _credentials
        .callMethod<JSPromise<JSObject>>('get'.toJS, options)
        .toDart;
    final prf = _prfFirst(cred) as JSObject?;
    final results = prf?.getProperty<JSAny?>('results'.toJS);
    if (results == null || results.isUndefinedOrNull) return null;
    return _bytes((results as JSObject).getProperty<JSAny?>('first'.toJS));
  }
}
