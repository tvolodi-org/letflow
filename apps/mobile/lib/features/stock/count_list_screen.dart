/// Count list (phone-flows.md section 2 step 1): counting and ordered tabs,
/// load more, every state inside a [RendererStateView].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../i18n/i18n.dart';
import '../../renderers/renderer_state.dart';
import '../../renderers/renderer_state_view.dart';
import 'count_api.dart';
import 'count_list_controller.dart';
import 'count_models.dart';
import 'stock_providers.dart';

const String kStockCountsPath = '/stock/counts';

class CountListScreen extends ConsumerStatefulWidget {
  const CountListScreen({super.key});

  @override
  ConsumerState<CountListScreen> createState() => _CountListScreenState();
}

class _CountListScreenState extends ConsumerState<CountListScreen> {
  late final CountListController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CountListController(
      StockCountApi(ref.read(stockGatewayProvider)),
    )..addListener(_onChange);
    unawaited(_controller.load());
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      key: const Key('stock-counts-screen'),
      appBar: AppBar(title: Text(tr('stock.counts.title'))),
      body: Column(
        children: [
          Row(
            children: [
              for (final s in kCountListStatuses)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ChoiceChip(
                    key: Key('stock-counts-tab-$s'),
                    label: Text(tr('stock.counts.tab.$s')),
                    selected: c.status == s,
                    onSelected: (_) => unawaited(c.selectStatus(s)),
                  ),
                ),
            ],
          ),
          if (c.notAvailable)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                key: const Key('stock-not-available'),
                tr('stock.state.notAvailable'),
              ),
            )
          else
            Expanded(
              child: RendererStateView<CountPage<CountOrder>>(
                state: c.state,
                onRetryBackpressure: c.load,
                contentBuilder: (context, page) => _rows(context, page),
              ),
            ),
          if (c.state is RendererFetchFailure<CountPage<CountOrder>> &&
              !c.notAvailable)
            TextButton(
              key: const Key('stock-counts-retry'),
              onPressed: () => unawaited(c.load()),
              child: Text(tr('stock.scan.retry')),
            ),
        ],
      ),
    );
  }

  Widget _rows(BuildContext context, CountPage<CountOrder> page) {
    if (page.rows.isEmpty) {
      return Center(
        key: const Key('stock-counts-empty'),
        child: Text(tr('stock.counts.empty')),
      );
    }
    return ListView(
      children: [
        for (final o in page.rows)
          ListTile(
            key: Key('stock-count-${o.id}'),
            title: Text(o.number ?? o.id),
            subtitle: Text(o.note ?? ''),
            onTap: () =>
                context.go('$kStockCountsPath/${Uri.encodeComponent(o.id)}'),
          ),
        if (page.nextCursor != null)
          TextButton(
            key: const Key('stock-counts-more'),
            onPressed: () => unawaited(_controller.loadMore()),
            child: Text(tr('stock.counts.more')),
          ),
      ],
    );
  }
}
