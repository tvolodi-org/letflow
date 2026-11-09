/// The narrow face of the browser recorder (PWA M4). No package import here:
/// tests give [WebVoiceSource] a fake port, so no test needs a browser.
library;

import 'dart:typed_data';

import 'mic_access.dart';
import 'voice_codec.dart';

abstract class WebRecorderPort {
  /// Asks for the microphone (inside the user's tap) and says whether it may
  /// be used, was refused, or cannot be used.
  Future<MicAccess> requestMic();

  /// The encoders this browser can record.
  Future<Set<VoiceCodec>> supportedCodecs();

  /// Starts recording with [codec]; true ONLY when a recording is confirmed
  /// running (the recorder package swallows its own start errors).
  Future<bool> start(VoiceCodec codec);

  /// Stops and returns the recording, or null.
  Future<Uint8List?> stop();

  /// Stops and drops the recording.
  Future<void> cancel();

  Future<void> dispose();
}
