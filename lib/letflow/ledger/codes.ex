defmodule Letflow.Ledger.Codes do
  @moduledoc """
  REQ-684 / GH #3698 (decision 0073, note 12.2): the neutral wire codes of the ledger core and the
  constants the alias rule of `Letflow.Modules.LedgerRegistration` needs. Pure data; inside the
  Rule 7 scope of `mix letflow.check_boundaries`, so no code here may contain a denylisted word.

    * `core/0` - every core code with the HTTP status it always carries (the status follows the
      CORE code, whatever alias a module maps it to).
    * `aliasable/0` - the closed subset a module may rename (`error_aliases` keys).
    * `reserved/0` - the reviewed constant of every core, engine, entity and ledger wire code. An
      alias VALUE may not be any of these. A new wire code elsewhere in the product is added here
      by a reviewed diff; the golden test in `test/letflow/ledger/codes_test.exs` pins the list.
  """

  @core [
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

  @aliasable [
    "insufficient_balance",
    "balance_bound_exceeded",
    "unit_mismatch",
    "posting_not_balanced",
    "posting_already_reversed",
    "posting_is_reversal"
  ]

  # Engine, entity and API codes found by a grep of the error bodies of lib/letflow/{api,engine,
  # entities,routers} (REQ-684 implement time), plus the ones note 12.2 names.
  @other_reserved [
    "definition_needs_reactivation",
    "endpoint_url_reserved_variable",
    "entity_append_only",
    "entity_write_activator_not_in_target_tenant",
    "entity_write_needs_reactivation",
    "entity_writes_invalid",
    "expression_references_reserved_variable",
    "internal_error",
    "invalid_arguments",
    "invalid_request",
    "movement_not_found",
    "not_found",
    "record_version_conflict",
    "script_binding_invalid",
    "script_busy",
    "tenant_inactive",
    "tenant_migrating",
    "test_case_failed",
    "trigger_backlog_full",
    "unauthorized",
    "validation_failed"
  ]

  @doc "The core codes of note 12.2 as `{code, http_status}`, in table order."
  @spec core() :: [{String.t(), pos_integer()}]
  def core, do: @core

  @doc """
  The HTTP status of a core code (string or atom), `nil` for a code that is not a core code.
  """
  @spec status(String.t() | atom()) :: pos_integer() | nil
  def status(code) when is_atom(code) and not is_nil(code), do: status(Atom.to_string(code))

  def status(code) when is_binary(code),
    do: Enum.find_value(@core, fn {c, s} -> c == code && s end)

  def status(_code), do: nil

  @doc "The core codes a module may alias (decision 0073 D3)."
  @spec aliasable() :: [String.t()]
  def aliasable, do: @aliasable

  @doc "Every reserved wire code, sorted: no alias value may equal one."
  @spec reserved() :: [String.t()]
  def reserved, do: Enum.sort(Enum.map(@core, &elem(&1, 0)) ++ @other_reserved)
end
