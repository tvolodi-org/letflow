defmodule Letflow.Ledger.CodesTest do
  @moduledoc "REQ-684 criterion 2 (T-ERR-4 part): the neutral code lists are a golden constant."

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Ledger.Codes

  test "T-ERR-4a the core codes with their statuses are unchanged" do
    assert Codes.core() == [
             {"insufficient_balance", 409},
             {"balance_bound_exceeded", 409},
             {"unit_mismatch", 409},
             {"posting_not_balanced", 409},
             {"posting_already_reversed", 409},
             {"posting_is_reversal", 409},
             {"posting_is_paired", 409},
             {"idempotency_key_reuse", 409},
             {"client_seq_conflict", 409},
             {"event_time_in_future", 422},
             {"event_time_too_old", 422},
             {"invalid_posting", 422},
             {"ledger_instances_exhausted", 422},
             {"write_not_permitted", 403},
             {"entity_write_failed", 500},
             {"entity_write_contention", 503}
           ]
  end

  test "T-ERR-4b the aliasable subset and the reserved list are unchanged" do
    assert Codes.aliasable() == [
             "insufficient_balance",
             "balance_bound_exceeded",
             "unit_mismatch",
             "posting_not_balanced",
             "posting_already_reversed",
             "posting_is_reversal"
           ]

    core = Enum.map(Codes.core(), &elem(&1, 0))
    assert Codes.aliasable() -- core == []

    assert Codes.reserved() == [
             "balance_bound_exceeded",
             "client_seq_conflict",
             "definition_needs_reactivation",
             "endpoint_url_reserved_variable",
             "entity_append_only",
             "entity_write_activator_not_in_target_tenant",
             "entity_write_contention",
             "entity_write_failed",
             "entity_write_needs_reactivation",
             "entity_writes_invalid",
             "event_time_in_future",
             "event_time_too_old",
             "expression_references_reserved_variable",
             "idempotency_key_reuse",
             "insufficient_balance",
             "internal_error",
             "invalid_arguments",
             "invalid_posting",
             "invalid_request",
             "ledger_instances_exhausted",
             "movement_not_found",
             "not_found",
             "posting_already_reversed",
             "posting_is_paired",
             "posting_is_reversal",
             "posting_not_balanced",
             "record_version_conflict",
             "script_binding_invalid",
             "script_busy",
             "tenant_inactive",
             "tenant_migrating",
             "test_case_failed",
             "trigger_backlog_full",
             "unauthorized",
             "unit_mismatch",
             "validation_failed",
             "write_not_permitted"
           ]

    assert Enum.all?(core, &(&1 in Codes.reserved()))
  end
end
