/// Hand-written fake of the device passkey seam (REQ-811). Records every
/// argument of every call so tests can assert rpId, user verification,
/// attachment and the PRF input.
library;

import 'dart:typed_data';

import 'package:letflow/auth/device_unlock.dart';

/// A recognisable PRF output: tests scan logs and screens for its encodings.
final Uint8List kPrfMarker = Uint8List.fromList(
  List<int>.generate(32, (i) => 0xA0 + (i % 16)),
);

class FakeDeviceUnlock implements DeviceUnlockAuthenticator {
  bool available = true;
  bool prfEnabled = true;

  /// Whether `create` already returns the PRF output.
  bool prfOnCreate = false;
  bool createThrows = false;
  bool getThrows = false;
  bool getReturnsNull = false;
  Uint8List prf = kPrfMarker;
  final Uint8List credentialId = Uint8List.fromList(
    List<int>.generate(24, (i) => i + 1),
  );

  int availableCalls = 0;
  final List<
    ({
      String rpId,
      Uint8List evalInput,
      String userVerification,
      String authenticatorAttachment,
    })
  >
  createCalls = [];
  final List<
    ({
      String rpId,
      Uint8List credentialId,
      Uint8List evalInput,
      String userVerification,
    })
  >
  getCalls = [];

  @override
  Future<bool> isAvailable() async {
    availableCalls++;
    return available;
  }

  @override
  Future<DeviceCreateResult> create({
    required String rpId,
    required Uint8List evalInput,
    required String userVerification,
    required String authenticatorAttachment,
  }) async {
    createCalls.add((
      rpId: rpId,
      evalInput: evalInput,
      userVerification: userVerification,
      authenticatorAttachment: authenticatorAttachment,
    ));
    if (createThrows) throw StateError('cancelled');
    return DeviceCreateResult(
      credentialId: credentialId,
      prfEnabled: prfEnabled,
      prfOutput: prfOnCreate ? Uint8List.fromList(prf) : null,
    );
  }

  @override
  Future<Uint8List?> get({
    required String rpId,
    required Uint8List credentialId,
    required Uint8List evalInput,
    required String userVerification,
  }) async {
    getCalls.add((
      rpId: rpId,
      credentialId: credentialId,
      evalInput: evalInput,
      userVerification: userVerification,
    ));
    if (getThrows) throw StateError('cancelled');
    if (getReturnsNull) return null;
    return Uint8List.fromList(prf);
  }
}
