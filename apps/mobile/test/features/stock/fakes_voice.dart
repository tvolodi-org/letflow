// REQ-747: fakes for the voice tests. No microphone, no network.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/features/stock/voice/recorder_port.dart';
import 'package:letflow/features/stock/voice/voice_source.dart';

class FakeVoiceSource implements VoiceSource {
  FakeVoiceSource({this.startResult = const VoiceStarted()});

  VoiceStart startResult;
  Uint8List? recorded = Uint8List.fromList([1, 2, 3]);
  int starts = 0;
  int stops = 0;
  int cancels = 0;

  @override
  Future<VoiceStart> start() async {
    starts++;
    return startResult;
  }

  @override
  Future<Uint8List?> stop() async {
    stops++;
    return recorded;
  }

  @override
  Future<void> cancel() async => cancels++;

  @override
  void dispose() {}
}

class FakeRecorderPort implements RecorderPort {
  bool permission = true;
  bool failStart = false;
  bool failStop = false;
  List<int> content = [9, 8, 7];
  String? startedPath;
  bool cancelled = false;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(String path) async {
    if (failStart) throw StateError('no mic');
    startedPath = path;
  }

  @override
  Future<String?> stop() async {
    if (failStop) throw StateError('stop failed');
    return startedPath;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}

/// A gateway whose voice answer is held until [release] is called.
class HeldGateway implements PostCapableHttpGateway {
  final Completer<Object?> _gate = Completer<Object?>();
  final List<String> paths = [];

  void release(Object? body) => _gate.complete(body);

  @override
  Future<Response<dynamic>> post(String path, {Object? data}) async {
    paths.add(path);
    final body = await _gate.future;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: body,
    );
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError();

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError();
}
