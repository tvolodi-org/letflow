// S1 (REQ-747 criterion 6): the temp file of a recording is deleted on every
// path. RecordVoiceSource over a fake recorder port and a temp directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/voice/record_voice_source.dart';
import 'package:letflow/features/stock/voice/voice_source.dart';

import 'fakes_voice.dart';

void main() {
  late Directory dir;
  late FakeRecorderPort port;
  late RecordVoiceSource source;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vs1');
    port = FakeRecorderPort();
    source = RecordVoiceSource(port, tempDir: () async => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  int files() => dir.listSync().length;

  test('S1a: stop returns the bytes and deletes the file', () async {
    expect(await source.start(), isA<VoiceStarted>());
    expect(port.startedPath, endsWith('.m4a'));
    File(port.startedPath!).writeAsBytesSync(port.content);
    expect(await source.stop(), [9, 8, 7]);
    expect(files(), 0);
  });

  test('S1b: a failing stop deletes the file and returns null', () async {
    await source.start();
    File(port.startedPath!).writeAsBytesSync(port.content);
    port.failStop = true;
    expect(await source.stop(), isNull);
    expect(files(), 0);
  });

  test('S1c: a failing start is unavailable and leaves no file', () async {
    port.failStart = true;
    expect(await source.start(), isA<VoiceUnavailable>());
    expect(files(), 0);
  });

  test('S1d: cancel drops the recording and deletes the file', () async {
    await source.start();
    File(port.startedPath!).writeAsBytesSync(port.content);
    await source.cancel();
    expect(port.cancelled, isTrue);
    expect(files(), 0);
  });

  test('S1e: a refused microphone creates no file', () async {
    port.permission = false;
    expect(await source.start(), isA<VoicePermissionDenied>());
    expect(port.startedPath, isNull);
    expect(files(), 0);
  });

  test('S1f: an empty recording is no recording', () async {
    await source.start();
    File(port.startedPath!).writeAsBytesSync(const []);
    expect(await source.stop(), isNull);
    expect(files(), 0);
  });
}
