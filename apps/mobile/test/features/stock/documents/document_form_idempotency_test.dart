// REQ-849: idempotency keys on save and issue (DocFormController).
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/api/client_key.dart';
import 'package:letflow/features/stock/documents/document_draft.dart';
import 'package:letflow/features/stock/documents/document_form_controller.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/document_pickers.dart';
import 'package:letflow/features/stock/documents/documents_api.dart';

import '../../../support/fake_write_gateway.dart';
import '../../../support/load_test_catalogue.dart';

const _docs = '/api/v1/modules/stock/documents';
const _t = '2026-11-05T10:00:00+05:00';

DocDraft _newDraft() => DocDraft(
  kind: DocKind.receipt,
  eventTime: _t,
  header: const {'org_unit_id': 'o', 'location_id': 'l', 'responsible_id': 'r'},
  lines: const [DocLine(item: 'i1', uom: 'u1', quantity: '2')],
);

DocDraft _savedDraft(String id) => DocDraft(
  id: id,
  kind: DocKind.receipt,
  eventTime: _t,
  header: const {'org_unit_id': 'o', 'location_id': 'l', 'responsible_id': 'r'},
  lines: const [DocLine(item: 'i1', uom: 'u1', quantity: '2')],
);

DocFormController _controller(FakeWriteGateway gw, DocDraft draft) =>
    DocFormController(
      api: StockDocumentsApi(gw),
      pickers: PickerLoader(gw),
      draft: draft,
    );

void main() {
  setUpAll(loadTestMessageCatalogue);

  late FakeWriteGateway gw;
  setUp(() => gw = FakeWriteGateway());

  test('I1: save of a new draft sends an idempotency-key header', () async {
    gw.on('POST', _docs, [
      (Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'},
    ]);
    final c = _controller(gw, _newDraft());
    await c.save();
    final call = gw.callsTo('POST', _docs).single;
    expect(call.idempotencyKey, isNotNull);
    expect(isClientKey(call.idempotencyKey!), isTrue);
  });

  test('I2: retry after network error on save sends the same key', () async {
    gw.on('POST', _docs, [
      const NetworkUnavailableError(),
      (Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'},
    ]);
    final c = _controller(gw, _newDraft());
    await c.save();
    expect(c.failure, isNotNull);
    // Retry with the same action.
    await c.retry();
    final calls = gw.callsTo('POST', _docs);
    expect(calls, hasLength(2));
    expect(calls[0].idempotencyKey, calls[1].idempotencyKey);
    expect(isClientKey(calls[0].idempotencyKey!), isTrue);
  });

  test('I3: editing the draft produces a new key on save', () async {
    gw.on('POST', _docs, [
      (Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'},
      (Object? d) => {...(d as Map), 'id': 'd2', 'state': 'draft'},
    ]);
    final c = _controller(gw, _newDraft());
    await c.save();
    final firstKey = gw.callsTo('POST', _docs).single.idempotencyKey;

    // Simulate editing the draft (creates a new controller, same draft).
    final c2 = _controller(gw, _newDraft());
    await c2.save();
    final secondKey = gw.callsTo('POST', _docs).last.idempotencyKey;

    expect(firstKey, isNotNull);
    expect(secondKey, isNotNull);
    expect(firstKey, isNot(secondKey));
  });

  test('I4: issue sends its own idempotency-key (after save)', () async {
    Map<String, dynamic> savedResponse(Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'};
    final issuedResponse = {'id': 'd1', 'kind': 'receipt', 'state': 'issued', 'event_time': _t};
    gw.on('POST', _docs, [savedResponse]);
    gw.on('POST', '$_docs/d1/issue', [issuedResponse]);
    final c = _controller(gw, _newDraft());
    await c.issue();
    final issueCall = gw.callsTo('POST', '$_docs/d1/issue').single;
    final saveCall = gw.callsTo('POST', _docs).single;
    expect(issueCall.idempotencyKey, isNotNull);
    expect(isClientKey(issueCall.idempotencyKey!), isTrue);
    // Save and issue have different keys.
    expect(issueCall.idempotencyKey, isNot(saveCall.idempotencyKey));
  });

  test('I5: retry after network error on issue sends the same issue key', () async {
    Map<String, dynamic> savedResponse(Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'};
    final issuedResponse = {'id': 'd1', 'kind': 'receipt', 'state': 'issued', 'event_time': _t};
    gw.on('POST', _docs, [savedResponse]);
    gw.on('POST', '$_docs/d1/issue', [
      const NetworkUnavailableError(),
      issuedResponse,
    ]);
    final c = _controller(gw, _newDraft());
    await c.issue();
    expect(c.failure, isNotNull);
    await c.retry();
    final issueCalls = gw.callsTo('POST', '$_docs/d1/issue');
    expect(issueCalls, hasLength(2));
    expect(issueCalls[0].idempotencyKey, issueCalls[1].idempotencyKey);
    expect(isClientKey(issueCalls[0].idempotencyKey!), isTrue);
  });

  test('I6: issue on already-saved draft sends key without prior save', () async {
    final issuedResponse = {'id': 'd1', 'kind': 'receipt', 'state': 'issued', 'event_time': _t};
    gw.on('POST', '$_docs/d1/issue', [issuedResponse]);
    final c = _controller(gw, _savedDraft('d1'));
    await c.issue();
    final issueCall = gw.callsTo('POST', '$_docs/d1/issue').single;
    expect(issueCall.idempotencyKey, isNotNull);
    expect(isClientKey(issueCall.idempotencyKey!), isTrue);
    // No save was made.
    expect(gw.callsTo('POST', _docs), isEmpty);
  });

  test('I7: changing draft (setField) resets the save key', () async {
    gw.on('POST', _docs, [
      const NetworkUnavailableError(),
      (Object? d) => {...(d as Map), 'id': 'd1', 'state': 'draft'},
    ]);
    final c = _controller(gw, _newDraft());
    await c.save(); // fails, _saveKey set
    final firstKey = gw.callsTo('POST', _docs).single.idempotencyKey;

    // Edit the draft — _saveKey should reset.
    c.setField('note', 'changed');
    await c.save(); // should use a fresh key
    final secondKey = gw.callsTo('POST', _docs).last.idempotencyKey;

    expect(firstKey, isNotNull);
    expect(secondKey, isNotNull);
    expect(firstKey, isNot(secondKey));
  });
}
