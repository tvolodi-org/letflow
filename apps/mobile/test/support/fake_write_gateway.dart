/// Fake [WriteCapableHttpGateway] for the stock document screens: records
/// every call (method, path, query, body) and answers from a script keyed
/// by `METHOD path`. A script entry is a list consumed in order; the last
/// one repeats.
library;

import 'package:dio/dio.dart';
import 'package:letflow/api/api_client.dart';

class RecordedCall {
  RecordedCall(this.method, this.path, this.query, this.data);

  final String method;
  final String path;
  final Map<String, dynamic>? query;
  final Object? data;

  String get key => '$method $path';
}

class FakeWriteGateway implements WriteCapableHttpGateway {
  final List<RecordedCall> calls = [];
  final Map<String, List<Object>> script = {};

  /// Scripts [answers] for `METHOD path`: a value is a 200 body; an
  /// `Exception` is thrown; a function gets the request body and returns the
  /// 200 body.
  void on(String method, String path, List<Object> answers) =>
      script['$method $path'] = [...answers];

  List<RecordedCall> callsTo(String method, String path) =>
      calls.where((c) => c.key == '$method $path').toList();

  Future<Response<dynamic>> _answer(
    String method,
    String path,
    Map<String, dynamic>? query,
    Object? data,
  ) async {
    calls.add(RecordedCall(method, path, query, data));
    final list = script['$method $path'];
    if (list == null || list.isEmpty) {
      throw StateError('FakeWriteGateway: nothing scripted for $method $path');
    }
    final answer = list.length > 1 ? list.removeAt(0) : list.first;
    if (answer is Exception) throw answer;
    if (answer is Object? Function(Object? data)) {
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: answer(data),
      );
    }
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: answer,
    );
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => _answer('GET', path, queryParameters, null);

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError();

  @override
  Future<Response<dynamic>> post(String path, {Object? data}) =>
      _answer('POST', path, null, data);

  @override
  Future<Response<dynamic>> put(String path, {Object? data}) =>
      _answer('PUT', path, null, data);

  @override
  Future<Response<dynamic>> delete(String path) =>
      _answer('DELETE', path, null, null);
}
