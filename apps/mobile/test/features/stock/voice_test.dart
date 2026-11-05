// REQ-747 (D3c): voice on the count screen and the stock document forms,
// against a fake gateway and a fake voice source. No microphone, no network.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:letflow/features/stock/count_detail_screen.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/documents_providers.dart'
    as docs;
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/features/stock/stock_providers.dart' as counts;
import 'package:letflow/features/stock/voice/voice_api.dart';
import 'package:letflow/features/stock/voice/voice_panel.dart';
import 'package:letflow/features/stock/voice/voice_source.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_put_capable_http_gateway.dart' as put;
import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';
import '../codes/fakes.dart';
import 'fakes_voice.dart';

const _loc = '11111111-1111-4111-8111-111111111111';
const _item = '22222222-2222-4222-8222-222222222222';
const _item2 = '44444444-4444-4444-8444-444444444444';
const _unit = '33333333-3333-4333-8333-333333333333';
const _query = '/api/v1/entities/query';

late FakeVoiceSource voice;
late FakeScanSource scan;
late FakeWriteGateway gw;

Map<String, dynamic> _draft({
  String kind = 'count',
  List<String> items = const [_item],
  String? quantity = '7.5',
  bool withLocation = true,
  bool withTo = false,
  String? notice,
}) => {
  'kind': kind,
  'items': [
    for (final id in items)
      {
        'id': id,
        'code': 'C-$id'.substring(0, 5),
        'name': 'Bolt',
        'base_unit': 'pcs',
      },
  ],
  'location': withLocation ? {'id': _loc, 'code': 'L1', 'name': 'Shelf'} : null,
  'to_location': withTo
      ? {'id': 'location_node-2', 'code': 'L2', 'name': 'Rack'}
      : null,
  'quantity': quantity,
  'transcript': 'seven and a half bolts',
  'dropped': <String>[],
  'notice': ?notice,
};

Map<String, dynamic> _line({int no = 1, String item = _item}) => {
  'line_no': no,
  'location_id': _loc,
  'catalog_item_id': item,
  'unit_ref': _unit,
  'book_quantity': '5.000',
  'counted_quantity': '2.500',
};

String? _ui;

void _ru(WidgetTester tester) => _ui = 'ru';

void _kk(WidgetTester tester) => _ui = 'kk';

void _big(WidgetTester tester, [Size size = const Size(900, 9000)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

// -- count screen -----------------------------------------------------------------

late put.FakePutCapableHttpGateway cg;

Future<void> _count(
  WidgetTester tester, {
  Object? Function(put.RecordedCall)? voiceAnswer,
  String status = 'counting',
  List<Map<String, dynamic>>? lines,
}) async {
  _big(tester);
  cg = put.FakePutCapableHttpGateway((c) {
    if (c.path.contains('/voice/')) return voiceAnswer!(c);
    if (c.method == 'PUT') return {..._line(), 'counted_quantity': '7.5'};
    if (c.path.endsWith('/lines')) {
      return {
        'rows': lines ?? [_line()],
        'next_cursor': null,
      };
    }
    return {'id': 'c1', 'status': status, 'number': 'N-7'};
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        scanSourceProvider.overrideWithValue(scan),
        counts.stockGatewayProvider.overrideWithValue(cg),
        voiceSourceProvider.overrideWithValue(voice),
        voiceUiLocaleProvider.overrideWithValue(_ui),
      ],
      child: const MaterialApp(home: CountDetailScreen(countId: 'c1')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _speak(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('stock-voice-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('stock-voice-stop')));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('stock-voice-text')), text);
  await tester.tap(find.byKey(const Key('stock-voice-text-send')));
  await tester.pumpAndSettle();
}

// -- document form ----------------------------------------------------------------

Object? _queryAnswer(Object? data) {
  final body = data as Map;
  final entity = body['entity_type'] as String;
  final filters = (body['filters'] as List).cast<Map>();
  final byId = filters.where((f) => f['field'] == 'record_id');
  if (byId.isNotEmpty) {
    final id = byId.first['value'] as String;
    return {
      'items': [
        {
          'record_id': id,
          'field_values': {'name': 'Bolt', 'code': 'B', 'base_uom_id': 'uom-9'},
        },
      ],
    };
  }
  return {
    'items': [
      for (final n in [1, 2])
        {
          'record_id': '$entity-$n',
          'field_values': {'name': '$entity $n', 'code': '$entity $n'},
        },
    ],
  };
}

Future<void> _form(WidgetTester tester, String kind) async {
  _big(tester);
  gw.on('POST', _query, [_queryAnswer]);
  final router = GoRouter(
    initialLocation: '$kStockDocumentsPath/new/$kind',
    routes: stockRoutes(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        docs.stockGatewayProvider.overrideWithValue(gw),
        scanSourceProvider.overrideWithValue(scan),
        voiceSourceProvider.overrideWithValue(voice),
        voiceUiLocaleProvider.overrideWithValue(_ui),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String field, String option) async {
  await _tap(tester, field);
  await _tap(tester, 'stock-doc-option-$option');
}

/// Picks every header field of [kind] except the keys voice fills.
Future<void> _pickHeader(
  WidgetTester tester,
  DocKind kind,
  Set<String> skip,
) async {
  for (final f in documentKindSpecs[kind]!.fields) {
    if (skip.contains(f.key)) continue;
    if (f.input == FieldInput.pick) {
      await _pick(tester, 'stock-doc-field-${f.key}', '${f.entity}-1');
    }
  }
}

FilledButton _btn(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(Key(key)));

List<RecordedCall> _writes() => gw.calls
    .where(
      (c) =>
          c.method != 'GET' && !c.path.contains('/voice/') && c.path != _query,
    )
    .toList();

String _msg(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('stock-voice-message'))).data!;

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() {
    voice = FakeVoiceSource();
    scan = FakeScanSource();
    gw = FakeWriteGateway();
    _ui = null;
  });

  group('api layer', () {
    test('F8: buildFileUploadFormData carries extra text fields', () {
      final withFields =
          buildFileUploadFormData(
                bytes: [1, 2],
                fileName: 'a.m4a',
                contentType: 'audio/mp4',
                partName: 'audio',
                fields: {'lang': 'kk'},
              )
              as FormData;
      expect(withFields.fields.map((e) => '${e.key}=${e.value}'), ['lang=kk']);
      expect(withFields.files.single.key, 'audio');
      final plain =
          buildFileUploadFormData(bytes: [1], fileName: 'f', contentType: 'a/b')
              as FormData;
      expect(plain.fields, isEmpty);
      expect(plain.files.single.key, 'file');
    });
  });

  group('requests', () {
    testWidgets('R1/R3/R4: audio goes out once with part, lang; button off', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      expect(find.byKey(const Key('stock-voice-lang-ru')), findsNothing);
      await _speak(tester);
      final call = cg.where('POST', '/voice/draft').single;
      final form = call.data as FormData;
      expect(form.fields.map((e) => '${e.key}=${e.value}'), ['lang=ru']);
      final part = form.files.single;
      expect(part.key, 'audio');
      expect(part.value.filename, 'voice.m4a');
      expect(part.value.contentType.toString(), 'audio/mp4');
      expect(await part.value.finalize().expand((b) => b).toList(), [1, 2, 3]);
    });

    testWidgets('R2: the typed phrase is sent unchanged with lang', (
      tester,
    ) async {
      _kk(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      await _type(tester, '  Болт  ЕКІ ');
      final call = cg.where('POST', '/voice/draft-text').single;
      expect(call.data, {'text': '  Болт  ЕКІ ', 'lang': 'kk'});
      expect(voice.starts, 0);
    });

    testWidgets('R4: English asks for ru or kk first; nothing before that', (
      tester,
    ) async {
      await _count(tester, voiceAnswer: (_) => _draft());
      expect(find.byKey(const Key('stock-voice-button')), findsNothing);
      await _type(tester, 'two bolts');
      expect(cg.where('POST', '/voice/'), isEmpty);
      expect(voice.starts, 0);
      await tester.tap(find.byKey(const Key('stock-voice-lang-kk')));
      await tester.pumpAndSettle();
      await _type(tester, 'two bolts');
      expect(
        (cg.where('POST', '/voice/draft-text').single.data as Map)['lang'],
        'kk',
      );
    });

    testWidgets('R3: the mic button is off while a request runs', (
      tester,
    ) async {
      _ru(tester);
      _big(tester);
      final held = HeldGateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voiceSourceProvider.overrideWithValue(voice),
            voiceUiLocaleProvider.overrideWithValue(_ui),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VoicePanel(gateway: held, onDraft: (_) {}),
            ),
          ),
        ),
      );
      await _speak(tester);
      // The request is held: the button is disabled and shows "sending".
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('stock-voice-button')),
      );
      expect(button.onPressed, isNull);
      expect(held.paths, [kVoiceDraftPath]);
      held.release(_draft());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const Key('stock-voice-button')),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('count', () {
    testWidgets('C1/C2: a count draft marks the line; confirm counts once', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft(withLocation: false));
      // The place comes from the current place (C2): set it by typing.
      cg.handler = (c) {
        if (c.path.contains('/voice/')) return _draft(withLocation: false);
        if (c.path.endsWith('/codes/resolve')) {
          return {
            'status': 'assigned',
            'value': 'L',
            'target_type': 'location_node',
            'target_id': _loc,
          };
        }
        if (c.method == 'PUT') return {..._line(), 'counted_quantity': '7.5'};
        if (c.path.endsWith('/lines')) {
          return {
            'rows': [_line()],
            'next_cursor': null,
          };
        }
        return {'id': 'c1', 'status': 'counting', 'number': 'N-7'};
      };
      await tester.enterText(find.byKey(const Key('stock-typed')), 'L');
      await tester.tap(find.byKey(const Key('stock-send')));
      await tester.pumpAndSettle();
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-proposal')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-mark-1')), findsOneWidget);
      expect(find.textContaining('7.5'), findsWidgets);
      expect(cg.where('PUT', '/count'), isEmpty);
      await tester.tap(find.byKey(const Key('stock-voice-confirm')));
      await tester.pumpAndSettle();
      final put = cg.where('PUT', '/lines/1/count').single;
      expect(put.data, {'counted_quantity': '7.5'});
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
    });

    testWidgets('C1b: the draft place is used and dismiss sends nothing', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-proposal')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stock-voice-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
      expect(cg.where('PUT', '/count'), isEmpty);
    });

    testWidgets('C3: no matching line shows a message and sends nothing', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft(items: [_item2]));
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-notice')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
      expect(cg.calls.where((c) => c.method == 'PUT'), isEmpty);
    });

    testWidgets('C4: a receipt draft on the count fills nothing', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft(kind: 'receipt'));
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-notice')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
    });

    testWidgets('C5: several items ask the user to choose', (tester) async {
      _ru(tester);
      await _count(
        tester,
        voiceAnswer: (_) => _draft(items: [_item, _item2]),
        lines: [
          _line(),
          _line(no: 2, item: _item2),
        ],
      );
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-choices')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
      await tester.tap(find.byKey(const Key('stock-voice-choice-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-voice-choices')), findsNothing);
      expect(find.byKey(const Key('stock-voice-mark-2')), findsOneWidget);
    });

    testWidgets('C6: no voice panel unless the count is open', (tester) async {
      _ru(tester);
      await _count(tester, status: 'ordered', voiceAnswer: (_) => _draft());
      expect(find.byKey(const Key('stock-voice-panel')), findsNothing);
    });
  });

  group('document form', () {
    for (final kind in [DocKind.receipt, DocKind.issue, DocKind.transfer]) {
      testWidgets('D1: ${kind.wire} is filled, nothing is written', (
        tester,
      ) async {
        _ru(tester);
        gw.on('POST', '/api/v1/modules/stock/voice/draft', [
          _draft(kind: kind.wire, withTo: kind == DocKind.transfer),
        ]);
        await _form(tester, kind.wire);
        await _speak(tester);
        if (kind == DocKind.transfer) {
          expect(find.textContaining('L1 Shelf'), findsOneWidget);
          expect(find.textContaining('L2 Rack'), findsOneWidget);
        } else {
          expect(find.textContaining('L1 Shelf'), findsOneWidget);
        }
        expect(find.text('Bolt'), findsOneWidget);
        expect(find.byKey(const Key('stock-doc-line-0')), findsOneWidget);
        final qty = tester.widget<TextFormField>(
          find.byKey(const Key('stock-doc-line-0-quantity')),
        );
        expect(qty.controller?.text ?? qty.initialValue, '7.5');
        // D4: only the voice route and read-only lookups were called.
        expect(_writes(), isEmpty);
      });
    }

    testWidgets('D2: two items disable Save until one is chosen', (
      tester,
    ) async {
      _ru(tester);
      gw.on('POST', '/api/v1/modules/stock/voice/draft', [
        _draft(kind: 'receipt', items: [_item, _item2]),
      ]);
      await _form(tester, 'receipt');
      await _pickHeader(tester, DocKind.receipt, {'location_id'});
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-choices')), findsOneWidget);
      expect(_btn(tester, 'stock-doc-save').onPressed, isNull);
      expect(_btn(tester, 'stock-doc-issue').onPressed, isNull);
      await _tap(tester, 'stock-voice-choice-0');
      expect(find.byKey(const Key('stock-voice-choices')), findsNothing);
      expect(_btn(tester, 'stock-doc-save').onPressed, isNotNull);
      expect(_writes(), isEmpty);
    });

    testWidgets('D2b: dismissing the choice enables the form again', (
      tester,
    ) async {
      _ru(tester);
      gw.on('POST', '/api/v1/modules/stock/voice/draft', [
        _draft(kind: 'receipt', items: [_item, _item2]),
      ]);
      await _form(tester, 'receipt');
      await _speak(tester);
      await _tap(tester, 'stock-voice-choice-dismiss');
      expect(find.byKey(const Key('stock-voice-choices')), findsNothing);
    });

    testWidgets('D3: no quantity heard leaves the quantity empty', (
      tester,
    ) async {
      _ru(tester);
      gw.on('POST', '/api/v1/modules/stock/voice/draft', [
        _draft(kind: 'issue', quantity: null),
      ]);
      await _form(tester, 'issue');
      await _speak(tester);
      final qty = tester.widget<TextFormField>(
        find.byKey(const Key('stock-doc-line-0-quantity')),
      );
      expect(qty.controller?.text ?? qty.initialValue ?? '', '');
    });

    testWidgets('D5: write off, hand over and return have no voice', (
      tester,
    ) async {
      _ru(tester);
      for (final kind in ['write_off', 'hand_over', 'return']) {
        await _form(tester, kind);
        expect(find.byKey(const Key('stock-voice-button')), findsNothing);
        expect(find.byKey(const Key('stock-voice-panel')), findsNothing);
      }
    });

    testWidgets('D6: a draft of another kind fills nothing', (tester) async {
      _ru(tester);
      gw.on('POST', '/api/v1/modules/stock/voice/draft', [
        _draft(kind: 'issue'),
      ]);
      await _form(tester, 'receipt');
      await _speak(tester);
      expect(find.textContaining('L1 Shelf'), findsNothing);
      expect(find.byKey(const Key('stock-doc-error')), findsOneWidget);
    });
  });

  group('failures', () {
    Future<void> failWith(WidgetTester tester, ApiError e) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => throw e);
      await _speak(tester);
    }

    ServerError server(int code, String? source, [String? reason]) =>
        ServerError(lastStatusCode: code, source: source, reason: reason);

    testWidgets('F1: speech down says so; typing and scanning still work', (
      tester,
    ) async {
      await failWith(tester, server(503, 'speech', 'speech_off'));
      expect(_msg(tester), contains('speech part'));
      // Typed phrase still goes out, the typed scan field still works.
      cg.handler = (c) {
        if (c.path.contains('/voice/')) return _draft();
        if (c.path.endsWith('/lines')) {
          return {
            'rows': [_line()],
          };
        }
        return {'id': 'c1', 'status': 'counting'};
      };
      await _type(tester, 'bolts');
      expect(cg.where('POST', '/voice/draft-text'), hasLength(1));
      expect(find.byKey(const Key('stock-voice-proposal')), findsOneWidget);
      expect(find.byKey(const Key('stock-typed')), findsOneWidget);
      expect(find.byKey(const Key('stock-send')), findsOneWidget);
    });

    for (final (code, source) in [(502, 'llm'), (504, 'llm')]) {
      testWidgets('F2: $code from the model says the model part is down', (
        tester,
      ) async {
        await failWith(tester, server(code, source, 'provider_error'));
        expect(_msg(tester), contains('understanding part'));
      });
    }

    testWidgets('F2b: 502 from speech names the speech part', (tester) async {
      await failWith(tester, server(502, 'speech', 'provider_error'));
      expect(_msg(tester), contains('speech part'));
    });

    testWidgets('F3: model off shows the transcript and fills nothing', (
      tester,
    ) async {
      _ru(tester);
      await _count(
        tester,
        voiceAnswer: (_) =>
            _draft(items: [], quantity: null, notice: 'llm_off'),
      );
      await _speak(tester);
      expect(find.byKey(const Key('stock-voice-transcript')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-message')), findsOneWidget);
      expect(find.byKey(const Key('stock-voice-proposal')), findsNothing);
      expect(find.byKey(const Key('stock-voice-notice')), findsNothing);
    });

    for (final e in [
      server(413, 'speech', 'audio_too_large'),
      server(415, 'speech', 'audio_format'),
      ValidationError(fieldErrors: const [], reason: 'bad_language'),
      ValidationError(fieldErrors: const [], reason: 'field_invalid'),
      const NotFoundError(),
    ]) {
      testWidgets('F4: $e shows its own message', (tester) async {
        await failWith(tester, e);
        expect(find.byKey(const Key('stock-voice-message')), findsOneWidget);
      });
    }

    for (final (name, e, key) in [
      ('forbidden', const ForbiddenError(), rendererPermissionDeniedKey),
      (
        'backpressure',
        const BackpressureError(retryAfterSeconds: 30),
        rendererBackpressureKey,
      ),
      ('network', const NetworkUnavailableError(), rendererFetchFailureKey),
    ]) {
      testWidgets('F5: $name uses the shared renderer state', (tester) async {
        await failWith(tester, e);
        expect(find.byKey(key), findsOneWidget);
      });
    }

    testWidgets('F6: a refused microphone says so; typing still works', (
      tester,
    ) async {
      voice = FakeVoiceSource(startResult: const VoicePermissionDenied());
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      await tester.tap(find.byKey(const Key('stock-voice-button')));
      await tester.pumpAndSettle();
      expect(_msg(tester), contains('microphone'));
      expect(find.byKey(const Key('stock-voice-stop')), findsNothing);
      await _type(tester, 'bolts');
      expect(cg.where('POST', '/voice/draft-text'), hasLength(1));
    });

    testWidgets('F6b: a recorder that cannot start says it is unavailable', (
      tester,
    ) async {
      voice = FakeVoiceSource(startResult: const VoiceUnavailable());
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      await tester.tap(find.byKey(const Key('stock-voice-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-voice-message')), findsOneWidget);
    });

    testWidgets('F6c: cancel drops the recording and sends nothing', (
      tester,
    ) async {
      _ru(tester);
      await _count(tester, voiceAnswer: (_) => _draft());
      await tester.tap(find.byKey(const Key('stock-voice-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stock-voice-cancel')));
      await tester.pumpAndSettle();
      expect(voice.cancels, 1);
      expect(cg.where('POST', '/voice/'), isEmpty);
    });
  });

  group('texts', () {
    for (final (name, setLocale) in [('ru', _ru), ('kk', _kk)]) {
      testWidgets('L3: the panel at 360 px in $name has no overflow', (
        tester,
      ) async {
        setLocale(tester);
        await _count(tester, voiceAnswer: (_) => throw server502());
        _big(tester, const Size(360, 9000));
        await tester.pumpAndSettle();
        await _speak(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

ServerError server502() =>
    const ServerError(lastStatusCode: 502, source: 'llm');
