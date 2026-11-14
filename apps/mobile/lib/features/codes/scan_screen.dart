/// The scan screen of the codes module (REQ-732): camera preview, a typed
/// fallback, and the answer of `POST /api/v1/modules/codes/resolve` inside a
/// [RendererStateView]. State lives in this screen instance only; nothing is
/// stored.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show PostCapableHttpGateway;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../../i18n/i18n.dart';
import '../../renderers/renderer_state.dart';
import '../../renderers/renderer_state_view.dart';
import 'camera_status_view.dart';
import 'codes_resolve.dart';
import 'scan_controller.dart';
import 'scan_source.dart';

/// The gateway the scan screen posts through: the app's one [ApiClient].
/// Tests override it with a fake gateway.
final Provider<PostCapableHttpGateway> codesGatewayProvider =
    Provider<PostCapableHttpGateway>((ref) => ref.watch(apiClientProvider));

class CodesScanScreen extends ConsumerStatefulWidget {
  const CodesScanScreen({super.key});

  @override
  ConsumerState<CodesScanScreen> createState() => _CodesScanScreenState();
}

class _CodesScanScreenState extends ConsumerState<CodesScanScreen> {
  late final ScanSource _source;
  late final CodesScanController _controller;
  final TextEditingController _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _source = ref.read(scanSourceProvider)();
    _controller = CodesScanController(
      resolver: CodesResolver(ref.read(codesGatewayProvider)),
      source: _source,
    )..addListener(_onChange);
    unawaited(_controller.prepare());
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChange)
      ..dispose();
    unawaited(_source.stop());
    _source.dispose();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final phase = _controller.cameraPhase;
    return Scaffold(
      key: const Key('codes-scan-screen'),
      appBar: AppBar(title: Text(tr('codes.scan.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (phase != null)
            CameraStatusView(
              phase: phase,
              keyPrefix: 'codes',
              onStart: () => unawaited(_controller.startScanning()),
            )
          else if (_controller.scanning)
            SizedBox(height: 240, child: _source.buildPreview()),
          const SizedBox(height: 16),
          TextField(
            key: const Key('codes-typed'),
            controller: _typed,
            decoration: InputDecoration(hintText: tr('codes.typed.hint')),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('codes-lookup'),
            onPressed: () => unawaited(_controller.lookUp(_typed.text)),
            child: Text(tr('codes.lookup')),
          ),
          const SizedBox(height: 16),
          if (state != null)
            SizedBox(
              key: const Key('codes-result'),
              child: RendererStateView<CodeResolution>(
                state: state,
                contentBuilder: (context, data) => _ResultView(result: data),
                onRetryBackpressure: _controller.retry,
              ),
            ),
          if (state is RendererFetchFailure<CodeResolution>)
            TextButton(
              key: const Key('codes-retry'),
              onPressed: () => unawaited(_controller.retry()),
              child: Text(tr('codes.retry')),
            ),
          if (!_controller.scanning && phase == null)
            TextButton(
              key: const Key('codes-scan-again'),
              onPressed: () => unawaited(_controller.scanAgain()),
              child: Text(tr('codes.scanAgain')),
            ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result});

  final CodeResolution result;

  @override
  Widget build(BuildContext context) {
    switch (result.status) {
      case CodeStatus.notAssigned:
        return Text(tr('codes.status.notAssigned'));
      case CodeStatus.retired:
        return Text(tr('codes.status.retired'));
      case CodeStatus.assignmentConflict:
        return Text(tr('codes.status.conflict'));
      case CodeStatus.notKnown:
        return Text(tr('codes.status.notKnown'));
      case CodeStatus.assigned:
        final kindId = switch (result.kind) {
          'barcode' => 'codes.kind.barcode',
          'qr' => 'codes.kind.qr',
          'epc' => 'codes.kind.epc',
          'tid' => 'codes.kind.tid',
          _ => null,
        };
        final objectId = switch (result.objectKind) {
          CodeObjectKind.location => 'codes.object.location',
          CodeObjectKind.item => 'codes.object.item',
          CodeObjectKind.lot => 'codes.object.lot',
          CodeObjectKind.other => 'codes.object.other',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr('codes.result.value')}: ${result.value}'),
            Text(
              '${tr('codes.result.kind')}: '
              '${kindId == null ? (result.kind ?? '') : tr(kindId)}',
            ),
            Text('${tr('codes.result.object')}: ${tr(objectId)}'),
          ],
        );
    }
  }
}
