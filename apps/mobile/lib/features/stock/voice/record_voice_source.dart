/// [VoiceSource] over a [RecorderPort] (REQ-747). The recording is a temporary
/// file: it is deleted as soon as it is read, and on every failure and cancel
/// path. This is the only file of the feature that touches `dart:io`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'recorder_port.dart';
import 'voice_source.dart';

class RecordVoiceSource implements VoiceSource {
  RecordVoiceSource(this._port, {Future<Directory> Function()? tempDir})
    : _tempDir = tempDir ?? getTemporaryDirectory;

  final RecorderPort _port;
  final Future<Directory> Function() _tempDir;
  String? _path;
  bool _recording = false;

  @override
  Future<VoiceStart> start() async {
    if (_recording) return const VoiceStarted();
    try {
      if (!await _port.hasPermission()) return const VoicePermissionDenied();
      final dir = await _tempDir();
      final path =
          '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
      _path = path;
      await _port.start(path);
      _recording = true;
      return const VoiceStarted();
    } on Object {
      await _deleteQuietly();
      return const VoiceUnavailable();
    }
  }

  @override
  Future<Uint8List?> stop() async {
    if (!_recording) return null;
    _recording = false;
    try {
      final finished = await _port.stop();
      final path = finished ?? _path;
      if (path == null) return null;
      _path = path;
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    } finally {
      await _deleteQuietly();
    }
  }

  @override
  Future<void> cancel() async {
    _recording = false;
    try {
      await _port.cancel();
    } on Object {
      // Nothing to do: the file is deleted below.
    }
    await _deleteQuietly();
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

  Future<void> _deleteQuietly() async {
    final path = _path;
    _path = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // A temp file that cannot be deleted is left to the OS cache cleanup.
    }
  }
}
