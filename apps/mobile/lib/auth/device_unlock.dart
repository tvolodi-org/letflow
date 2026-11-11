/// "Unlock with this device" seam (REQ-811). A platform passkey (WebAuthn)
/// with the PRF extension gives a secret only after the device verified the
/// user (fingerprint, face or the device's own PIN: the device decides, the
/// page cannot). That secret is turned into a key (HKDF-SHA-256) that wraps a
/// second copy of the data key, beside the PIN wrapping.
///
/// The browser implementation is `web_device_unlock.dart`; `flutter test` on
/// the VM uses a hand-written fake that records every argument. The challenges
/// of the WebAuthn calls are local only: no server verifies the assertion. The
/// security property is that the PRF output exists only after verification on
/// the bound authenticator, and only that output opens the wrapping.
library;

import 'dart:typed_data';

/// WebAuthn `userVerification` used on BOTH create and get.
const String kDeviceUserVerification = 'required';

/// WebAuthn `authenticatorAttachment`: this device's own authenticator.
const String kDeviceAttachment = 'platform';

/// Length of the random PRF input stored in the record.
const int kPrfEvalInputBytes = 32;

/// HKDF info string of the device key (UTF-8).
const String kDeviceHkdfInfo = 'letflow-pwa-device-unlock-v1';

/// What `create` returns. [prfOutput] is set only when the authenticator
/// evaluated the PRF during creation.
class DeviceCreateResult {
  const DeviceCreateResult({
    required this.credentialId,
    required this.prfEnabled,
    this.prfOutput,
  });

  final Uint8List credentialId;
  final bool prfEnabled;
  final Uint8List? prfOutput;
}

abstract interface class DeviceUnlockAuthenticator {
  /// Whether a user-verifying platform authenticator exists. Never throws.
  Future<bool> isAvailable();

  /// Creates a passkey bound to [rpId]. Throws on cancel or any failure.
  Future<DeviceCreateResult> create({
    required String rpId,
    required Uint8List evalInput,
    required String userVerification,
    required String authenticatorAttachment,
  });

  /// Asserts with the passkey [credentialId]; returns the PRF output for
  /// [evalInput], or null when the authenticator gave none. Throws on cancel
  /// or any failure.
  Future<Uint8List?> get({
    required String rpId,
    required Uint8List credentialId,
    required Uint8List evalInput,
    required String userVerification,
  });
}
