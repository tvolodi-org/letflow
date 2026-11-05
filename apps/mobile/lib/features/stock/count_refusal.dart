/// Refusal reasons of the stock count routes (phone-flows.md section 3), each
/// with its own message key in ru, kk and en.
library;

enum CountRefusal {
  codeRetired('code_retired'),
  codeAssignmentConflict('code_assignment_conflict'),
  codeNotAssigned('code_not_assigned'),
  codeNotCountable('code_not_countable'),
  scanNoLine('scan_no_line'),
  scanAmbiguous('scan_ambiguous'),
  locationNotInCount('location_not_in_count'),
  notCommissionMember('not_commission_member'),
  countStateInvalid('count_state_invalid'),
  scanIdConflict('scan_id_conflict'),
  notChair('not_chair'),
  lineNotFound('line_not_found'),
  linesUncounted('lines_uncounted'),
  countNotDue('count_not_due'),
  itemInactive('item_inactive'),
  unitInvalid('unit_invalid'),
  lotInvalid('lot_invalid'),
  countLineExists('count_line_exists'),
  employeeInactive('employee_inactive'),
  fieldInvalid('field_invalid'),
  unknown('unknown');

  const CountRefusal(this.reason);

  final String reason;

  String get messageKey => 'stock.refusal.$reason';

  /// An absent or unknown reason maps to [unknown].
  static CountRefusal fromReason(String? reason) {
    for (final r in values) {
      if (r.reason == reason && r != unknown) return r;
    }
    return unknown;
  }
}
