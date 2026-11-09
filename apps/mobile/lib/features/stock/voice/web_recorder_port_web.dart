/// The browser recorder behind [WebRecorderPort] (PWA M4); compiled only into
/// the web build. With `package_recorder_port.dart` the only files that
/// import `package:record`. Thin on purpose: it needs a browser and a
/// microphone, so the decisions live in pure Dart (`classifyMicError`,
/// `startConfirmed`, `chooseVoiceCodec`) and are tested there; the
/// compile is checked by `flutter build web`.
///
/// Two facts of record_web 1.3.0 shape it: `hasPermission()` turns every
/// `getUserMedia` failure into `false` (refused and no device look the
/// same), so [requestMic] calls `getUserMedia` itself and classifies the
/// `DOMException` name; and `start()` swallows its own errors, so [start]
/// asks `isRecording()` afterwards. The recording is a blob URL that is read
/// once and revoked; nothing is stored.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web/web.dart' as web;

import 'mic_access.dart';
import 'start_confirmed.dart';
import 'voice_codec.dart';
import 'web_recorder_port.dart';

class WebRecorderPortImpl implements WebRecorderPort {
  final AudioRecorder _recorder = AudioRecorder();

  static AudioEncoder _encoder(VoiceCodec codec) => switch (codec) {
    VoiceCodec.opus => AudioEncoder.opus,
    VoiceCodec.aacLc => AudioEncoder.aacLc,
  };

  @override
  Future<MicAccess> requestMic() async {
    final navigator = web.window.navigator;
    // Absent on an insecure (non-HTTPS) page.
    if (!(navigator as JSObject).has('mediaDevices')) {
      return MicAccess.unavailable;
    }
    try {
      final stream = await navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
          .toDart;
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
      return MicAccess.granted;
    } on Object catch (e) {
      return classifyMicError(_errorName(e));
    }
  }

  static String? _errorName(Object e) {
    try {
      return (e as JSObject).getProperty<JSString?>('name'.toJS)?.toDart;
    } on Object {
      return null;
    }
  }

  @override
  Future<Set<VoiceCodec>> supportedCodecs() async {
    final supported = <VoiceCodec>{};
    for (final codec in VoiceCodec.values) {
      try {
        if (await _recorder.isEncoderSupported(_encoder(codec))) {
          supported.add(codec);
        }
      } on Object {
        // An encoder the browser cannot report on is not used.
      }
    }
    return supported;
  }

  @override
  Future<bool> start(VoiceCodec codec) async {
    final ok = await startConfirmed(
      () => _recorder.start(
        RecordConfig(encoder: _encoder(codec), numChannels: 1),
        path: '',
      ),
      _recorder.isRecording,
    );
    if (!ok) {
      try {
        await _recorder.cancel();
      } on Object {
        // Nothing was recording.
      }
    }
    return ok;
  }

  @override
  Future<Uint8List?> stop() async {
    final url = await _recorder.stop();
    if (url == null || url.isEmpty) return null;
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      final buffer = await response.arrayBuffer().toDart;
      return buffer.toDart.asUint8List();
    } finally {
      web.URL.revokeObjectURL(url);
    }
  }

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}
