import 'package:flutter/material.dart';

import '../../i18n/i18n.dart';

/// Skeleton home of the `stock` module: an empty state only. Counts and
/// movements arrive in later slices; no stock call is made here.
class StockHomeScreen extends StatelessWidget {
  const StockHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('stock-home-screen'),
      appBar: AppBar(title: Text(tr('stock.home.title'))),
      body: Center(
        key: const Key('stock-home-empty'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr('stock.home.empty'), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
