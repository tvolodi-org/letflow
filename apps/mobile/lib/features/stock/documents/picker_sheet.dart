import 'package:flutter/material.dart';

import '../../../i18n/i18n.dart';
import 'document_form_controller.dart';
import 'document_pickers.dart';

/// A bottom sheet listing the options of one entity type (first 200 active
/// records); resolves to the chosen option or null.
Future<PickerOption?> showEntityPicker(
  BuildContext context,
  DocFormController controller,
  String entity, {
  String? itemId,
}) {
  return showModalBottomSheet<PickerOption>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _PickerBody(loader: () => controller.options(entity, itemId: itemId)),
  );
}

/// A fixed option list (the write-off reasons).
Future<PickerOption?> showFixedPicker(
  BuildContext context,
  List<PickerOption> options,
) {
  return showModalBottomSheet<PickerOption>(
    context: context,
    builder: (_) => _PickerBody(loader: () async => options),
  );
}

class _PickerBody extends StatelessWidget {
  const _PickerBody({required this.loader});

  final Future<List<PickerOption>> Function() loader;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<PickerOption>>(
        future: loader(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final options = snapshot.data!;
          if (options.isEmpty) {
            return SizedBox(
              height: 120,
              child: Center(
                key: const Key('stock-doc-picker-empty'),
                child: Text(tr('stock.doc.pick.empty')),
              ),
            );
          }
          return ListView(
            shrinkWrap: true,
            children: [
              for (final o in options)
                ListTile(
                  key: Key('stock-doc-option-${o.id}'),
                  title: Text(o.label),
                  onTap: () => Navigator.of(context).pop(o),
                ),
            ],
          );
        },
      ),
    );
  }
}
