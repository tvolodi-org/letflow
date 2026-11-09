/// The start rule of the browser recorder (PWA M4): `record_web` catches its
/// own start errors and completes normally, so a start counts only when the
/// recorder says it is recording afterwards. Pure Dart, so the rule is
/// tested, not only written in a comment.
library;

Future<bool> startConfirmed(
  Future<void> Function() start,
  Future<bool> Function() isRecording,
) async {
  try {
    await start();
    return await isRecording();
  } on Object {
    return false;
  }
}
