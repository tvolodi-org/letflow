/// Fake [PutCapableHttpGateway] for the stock count tests (D3a): records
/// every call and answers through one handler per test.
library;

import 'package:dio/dio.dart';
import 'package:letflow/api/api_client.dart';

class RecordedCall {
  RecordedCall(this.method, this.path, this.data, this.query);

  final String method;
  final String path;
  final Object? data;
  final Map<String, dynamic>? query;
}

/// Returns the JSON body, or throws an `ApiError` to script a failure.
typedef StockHandler = Object? Function(RecordedCall call);

class FakePutCapableHttpGateway implements PutCapableHttpGateway {
  FakePutCapableHttpGateway(this.handler);

  StockHandler handler;
  final List<RecordedCall> calls = [];

  Iterable<RecordedCall> where(String method, String pathEnd) =>
      calls.where((c) => c.method == method && c.path.endsWith(pathEnd));

  Future<Response<dynamic>> _go(RecordedCall call) async {
    calls.add(call);
    final body = handler(call);
    return Response<dynamic>(
      requestOptions: RequestOptions(path: call.path),
      statusCode: 200,
      data: body,
    );
  }

  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => _go(RecordedCall('GET', path, null, queryParameters));

  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => throw UnimplementedError();

  @override
  Future<Response<dynamic>> post(String path, {Object? data}) =>
      _go(RecordedCall('POST', path, data, null));

  @override
  Future<Response<dynamic>> put(String path, {Object? data}) =>
      _go(RecordedCall('PUT', path, data, null));
}
