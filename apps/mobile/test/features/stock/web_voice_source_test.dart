// PWA M4 V3: the web voice source over a fake browser recorder: refused
// versus unavailable microphone, the codec chosen at run time, and a start
// that the recorder swallowed is never reported as started.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/voice/mic_access.dart';
import 'package:letflow/features/stock/voice/voice_codec.dart';
import 'package:letflow/features/stock/voice/voice_source.dart';
import 'package:letflow/features/stock/voice/web_recorder_port.dart';
import 'package:letflow/features/stock/voice/web_voice_source.dart';

class _FakePort implements WebRecorderPort {
  MicAccess mic = MicAccess.granted;
  Set<VoiceCodec> codecs = {VoiceCodec.opus, VoiceCodec.aacLc};
  bool startResult = true;
  Object? startError;
  Object? stopError;
  Uint8List? recording = Uint8List.fromList([1, 2, 3]);
  final List<VoiceCodec> started = [];
  int micRequests = 0;
  int stops = 0;
  int cancels = 0;
  int disposes = 0;

  @override
  Future<MicAccess> requestMic() async {
    micRequests++;
    return mic;
  }

  @override
  Future<Set<VoiceCodec>> supportedCodecs() async => codecs;

  @override
  Future<bool> start(VoiceCodec codec) async {
    final e = startError;
    if (e != null) throw e;
    started.add(codec);
    return startResult;
  }

  @override
  Future<Uint8List?> stop() async {
    stops++;
    final e = stopError;
    if (e != null) throw e;
    return recording;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    throw StateError('cancel');
  }

  @override
  Future<void> dispose() async {
    disposes++;
    throw StateError('dispose');
  }
}

void main() {
  late _FakePort port;
  late WebVoiceSource source;
  setUp(() {
    port = _FakePort();
    source = WebVoiceSource(port);
  });

  test('V3a: a refused microphone is VoicePermissionDenied', () async {
    port.mic = MicAccess.denied;
    expect(await source.start(), isA<VoicePermissionDenied>());
    expect(port.started, isEmpty);
  });

  test('V3b: no microphone / insecure page is VoiceUnavailable', () async {
    port.mic = MicAccess.unavailable;
    expect(await source.start(), isA<VoiceUnavailable>());
    expect(port.started, isEmpty);
  });

  test('V3c: no supported codec is VoiceUnavailable', () async {
    port.codecs = {};
    expect(await source.start(), isA<VoiceUnavailable>());
    expect(port.started, isEmpty);
  });

  test('V3d: a start that throws is VoiceUnavailable', () async {
    port.startError = StateError('MediaRecorder');
    expect(await source.start(), isA<VoiceUnavailable>());
    expect(await source.stop(), isNull);
  });

  test('V3e: a start that completes but does not record is unavailable, '
      'and a later start is allowed', () async {
    port.startResult = false;
    expect(await source.start(), isA<VoiceUnavailable>());
    expect(await source.stop(), isNull);
    expect(port.stops, 0); // never marked as recording
    port.startResult = true;
    expect(await source.start(), isA<VoiceStarted>());
    expect(port.started, hasLength(2));
  });

  test('V3f: Opus where supported, AAC-LC on Safari', () async {
    expect(await source.start(), isA<VoiceStarted>());
    expect(port.started.single, VoiceCodec.opus);
    final safari = _FakePort()..codecs = {VoiceCodec.aacLc};
    final s = WebVoiceSource(safari);
    expect(await s.start(), isA<VoiceStarted>());
    expect(safari.started.single, VoiceCodec.aacLc);
    expect(s.codec, VoiceCodec.aacLc);
  });

  test('V3g: start is idempotent while recording', () async {
    expect(await source.start(), isA<VoiceStarted>());
    expect(await source.start(), isA<VoiceStarted>());
    expect(port.started, hasLength(1));
    expect(port.micRequests, 1);
  });

  test('V3h: stop returns the bytes; empty and errors are null', () async {
    await source.start();
    expect(await source.stop(), [1, 2, 3]);
    expect(await source.stop(), isNull); // not recording any more

    port.recording = Uint8List(0);
    await source.start();
    expect(await source.stop(), isNull);

    port.stopError = StateError('fetch');
    await source.start();
    expect(await source.stop(), isNull);
  });

  test('V3i: cancel and dispose are safe when the port throws', () async {
    await source.start();
    await source.cancel();
    expect(port.cancels, 1);
    expect(await source.stop(), isNull);
    source.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(port.disposes, 1);
  });

  test('V3j: a requestMic that throws is unavailable', () async {
    final throwing = _ThrowingMicPort();
    expect(await WebVoiceSource(throwing).start(), isA<VoiceUnavailable>());
  });
}

class _ThrowingMicPort extends _FakePort {
  @override
  Future<MicAccess> requestMic() async => throw StateError('getUserMedia');
}
