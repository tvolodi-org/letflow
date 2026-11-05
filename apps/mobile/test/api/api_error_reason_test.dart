// E1 (T-1346, REQ-746 criterion 6): classifyError keeps the stock refusal
// extension keys of a 422 and a 409, and ignores values of the wrong type.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';

RequestOptions _req() =>
    RequestOptions(path: '/api/v1/modules/stock/documents');

void main() {
  test('E1a: 422 carries reason, field, line_no and side', () {
    final e = classifyError(
      _req(),
      statusCode: 422,
      responseBody: {
        'reason': 'not_linked',
        'field': 'to_location_id',
        'line_no': 2,
        'side': 'to',
      },
    );
    expect(e, isA<ValidationError>());
    e as ValidationError;
    expect(e.reason, 'not_linked');
    expect(e.field, 'to_location_id');
    expect(e.lineNo, 2);
    expect(e.side, 'to');
    expect(e.fieldErrors, isEmpty);
  });

  test('E1b: 409 carries the reason', () {
    final e = classifyError(
      _req(),
      statusCode: 409,
      responseBody: {'reason': 'document_not_draft'},
    );
    expect(e, isA<ConflictError>());
    expect((e as ConflictError).reason, 'document_not_draft');
  });

  test('E1c: wrong types and a missing body give nulls', () {
    final e =
        classifyError(
              _req(),
              statusCode: 422,
              responseBody: {
                'reason': 5,
                'field': ['x'],
                'line_no': '3',
                'side': 1,
              },
            )
            as ValidationError;
    expect([e.reason, e.field, e.lineNo, e.side], everyElement(isNull));
    final c = classifyError(_req(), statusCode: 409) as ConflictError;
    expect(c.reason, isNull);
    expect(const ConflictError().reason, isNull);
  });
}
