/// The surplus line form (phone-flows.md section 2 step 6). Ids pre-filled
/// from the refused scan are editable; a missing id is pasted as a uuid (no
/// route resolves item names or units: a spec GAP). Save is enabled only for
/// valid ids and quantity.
library;

import 'package:flutter/material.dart';

import '../../i18n/i18n.dart';
import 'count_detail_controller.dart';

class SurplusResult {
  const SurplusResult({
    required this.locationId,
    required this.catalogItemId,
    required this.unitRef,
    required this.catalogLotId,
    required this.quantity,
  });

  final String locationId;
  final String catalogItemId;
  final String unitRef;
  final String catalogLotId;
  final String quantity;
}

class SurplusLineSheet extends StatefulWidget {
  const SurplusLineSheet({super.key, required this.draft});

  final SurplusDraft draft;

  @override
  State<SurplusLineSheet> createState() => _SurplusLineSheetState();
}

class _SurplusLineSheetState extends State<SurplusLineSheet> {
  late final TextEditingController _item = TextEditingController(
    text: widget.draft.catalogItemId,
  );
  late final TextEditingController _unit = TextEditingController(
    text: widget.draft.unitRef,
  );
  late final TextEditingController _lot = TextEditingController(
    text: widget.draft.catalogLotId,
  );
  final TextEditingController _qty = TextEditingController();

  @override
  void dispose() {
    _item.dispose();
    _unit.dispose();
    _lot.dispose();
    _qty.dispose();
    super.dispose();
  }

  bool get _valid =>
      isUuidText(widget.draft.locationId) &&
      isUuidText(_item.text) &&
      isUuidText(_unit.text) &&
      (_lot.text.isEmpty || isUuidText(_lot.text)) &&
      isQuantityText(_qty.text);

  Widget _field(String key, String label, TextEditingController c) => TextField(
    key: Key(key),
    controller: c,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(labelText: tr(label)),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('stock-surplus-sheet'),
      title: Text(tr('stock.surplus.title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.draft.codeNotUsable)
              Text(
                key: const Key('stock-surplus-code-not-usable'),
                tr('stock.surplus.codeNotUsable'),
              ),
            _field('stock-surplus-item', 'stock.surplus.item', _item),
            _field('stock-surplus-unit', 'stock.surplus.unit', _unit),
            _field('stock-surplus-lot', 'stock.surplus.lot', _lot),
            _field('stock-surplus-qty', 'stock.surplus.quantity', _qty),
            if (!isUuidText(widget.draft.locationId))
              Text(tr('stock.surplus.invalidId')),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('stock-surplus-save'),
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  SurplusResult(
                    locationId: widget.draft.locationId,
                    catalogItemId: _item.text,
                    unitRef: _unit.text,
                    catalogLotId: _lot.text,
                    quantity: _qty.text,
                  ),
                )
              : null,
          child: Text(tr('stock.surplus.save')),
        ),
      ],
    );
  }
}
