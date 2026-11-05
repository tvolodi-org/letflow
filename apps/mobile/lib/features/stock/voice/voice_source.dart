/// Where a spoken phrase comes from (REQ-747). The screen sees only this
/// interface; tests replace it with a fake.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package_recorder_port.dart';
import 'record_voice_source.dart';

sealed class VoiceStart {
  const VoiceStart();
}

class VoiceStarted extends VoiceStart {
  const VoiceStarted();
}

/// The user (or the OS) refused the microphone.
class VoicePermissionDenied extends VoiceStart {
  const VoicePermissionDenied();
}

/// No microphone, or the recorder failed to start.
class VoiceUnavailable extends VoiceStart {
  const VoiceUnavailable();
}

abstract class VoiceSource {
  Future<VoiceStart> start();

  /// Stops and returns the recording as bytes, or null when there is none.
  Future<Uint8List?> stop();

  Future<void> cancel();

  void dispose();
}

/// The UI language the voice hint is taken from; null means the device
/// language. Tests override it (the device locale is not settable there).
final Provider<String?> voiceUiLocaleProvider = Provider<String?>(
  (ref) => null,
);

/// The real recorder; tests override this provider with a fake source.
final Provider<VoiceSource> voiceSourceProvider = Provider<VoiceSource>(
  (ref) => RecordVoiceSource(PackageRecorderPort()),
);
