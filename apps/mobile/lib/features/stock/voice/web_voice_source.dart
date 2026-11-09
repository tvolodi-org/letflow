/// [VoiceSource] for the web build (PWA M4) over a [WebRecorderPort]. The
/// recording stays in memory (a blob read once and released); nothing is
/// written to the device. The encoder is chosen at run time: Opus where the
/// browser records it, else AAC-LC (Safari records `audio/mp4`).
library;

import 'dart:async';
import 'dart:typed_data';

import 'mic_access.dart';
import 'voice_codec.dart';
import 'voice_source.dart';
import 'web_recorder_port.dart';

class WebVoiceSource implements VoiceSource {
  WebVoiceSource(this._port);

  final WebRecorderPort _port;
  bool _recording = false;

  /// The encoder of the running or last recording (for tests and logs).
  VoiceCodec? codec;

  @override
  Future<VoiceStart> start() async {
    if (_recording) return const VoiceStarted();
    try {
      switch (await _port.requestMic()) {
        case MicAccess.denied:
          return const VoicePermissionDenied();
        case MicAccess.unavailable:
          return const VoiceUnavailable();
        case MicAccess.granted:
          break;
      }
      final chosen = chooseVoiceCodec(await _port.supportedCodecs());
      if (chosen == null) return const VoiceUnavailable();
      if (!await _port.start(chosen)) return const VoiceUnavailable();
      codec = chosen;
      _recording = true;
      return const VoiceStarted();
    } on Object {
      return const VoiceUnavailable();
    }
  }

  @override
  Future<Uint8List?> stop() async {
    if (!_recording) return null;
    _recording = false;
    try {
      final bytes = await _port.stop();
      return bytes == null || bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    _recording = false;
    try {
      await _port.cancel();
    } on Object {
      // Nothing is kept: the blob is dropped with the recorder.
    }
  }

  @override
  void dispose() {
    unawaited(_close());
  }

  Future<void> _close() async {
    if (_recording) await cancel();
    try {
      await _port.dispose();
    } on Object {
      // Disposing is best effort.
    }
  }
}
