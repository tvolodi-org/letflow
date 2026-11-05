/// A bottom sheet that scans (or takes typed) text, resolves it through
/// `POST /api/v1/modules/codes/resolve` unchanged and returns the resolution.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/i18n.dart';
import '../../../renderers/renderer_state.dart';
import '../../../renderers/renderer_state_view.dart';
import '../../codes/codes_resolve.dart';
import '../../codes/scan_controller.dart';
import '../../codes/scan_source.dart';
import 'documents_providers.dart';

Future<CodeResolution?> showScanFill(BuildContext context) {
  return showModalBottomSheet<CodeResolution>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ScanFillBody(),
  );
}

class _ScanFillBody extends ConsumerStatefulWidget {
  const _ScanFillBody();

  @override
  ConsumerState<_ScanFillBody> createState() => _ScanFillBodyState();
}

class _ScanFillBodyState extends ConsumerState<_ScanFillBody> {
  late final ScanSource _source;
  late final CodesScanController _controller;
  final TextEditingController _typed = TextEditingController();
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _source = ref.read(scanSourceProvider);
    _controller = CodesScanController(
      resolver: CodesResolver(ref.read(stockGatewayProvider)),
      source: _source,
    )..addListener(_onChange);
    unawaited(_controller.startScanning());
  }

  void _onChange() {
    if (!mounted) return;
    final state = _controller.state;
    // Any answer, whatever its status, goes back to the form, which decides
    // whether it fills; only failures stay here with a retry.
    if (state is RendererContent<CodeResolution> && !_popped) {
      _popped = true;
      Navigator.of(context).pop(state.data);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChange)
      ..dispose();
    unawaited(_source.stop());
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_controller.cameraRefused)
              Text(tr('codes.cameraRefused'))
            else if (_controller.scanning)
              SizedBox(height: 200, child: _source.buildPreview()),
            TextField(
              key: const Key('stock-doc-scan-typed'),
              controller: _typed,
              decoration: InputDecoration(hintText: tr('codes.typed.hint')),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('stock-doc-scan-lookup'),
              onPressed: () => unawaited(_controller.lookUp(_typed.text)),
              child: Text(tr('codes.lookup')),
            ),
            if (state != null && state is! RendererContent<CodeResolution>)
              RendererStateView<CodeResolution>(
                state: state,
                contentBuilder: (_, _) => const SizedBox.shrink(),
                onRetryBackpressure: _controller.retry,
              ),
            if (state is RendererFetchFailure<CodeResolution>)
              TextButton(
                key: const Key('stock-doc-scan-retry'),
                onPressed: () => unawaited(_controller.retry()),
                child: Text(tr('codes.retry')),
              ),
          ],
        ),
      ),
    );
  }
}
