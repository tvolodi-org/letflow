/// The only file that imports `package:record` (REQ-747). Thin on purpose:
/// it needs a microphone, so it is covered by analyze and build, not by a
/// unit test.
library;

import 'package:record/record.dart';

import 'recorder_port.dart';

class PackageRecorderPort implements RecorderPort {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 64000,
      sampleRate: 16000,
      numChannels: 1,
    ),
    path: path,
  );

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}
