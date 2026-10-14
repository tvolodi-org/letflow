defmodule Letflow.Engine.ScriptReadPort do
  @moduledoc """
  GH 2534 PR 7c-2 (decision 0053 D5, F10): the engine-defined port through which a tenant
  script's declared master-data `reads` are pre-fetched host-side, before the run. Design
  `lib/letflow/design/gh2534-7c-script-handler.md` sections 11.1-11.3.

  The engine owns this behaviour; the entity-record implementation lives outside the engine and
  is selected at run time from the `config :letflow, :script_read_port` value (set in
  `config/config.exs`), so no engine file names an entity module. `mix letflow.check_boundaries`
  Rule 6 enforces that on direct file edges.

  The dispatcher calls `prefetch/3` only when the manifest's `reads` is non-empty, after the
  kill switch, tenant, version, manifest backstops (closed output schema, restricted opt-in
  refusal, `Letflow.Scripts.Policy.check_reads/2`) and the HMAC key, and before admission.

  Contract for an implementation:

    * Phase 1, for EVERY read, before any record query: the type has an active definition and
      no type restriction; every `fields` and `match.field` name is a field of it;
      `restricted_fields` is absent or empty (hook 1 has no opt-in, C10); a `match.field` that
      is restricted NOW is refused (SEC N1). Any failure is `{:error, :reads_not_allowed}`.
    * Phase 2: exactly ONE record query per read, whether it hits or misses (no existence
      oracle); at most `limit` (<= 50) rows; a field restricted NOW is omitted from every row.
    * The tenant prefix is the caller's run-context prefix, never derived from manifest text.
    * Nothing survives a call: no cache across runs.
  """

  @typedoc """
  One declared read (a validated manifest entry). `restricted_fields` is always empty here:
  the restricted opt-in is refused before the port is called (C10).
  """
  @type read_spec :: %{required(String.t()) => term()}

  @typedoc "One delivered row: the record id under `\"id\"` plus the declared, unredacted fields."
  @type row :: %{required(String.t()) => term()}

  @doc """
  Pre-fetches every read in `reads` from the tenant schema `prefix`, taking match values from
  `input_vars` (the script's declared input variables). Returns every read name, a miss as
  `[]`, or `{:error, :reads_not_allowed}` before any record query.
  """
  @callback prefetch(prefix :: String.t(), reads :: [read_spec()], input_vars :: map()) ::
              {:ok, %{optional(String.t()) => [row()]}} | {:error, :reads_not_allowed}
end
