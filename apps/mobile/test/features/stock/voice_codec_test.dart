// PWA M4 V1/V2/V5/V6: the encoder chosen at run time, the upload label from
// the bytes, refused versus missing microphone, and the start-confirm rule.
// Pure Dart; no browser, no microphone.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/voice/mic_access.dart';
import 'package:letflow/features/stock/voice/start_confirmed.dart';
import 'package:letflow/features/stock/voice/voice_api.dart';
import 'package:letflow/features/stock/voice/voice_codec.dart';

import '../../support/fake_post_capable_http_gateway.dart';

/// The first bytes of an MP4 (Safari, phone) and a WebM (Chrome) file.
final Uint8List _mp4 = Uint8List.fromList([
  0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, //
]);
final Uint8List _webm = Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 1, 2]);

void main() {
  test('V1: Opus first, then AAC-LC, else no voice', () {
    expect(
      chooseVoiceCodec({VoiceCodec.opus, VoiceCodec.aacLc}),
      VoiceCodec.opus,
    );
    expect(chooseVoiceCodec({VoiceCodec.aacLc}), VoiceCodec.aacLc);
    expect(chooseVoiceCodec({VoiceCodec.opus}), VoiceCodec.opus);
    expect(chooseVoiceCodec({}), isNull);
  });

  test('V2a: upload name and type follow the bytes', () {
    expect(audioUploadFormat(_mp4), (
      fileName: 'voice.m4a',
      contentType: 'audio/mp4',
    ));
    expect(audioUploadFormat(_webm), (
      fileName: 'voice.webm',
      contentType: 'audio/webm',
    ));
    for (final other in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
    ]) {
      expect(audioUploadFormat(other), (
        fileName: 'voice.m4a',
        contentType: 'audio/mp4',
      ));
    }
  });

  test('V2b: a WebM recording is uploaded as voice.webm', () async {
    final gateway = FakePostCapableHttpGateway();
    gateway.postResponseQueue.add(
      ScriptedResponse(data: {'kind': 'count', 'items': <Object>[]}),
    );
    await StockVoiceApi(gateway).draftAudio(_webm, 'en');
    final form = gateway.postCalls.single.data as FormData;
    final part = form.files.single;
    expect(part.key, 'audio');
    expect(part.value.filename, 'voice.webm');
    expect(part.value.contentType.toString(), 'audio/webm');
  });

  test('V5: only a refusal is denied; every other failure is unavailable', () {
    for (final name in [
      'NotAllowedError',
      'PermissionDeniedError',
      'SecurityError',
    ]) {
      expect(classifyMicError(name), MicAccess.denied, reason: name);
    }
    for (final name in [
      'NotFoundError',
      'DevicesNotFoundError',
      'OverconstrainedError',
      'NotReadableError',
      'AbortError',
      'TypeError',
      null,
      'Weird',
    ]) {
      expect(classifyMicError(name), MicAccess.unavailable, reason: '$name');
    }
  });

  test('V6: a start counts only when the recorder reports recording', () async {
    Future<void> ok() async {}
    Future<void> boom() async => throw StateError('start');
    expect(await startConfirmed(ok, () async => false), isFalse);
    expect(await startConfirmed(ok, () async => true), isTrue);
    expect(await startConfirmed(boom, () async => true), isFalse);
    expect(
      await startConfirmed(ok, () async => throw StateError('isRecording')),
      isFalse,
    );
  });
}
