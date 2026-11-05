/// The narrow face of the recorder plugin (REQ-747). No package import here:
/// tests give [RecordVoiceSource] a fake port, so no test needs a microphone.
library;

abstract class RecorderPort {
  /// True when recording is allowed; asks the OS when not yet decided.
  Future<bool> hasPermission();

  /// Starts recording AAC-LC into the file at [path].
  Future<void> start(String path);

  /// Stops and returns the path of the finished file, or null.
  Future<String?> stop();

  /// Stops and drops the recording.
  Future<void> cancel();

  Future<void> dispose();
}
