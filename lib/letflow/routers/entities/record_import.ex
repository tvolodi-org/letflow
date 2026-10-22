defmodule Letflow.Routers.Entities.RecordImport do
  @moduledoc """
  Record import handler (POST /entities/records/:entity_type/import, REQ-320).

  Extracted from `Letflow.Routers.Entities` (GH #2833). The route table stays there;
  each route's handler delegates here with the arguments it had as a local function,
  so behaviour, the INV-1 prefix handling and every response are unchanged.
  """

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Entities.ImportUpsert
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.RecordAccess
  alias Letflow.Entities.Records
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.ScopedWrites

  import Letflow.Routers.Entities.Support

  # ══ POST /entities/records/:entity_type/import (REQ-320) ═════════════
  #
  # Design doc: req314-entity-record-bulk-export-import.md §3 (write path
  # and per-batch failure semantics), §4 (route shape), §6/INV-5 (tenant
  # scoping, not-found folding), §7 (the 200-record cap and its 413).
  #
  # ⛔ Check ordering is load-bearing, not cosmetic (§7's own "cheapest,
  # most structural check first" discipline):
  #
  #   1. the 200-record cap (§7) -- before entity-type/definition resolution
  #      or ANY per-entry validation, never a silent truncation;
  #   2. the `record_export_schema_version` gate (§1/§3) -- before tenant
  #      resolution or any database touch, a distinct 422 from a generic
  #      validation failure;
  #   3. the `entity_type` path-vs-body match (§4) -- before any
  #      `create_record/2` call.
  #
  #   4. (GH #2659) the optional `upsert_by` member: absent -> the create-only
  #      import above, byte-identical to before; "external_ref" -> the
  #      idempotent upsert (`Letflow.Entities.ImportUpsert`); other -> 422.
  #
  # Only after checks 1-3 pass does the body reach an entry. Check 4 only selects
  # the mode: absent -> `create_record/2` per entry, "external_ref" -> the upsert.
  @record_export_schema_version "entities/record-export/v1"

  @doc false
  def handle_import_records(conn, entity_type) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesRecordsImport)

    case RecordAccess.write(conn.assigns.auth_context.user_id, entity_type, prefix!(conn)) do
      :managed -> Response.send_problem(conn, Error.entity_type_managed())
      access -> import_records_with_access(conn, entity_type, access, scope)
    end
  end

  defp import_records_with_access(conn, entity_type, access, scope) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, records} <- records_within_cap(body),
         :ok <- check_record_export_schema_version(body),
         :ok <- check_import_entity_type_match(body, entity_type),
         {:ok, mode} <- check_upsert_by(body),
         :ok <- import_scope_check(access, scope, mode, entity_type, records, prefix) do
      import_request_id = Ecto.UUID.generate()

      case run_import_mode(
             mode,
             records,
             entity_type,
             actor_id,
             import_request_id,
             prefix,
             {access, scope}
           ) do
        {:ok, results} ->
          Response.ok(conn, %{"results" => Enum.map(results, &import_entry_result_json/1)})

        # §6/INV-5, AC: a definition_not_found from the FIRST entry -- the
        # only entry this handler ever inspects for this outcome, since
        # entity_type/tenant are constant across the whole batch -- folds
        # to the SAME 404 create_record/2's own single-write path already
        # produces. No cross-tenant-specific pre-check is added here.
        {:error, {:definition_not_found, _entity_type}} ->
          Response.not_found(conn)

        # GH #2659 upsert mode only: a type that is absent OR denied to the
        # caller (one exit, design 4.5/5.2), decided before any entry is read.
        {:error, :not_found} ->
          Response.not_found(conn)

        # GH #2659: the tenant is not yet replayed to ENTITY_RECORD_CREATED v2;
        # constant, nothing was written.
        {:error, :event_schema_outdated} ->
          Response.service_unavailable(conn, "event_schema_outdated")
      end
    else
      # REQ-518 (2c-ii): one answer for a refused batch, whichever row or reason (R-5).
      {:error, :scope_refused} ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :records_not_an_array} ->
        Response.unprocessable(conn, "records must be an array")

      {:error, :too_many_records, count} ->
        Response.payload_too_large(
          conn,
          "import batch of #{count} records exceeds the 200-record cap"
        )

      {:error, :unknown_record_export_schema_version, actual} ->
        Response.unprocessable(
          conn,
          "unknown record_export_schema_version: #{inspect(actual)}"
        )

      {:error, :import_entity_type_mismatch} ->
        Response.unprocessable(
          conn,
          "entity_type in the request body does not match the route's :entity_type path segment"
        )

      {:error, :invalid_upsert_by} ->
        Response.unprocessable(conn, "upsert_by must be \"external_ref\" when present")
    end
  end

  # REQ-518 (2c-ii, AC 9), AFTER the structural checks (they concern the document, not a
  # resource) and BEFORE the first row is written: a scoped caller passes the type gate and EVERY
  # entry's scope value is checked, or the whole batch is refused with one answer and nothing
  # written (R-5). Upsert mode can update an existing record, so it is not offered to a scoped
  # caller (the same refusal). `:all` callers are not touched.
  defp import_scope_check(_access, :all, _mode, _entity_type, _records, _prefix), do: :ok

  defp import_scope_check(access, scope, mode, entity_type, records, prefix) do
    with :create <- mode,
         {:ok, declaration} <- write_type_gate(access, entity_type, scope, prefix),
         :ok <- ScopedWrites.check_batch(records, declaration, scope),
         :ok <- ScopedWrites.check_batch_references(entity_type, records, scope, prefix) do
      :ok
    else
      _refused ->
        ScopedLookup.emit_not_found(:EntitiesRecordsImport, :import)
        {:error, :scope_refused}
    end
  end

  # §7: rejects the WHOLE request past the 200-record cap, before entity-
  # type/definition resolution or any per-entry validation -- never a
  # silent truncation to the first 200.
  @import_record_cap 200

  defp records_within_cap(body) do
    case Map.get(body, "records") do
      records when is_list(records) ->
        count = length(records)

        if count > @import_record_cap do
          {:error, :too_many_records, count}
        else
          {:ok, records}
        end

      _not_a_list ->
        {:error, :records_not_an_array}
    end
  end

  # §1/§3's ExportImport precedent: checked before tenant resolution or any
  # database touch, a distinct, NAMED error -- never conflated with a
  # generic validation failure.
  defp check_record_export_schema_version(body) do
    case Map.get(body, "record_export_schema_version") do
      @record_export_schema_version -> :ok
      other -> {:error, :unknown_record_export_schema_version, other}
    end
  end

  # §4: the document's own `entity_type` must match the route's
  # `:entity_type` path segment exactly, or 422 before any create_record/2
  # call.
  defp check_import_entity_type_match(body, entity_type) do
    case Map.get(body, "entity_type") do
      ^entity_type -> :ok
      _mismatch -> {:error, :import_entity_type_mismatch}
    end
  end

  # GH #2659 (design 5.1): after the entity_type match, so the existing error
  # ordering is unchanged. Absent -> today's create-only import; exactly
  # "external_ref" -> the idempotent upsert; anything else (null included) -> 422.
  defp check_upsert_by(body) do
    case Map.fetch(body, "upsert_by") do
      :error -> {:ok, :create}
      {:ok, "external_ref"} -> {:ok, :upsert}
      {:ok, _other} -> {:error, :invalid_upsert_by}
    end
  end

  defp run_import_mode(
         :create,
         records,
         entity_type,
         actor_id,
         import_request_id,
         prefix,
         access_and_scope
       ),
       do:
         run_import(
           records,
           entity_type,
           actor_id,
           import_request_id,
           prefix,
           access_and_scope
         )

  # Pre-check once (the schema-version read, then the decision `RecordAccess.write/3` already
  # made), then the per-entry upsert. A scoped caller never reaches it (`import_scope_check/6`
  # refuses upsert mode for it), so the scope in the pair is always `:all`.
  defp run_import_mode(
         :upsert,
         records,
         entity_type,
         actor_id,
         import_request_id,
         prefix,
         {access, :all}
       ) do
    with {:ok, restricted} <- ImportUpsert.precheck(access, prefix) do
      {:ok,
       ImportUpsert.run(records, entity_type, actor_id, import_request_id, restricted, prefix)}
    end
  end

  # §3: per-record partial success, not whole-batch atomicity --
  # create_record/2 commits its own transaction per call and is never
  # composed into an outer Multi here. The FIRST entry is inspected
  # specially only for the definition_not_found short-circuit (see
  # handle_import_records/2's comment); every entry (first included) still
  # contributes its own result to the accumulated list on every other
  # outcome.
  defp run_import([], _entity_type, _actor_id, _import_request_id, _prefix, _access),
    do: {:ok, []}

  defp run_import([first | rest], entity_type, actor_id, import_request_id, prefix, access) do
    case import_one_entry(first, 0, entity_type, actor_id, import_request_id, prefix, access) do
      {:error, _source_record_id, {:error, {:definition_not_found, _} = reason}} ->
        {:error, reason}

      first_result ->
        rest_results =
          rest
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, index} ->
            import_one_entry(
              entry,
              index,
              entity_type,
              actor_id,
              import_request_id,
              prefix,
              access
            )
          end)

        {:ok, [first_result | rest_results]}
    end
  end

  # §3: `entry.record_id` is NEVER used to address/update an existing row --
  # create_record/2 always mints its own fresh record_id; `source_record_id`
  # is carried through purely for the caller's own reconciliation.
  # `deleted: true` on an entry is imported as a live create, identically to
  # a non-deleted one -- no create-then-delete reproduction (§3's explicit
  # scope cut). `idempotency_key` is derived from `(import_request_id,
  # source_record_id)` -- `import_request_id` is minted once per HTTP call
  # in handle_import_records/2, NEVER read from the document or the entry --
  # so two entries sharing a `record_id` WITHIN one call collide onto the
  # same key (intra-call dedup, via create_record/2's own duplicate-key
  # contract; GH #2543: only identical field_values dedupe, differing ones
  # give a per-entry idempotency_key_reuse), while two separate calls -- even a byte-identical re-POST --
  # each mint their own import_request_id and share no relationship at all.
  defp import_one_entry(
         entry,
         index,
         entity_type,
         actor_id,
         import_request_id,
         prefix,
         {access, scope}
       ) do
    source_record_id = Map.get(entry, "record_id")
    field_values = Map.get(entry, "field_values", %{})
    idempotency_key = import_idempotency_key(import_request_id, source_record_id, index)

    command_attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: actor_id,
      idempotency_key: idempotency_key,
      scope: scope
    }

    # GH #2784: the write point. A hidden type gets the result `Records` gives an absent type
    # (so the first-entry fold in `run_import/6` answers exactly as for an absent type); an entry
    # naming a restricted field is refused per entry before `Records`.
    result =
      case access do
        :hidden ->
          RecordAccess.hidden_result(entity_type)

        {:open, restricted} ->
          if RecordAccess.names_restricted?(field_values, restricted),
            do: {:error, :field_restricted},
            else: Records.create_record(command_attrs, prefix)
      end

    case result do
      {:ok, %{record: %Latest{record_id: record_id}}} ->
        {:ok, %{record_id: record_id, source_record_id: source_record_id}}

      {:error, _reason} = error ->
        {:error, source_record_id, error}
    end
  end

  # GH #2551: an entry without a record_id is keyed by its zero-based index in
  # the request so entries do not all collapse onto one `...:nil` key.
  defp import_idempotency_key(import_request_id, nil, index) do
    "entities-record-import:#{import_request_id}:idx:#{index}"
  end

  defp import_idempotency_key(import_request_id, source_record_id, _index) do
    "entities-record-import:#{import_request_id}:#{inspect(source_record_id)}"
  end

  # GH #2659 upsert mode: an ok entry also carries its outcome and the ref it was
  # filed under. Error entries never carry the ref (import_reason_json/1).
  defp import_entry_result_json(
         {:ok,
          %{
            record_id: record_id,
            source_record_id: source_record_id,
            outcome: outcome,
            external_ref: %Letflow.Entities.ExternalRef{} = external_ref
          }}
       ) do
    %{
      "status" => "ok",
      "record_id" => record_id,
      "source_record_id" => source_record_id,
      "outcome" => Atom.to_string(outcome),
      "external_ref" => Letflow.Entities.ExternalRef.to_payload(external_ref)
    }
  end

  defp import_entry_result_json(
         {:ok, %{record_id: record_id, source_record_id: source_record_id}}
       ) do
    %{"status" => "ok", "record_id" => record_id, "source_record_id" => source_record_id}
  end

  defp import_entry_result_json({:error, source_record_id, {:error, reason}}) do
    %{
      "status" => "error",
      "source_record_id" => source_record_id,
      "reason" => import_reason_json(reason)
    }
  end

  # Mirrors render_record_command/3's own Records.command_error() mapping
  # (unmodified reasons, just JSON-shaped instead of turned into an HTTP
  # status) -- so a failing entry's "reason" carries the same information a
  # standalone POST /entities/records/:entity_type call for that same entry
  # would surface.
  defp import_reason_json({:record_payload_invalid, violations}) do
    %{"type" => "record_payload_invalid", "violations" => Enum.map(violations, &violation_map/1)}
  end

  defp import_reason_json({:definition_not_found, entity_type}) do
    %{"type" => "definition_not_found", "entity_type" => entity_type}
  end

  defp import_reason_json({:payload_validation_failed, _errors}) do
    %{"type" => "payload_validation_failed"}
  end

  # GH #2543: two entries in one call sharing a `record_id` (so a key) but
  # with different field_values -- the second is refused, not dropped.
  defp import_reason_json(:idempotency_key_reuse) do
    %{"type" => "idempotency_key_reuse"}
  end

  # GH #2583: race only (the guard already refused managed types before the
  # body was read); constant, no detail, and not logged as an internal error.
  defp import_reason_json(:entity_type_managed) do
    %{"type" => "entity_type_managed"}
  end

  # GH #2654: the entry overlapped an activation of its type; nothing was
  # appended for it and a retry is safe. Constant, no type name.
  defp import_reason_json({:definition_changed, _entity_type}) do
    %{"type" => "definition_changed"}
  end

  # GH #2659 upsert mode: constant reasons, never the ref or the type name.
  @upsert_error_reasons ImportUpsert.error_reasons()

  defp import_reason_json(reason) when reason in @upsert_error_reasons do
    %{"type" => Atom.to_string(reason)}
  end

  defp import_reason_json({:entity_append_only, _entity_type}) do
    %{"type" => "entity_append_only"}
  end

  defp import_reason_json(reason)
       when reason in [:tenant_not_provisioned, :invalid_schema_name] do
    %{"type" => Atom.to_string(reason)}
  end

  defp import_reason_json(other) do
    Logger.warning("entity record import entry failed: #{inspect(other)}")
    %{"type" => "internal_error"}
  end
end
