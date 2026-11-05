import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../i18n/i18n.dart';
import 'documents/document_form_screen.dart' show kStockDocumentsPath;

/// Home of the `stock` module: the entry to the movement drafts. Counts
/// arrive in a later slice; no stock call is made here.
class StockHomeScreen extends StatelessWidget {
  const StockHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('stock-home-screen'),
      appBar: AppBar(title: Text(tr('stock.home.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          ListTile(
            key: const Key('stock-home-documents-entry'),
            title: Text(tr('stock.home.documents')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(kStockDocumentsPath),
          ),
          Padding(
            key: const Key('stock-home-empty'),
            padding: const EdgeInsets.only(top: 16),
            child: Text(tr('stock.home.empty'), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
