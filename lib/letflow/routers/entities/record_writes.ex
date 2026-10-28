defmodule Letflow.Routers.Entities.RecordWrites do
  @moduledoc """
  Record write handlers (create, update, delete) of the entity subsystem, and the one renderer of a record command.

  Extracted from `Letflow.Routers.Entities` (GH #2833). The route table stays there;
  each route's handler delegates here with the arguments it had as a local function,
  so behaviour, the INV-1 prefix handling and every response are unchanged.
  """

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.RecordAccess
  alias Letflow.Entities.Records
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.ScopedWrites
  alias Letflow.Entities.WriteScope
  alias Letflow.Idempotency

  import Letflow.Routers.Entities.Support
  import Plug.Conn, only: [fetch_query_params: 1]

  # ══ POST /entities/records/:entity_type ═══════════════════════════════
  #
  # create_record/2's create_attrs() is
  # %{entity_type, field_values, actor_id, idempotency_key} -- `entity_type`
  # comes from the PATH segment (never a body field), `actor_id` from
  # conn.assigns.auth_context.user_id (INV-1), `idempotency_key` resolved by
  # Letflow.Idempotency.from_body/3 (GH #2550): the caller's own replay token
  # stored as `client:rec:<actor>:<K>` (bound to (command, entity_type,
  # record_id, field_values, actor) -- GH #2543), refused with a 422
  # `max_length` over 199 bytes and a 422 `format` when not valid UTF-8 or
  # containing NUL (checked before any DB access), and otherwise freshly
  # minted so the delegate's required key is always present. A supplied key may also resolve to a pre-#2550 original
  # (Idempotency.legacy_original/3, one release, GH #2578).

  # REQ-607: the constant detail of the 503 for the two pre-write hook codes.
  @hook_unavailable "the write could not be completed; retry"

  @record_write_schema [
    %FieldConstraint{name: "field_values", required: true, type: :object},
    %FieldConstraint{
      name: "idempotency_key",
      required: false,
      type: :string,
      reject_empty_string: true
    }
  ]

  # GH #2784: the decider. `RecordAccess.write/3` is computed FIRST (before the body is read) and
  # APPLIED last, at the write point inside `create_record_with_access/3`: a managed type is the
  # constant 403 here (visible types only, so it can never reveal a denied one); a hidden type
  # (denied, absent, or a failed read) runs the same validation as an absent type and then gets
  # the result `Records` gives an absent type.
  @doc false
  def handle_create_record(conn, entity_type) do
    # REQ-518 (2c-ii): the set is read FIRST through the one gate, and every response below is
    # sent on the conn it returns (the "scope applied" marker). A scoped caller then passes the
    # type gate BEFORE the body is read (R-6); `:all` callers take today's path unchanged.
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesRecordsWrite)
    prefix = prefix!(conn)

    case RecordAccess.write(conn.assigns.auth_context.user_id, entity_type, prefix) do
      :managed ->
        Response.send_problem(conn, Error.entity_type_managed())

      access ->
        case write_type_gate(access, entity_type, scope, prefix) do
          {:ok, declaration} ->
            create_record_with_access(
              conn,
              entity_type,
              access,
              WriteScope.new(scope, declaration)
            )

          :refused ->
            scope_refused(conn, :EntitiesRecordsWrite, :write_value)
        end
    end
  end

  # By-id visibility for PUT and DELETE (D5): one predicate lookup AFTER the set read and BEFORE
  # the body (or query string) is read. A hidden type is not visible to a scoped caller.
  defp visible_record(_access, _entity_type, _record_id, :all, _prefix, _policy),
    do: {:ok, :unscoped}

  defp visible_record(:hidden, _entity_type, _record_id, _scope, _prefix, policy) do
    ScopedLookup.emit_not_found(policy, :by_id)
    {:error, :scope_refused}
  end

  defp visible_record({:open, _restricted}, entity_type, record_id, scope, prefix, policy) do
    case ScopedLookup.fetch_in_scope(entity_type, record_id, scope, prefix, {policy, :by_id}) do
      {:ok, declaration} -> {:ok, declaration}
      :not_found -> {:error, :scope_refused}
    end
  end

  # C-3: the pure new-value check, then the reference resolution (SEC BUG-1: a reference to an
  # out-of-scope record must answer like one to a nonexistent record); both run before the
  # idempotency claim and share the one refusal and telemetry kind.
  defp check_new_scope_value(
         %WriteScope{scope: scope, declaration: declaration},
         field_values,
         policy,
         entity_type,
         prefix
       ) do
    with :ok <- ScopedWrites.check_new_value(field_values, declaration, scope),
         :ok <- ScopedWrites.check_references_of_type(entity_type, field_values, scope, prefix) do
      :ok
    else
      :refused ->
        ScopedLookup.emit_not_found(policy, :write_value)
        {:error, :scope_refused}
    end
  end

  defp scope_refused(conn, policy, kind) do
    ScopedLookup.emit_not_found(policy, kind)
    Response.not_found(conn)
  end

  defp create_record_with_access(conn, entity_type, access, %WriteScope{scope: scope} = scoped) do
    prefix = prefix!(conn)

    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_write_schema, body),
         :ok <-
           check_new_scope_value(
             scoped,
             Map.fetch!(attrs, "field_values"),
             :EntitiesRecordsWrite,
             entity_type,
             prefix
           ),
         {:ok, resolved} <- Idempotency.from_body(attrs, :rec, actor_id) do
      command_attrs =
        %{
          entity_type: entity_type,
          field_values: Map.fetch!(attrs, "field_values"),
          actor_id: actor_id,
          idempotency_key: resolved.key,
          scope: scope
        }
        |> put_legacy_original(resolved, actor_id, prefix)

      case write_point(access, Map.fetch!(attrs, "field_values")) do
        {:run, restricted} ->
          render_record_command(
            conn,
            Records.create_record(command_attrs, prefix),
            :created,
            restricted
          )

        {:refuse, :restricted_field} ->
          restricted_fields_refusal(conn)

        {:refuse, :hidden} ->
          render_record_command(
            conn,
            RecordAccess.hidden_result(entity_type),
            :created,
            MapSet.new()
          )
      end
    else
      {:error, :scope_refused} ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :idempotency_key_too_long} ->
        Response.send_problem(conn, Validation.problem([Idempotency.too_long_error(:body)]))

      {:error, :idempotency_key_invalid} ->
        Response.send_problem(conn, Validation.problem([Idempotency.invalid_error(:body)]))
    end
  end

  # ══ PUT /entities/records/:entity_type/:record_id ═════════════════════
  #
  # Full replacement of `field_values` (update_record/2's own whole-document
  # semantics).
  #
  # GH #2528: PUT alone accepts the optional `expected_last_event_global_seq`
  # (POST keeps @record_write_schema byte-for-byte). `type: :integer` rejects
  # 1.0 / "5" / true with 422; JSON null arrives as nil, which the domain
  # treats as absent. `max_value` keeps a JSON bignum away from Postgrex's
  # int8 encoder (INV-8). The value is passed through untouched -- no cast.
  # `If-Match` stays ignored.
  #
  # GH #2529: an append-only entity type gives 422 entity-append-only for any
  # record id (the domain refuses before the record lookup, INV-5).

  @max_int8 9_223_372_036_854_775_807

  @record_update_schema @record_write_schema ++
                          [
                            %FieldConstraint{
                              name: "expected_last_event_global_seq",
                              required: false,
                              type: :integer,
                              min_value: 0,
                              max_value: @max_int8
                            }
                          ]

  @doc false
  def handle_update_record(conn, entity_type, raw_record_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesRecordsWrite)

    case RecordAccess.write(conn.assigns.auth_context.user_id, entity_type, prefix!(conn)) do
      :managed -> Response.send_problem(conn, Error.entity_type_managed())
      access -> update_record_with_access(conn, entity_type, raw_record_id, access, scope)
    end
  end

  defp update_record_with_access(conn, entity_type, raw_record_id, access, scope) do
    prefix = prefix!(conn)

    actor_id = conn.assigns.auth_context.user_id

    # REQ-518 (2c-ii): the by-id lookup follows the id cast and precedes the body (a malformed or
    # schema-invalid body for an out-of-scope or nonexistent id is the same 404); the new value is
    # checked (pure) before the idempotency claim.
    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, declaration} <-
           visible_record(access, entity_type, record_id, scope, prefix, :EntitiesRecordsWrite),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_update_schema, body),
         :ok <-
           check_new_scope_value(
             WriteScope.new(scope, declaration),
             Map.fetch!(attrs, "field_values"),
             :EntitiesRecordsWrite,
             entity_type,
             prefix
           ),
         {:ok, resolved} <- Idempotency.from_body(attrs, :rec, actor_id) do
      command_attrs =
        %{
          entity_type: entity_type,
          record_id: record_id,
          field_values: Map.fetch!(attrs, "field_values"),
          actor_id: actor_id,
          idempotency_key: resolved.key,
          expected_last_event_global_seq: Map.get(attrs, "expected_last_event_global_seq"),
          scope: scope
        }
        |> put_legacy_original(resolved, actor_id, prefix)

      # GH #2812: PUT replaces `field_values` wholesale, so a body naming a restricted key is
      # refused (as POST); otherwise the server carries the stored values of the actor's restricted
      # keys into the written document under a version check (`preserve_keys`).
      case update_write_point(access, Map.fetch!(attrs, "field_values")) do
        {:run, restricted} ->
          command_attrs = put_preserve_keys(command_attrs, restricted)

          render_record_command(
            conn,
            Records.update_record(command_attrs, prefix),
            :ok,
            restricted
          )

        {:refuse, :restricted_field} ->
          restricted_fields_refusal(conn)

        {:refuse, :hidden} ->
          render_record_command(
            conn,
            RecordAccess.hidden_result(entity_type),
            :ok,
            MapSet.new()
          )
      end
    else
      # INV-5: a malformed record id takes the same zero-detail 404 a
      # well-formed-but-absent (or cross-tenant) one takes.
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :scope_refused} ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :idempotency_key_too_long} ->
        Response.send_problem(conn, Validation.problem([Idempotency.too_long_error(:body)]))

      {:error, :idempotency_key_invalid} ->
        Response.send_problem(conn, Validation.problem([Idempotency.invalid_error(:body)]))
    end
  end

  # The write point of POST: what to do with the access decision once the request validated.
  defp write_point(:hidden, _field_values), do: {:refuse, :hidden}

  defp write_point({:open, restricted}, field_values) do
    if RecordAccess.names_restricted?(field_values, restricted),
      do: {:refuse, :restricted_field},
      else: {:run, restricted}
  end

  # The write point of PUT (GH #2812): as POST, a body naming a restricted key refuses.
  defp update_write_point(access, field_values), do: write_point(access, field_values)

  defp put_preserve_keys(command_attrs, restricted) do
    if MapSet.size(restricted) > 0,
      do: Map.put(command_attrs, :preserve_keys, restricted),
      else: command_attrs
  end

  # GH #2550 (design D3), removed by GH #2578: a supplied key that passes the
  # no-I/O guard and names a same-actor pre-cutoff record event becomes
  # Records' `legacy_original`, matched instead of appended.
  defp put_legacy_original(command_attrs, resolved, actor_id, prefix) do
    case Idempotency.legacy_original(resolved, actor_id, prefix: prefix) do
      {:ok, event} -> Map.put(command_attrs, :legacy_original, event)
      :none -> command_attrs
    end
  end

  # ══ DELETE /entities/records/:entity_type/:record_id ══════════════════
  #
  # Bodyless. delete_record/2 treats an already-deleted record as a no-op
  # success (its own documented domain-level idempotency), so
  # {:record_already_deleted, _} is unreachable through this route (still
  # mapped below, on the shared renderer, for completeness). A 409 IS
  # reachable (GH #2528): an optional
  # `?expected_last_event_global_seq=<n>` query param that no longer matches
  # the stored row gives 409 record-version-conflict. An invalid value is a
  # 400 (query-string errors are 400 in this router, like `page_size`),
  # checked after the record id cast (malformed id -> 404 first) and before
  # any lookup, so it does not depend on record existence (INV-5).
  # GH #2529: an append-only entity type gives 422 entity-append-only for any
  # record id, live, deleted or absent (refused before the record lookup).

  @doc false
  def handle_delete_record(conn, entity_type, raw_record_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesRecordsWrite)

    case RecordAccess.write(conn.assigns.auth_context.user_id, entity_type, prefix!(conn)) do
      :managed -> Response.send_problem(conn, Error.entity_type_managed())
      access -> delete_record_with_access(conn, entity_type, raw_record_id, access, scope)
    end
  end

  defp delete_record_with_access(conn, entity_type, raw_record_id, access, scope) do
    # REQ-518 (2c-ii): the by-id lookup precedes the query-string parse (a 400 for a bad
    # `expected_last_event_global_seq` must not tell an out-of-scope id from a nonexistent one).
    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, _declaration} <-
           visible_record(
             access,
             entity_type,
             record_id,
             scope,
             prefix!(conn),
             :EntitiesRecordsWrite
           ),
         conn = fetch_query_params(conn),
         {:ok, expected} <-
           parse_expected_seq_param(Map.get(conn.query_params, "expected_last_event_global_seq")) do
      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: Ecto.UUID.generate(),
        expected_last_event_global_seq: expected,
        scope: scope
      }

      # No body, so no key check; the RESPONSE of an open type is redacted for an actor holding
      # restricted fields (the deleted row is returned with its `field_values`).
      case access do
        {:open, restricted} ->
          render_record_command(
            conn,
            Records.delete_record(command_attrs, prefix!(conn)),
            :ok,
            restricted
          )

        :hidden ->
          render_record_command(
            conn,
            RecordAccess.hidden_result(entity_type),
            :ok,
            MapSet.new()
          )
      end
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :scope_refused} ->
        Response.not_found(conn)

      {:error, :invalid_expected_seq} ->
        Response.bad_request(conn, "invalid expected_last_event_global_seq")
    end
  end

  # Absent -> {:ok, nil}; a string Integer.parse/1 consumes fully, within
  # 0..max int8 -> {:ok, n}; anything else ("abc", "", "-1", "1.5", "1x",
  # overflow, a repeated/array param) -> {:error, :invalid_expected_seq}.
  @spec parse_expected_seq_param(nil | String.t() | list() | map()) ::
          {:ok, non_neg_integer() | nil} | {:error, :invalid_expected_seq}
  defp parse_expected_seq_param(nil), do: {:ok, nil}

  defp parse_expected_seq_param(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 and n <= @max_int8 -> {:ok, n}
      _other -> {:error, :invalid_expected_seq}
    end
  end

  defp parse_expected_seq_param(_other), do: {:error, :invalid_expected_seq}

  # design §7, Records.command_error(), mapped exhaustively:
  #   {:definition_not_found, _}     -> 404  (INV-5)
  #   {:record_not_found, _}         -> 404  (INV-5)
  #   {:record_payload_invalid, v}   -> 422 with the violation list
  #   {:record_size_exceeded, _}     -> 422 constant detail (GH #2689, Record.SizeCap)
  #   {:payload_validation_failed,_} -> 422
  #   {:record_already_deleted, _}   -> 409
  #   :record_version_conflict       -> 409 (record-version-conflict, GH #2528;
  #                                     constant body, no record data/seq)
  #   {:entity_append_only, _}       -> 422 (entity-append-only, GH #2529;
  #                                     constant body)
  #   :idempotency_key_reuse         -> 422 (idempotency-key-reuse, GH #2543;
  #                                     constant body, no original data)
  #   {:definition_changed, _}       -> 409 (GH #2654; write overlapped an activation)
  #   :entity_type_managed           -> 403 (race only; same body as the guard,
  #                                     GH #2583)
  #   :preserved_value_invalid       -> 403  (constant restricted-field detail,
  #                                     GH #2812)
  #   :entity_write_contention       -> 503 (REQ-607; pre-write hook lock timeout/deadlock/statement
  #                                     timeout; the problem-JSON constant body)
  #   :derived_value_conflict,
  #   :script_busy                   -> 503 {"error": "<code>"} (REQ-618, decision 0065 D6)
  #   :script_rejected               -> 409 {"error": "script_rejected"}
  #   :script_error, :budget_exceeded, :memory_limit_exceeded, :timeout, :output_invalid,
  #   {:script_failed, code}         -> 422 {"error": "<code>"} (the declared code for script_failed)
  #   :tenant_not_provisioned        -> 500  (unreachable, INV-1)
  #   :invalid_schema_name           -> 500  (unreachable, INV-1)
  #   any other term()               -> 500  (INV-8 catch-all, no detail)
  #
  # GH #2784: `render_record_command/4` is the one renderer of a record command. For a success it
  # redacts `record.field_values` through `FieldGrants.redact_field_values/2` when `restricted` is
  # non-empty, BEFORE `record_map/2` (which stays unchanged), the order the read routes use. Every
  # other result is rendered by the error clauses of `render_record_command/3`, which never see
  # the set. `@doc false def` only so the redaction can be unit tested.
  @doc false
  @spec render_record_command(Plug.Conn.t(), term(), :created | :ok, MapSet.t(String.t())) ::
          Plug.Conn.t()
  def render_record_command(
        conn,
        {:ok, %{record: %Latest{} = record} = result},
        status,
        restricted
      )
      when status in [:created, :ok] do
    record = redact_record(record, restricted)
    body = record_map(record, command_specs(result, record, conn))

    case status do
      :created -> Response.created(conn, body)
      :ok -> Response.ok(conn, body)
    end
  end

  def render_record_command(conn, result, status, _restricted),
    do: render_record_command(conn, result, status)

  # GH #2773: the specs the command validated against (`Records` result); a result built without
  # them (a hand-made one in a unit test) falls back to one definition read.
  defp command_specs(%{strict_specs: specs}, _record, _conn) when is_map(specs), do: specs

  defp command_specs(_result, %Latest{entity_type: entity_type}, conn),
    do: strict_specs_for(entity_type, prefix!(conn))

  defp redact_record(%Latest{field_values: field_values} = record, restricted)
       when is_map(field_values) do
    if MapSet.size(restricted) > 0,
      do: %{record | field_values: FieldGrants.redact_field_values(field_values, restricted)},
      else: record
  end

  defp redact_record(%Latest{} = record, _restricted), do: record

  defp render_record_command(conn, {:error, {:definition_not_found, _entity_type}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_not_found, _record_id}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_payload_invalid, violations}}, _status) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("entity record payload failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # GH #2689: the entity-side size cap. 422 (the body fit the transport; the entity contract is
  # violated). Constant detail, no field name, no size (INV-2).
  defp render_record_command(conn, {:error, {:record_size_exceeded, :record}}, _status),
    do: Response.unprocessable(conn, "entity record exceeds the size limit")

  defp render_record_command(conn, {:error, {:record_size_exceeded, :value}}, _status),
    do: Response.unprocessable(conn, "an entity record field value exceeds the size limit")

  # ⛔ UNREACHABLE through these three routes, and no test drives it
  # (REQ-310 rework round 1, REVIEWER). This is REQ-024's OUTER envelope
  # check firing inside `EventStore.append_multi/3` -- it reports that the
  # EVENT PAYLOAD this router's own delegate constructed violates the
  # registered event-type schema, not that the caller's `field_values` are
  # wrong (that is `{:record_payload_invalid, _}` above, which IS reachable
  # and IS tested). `Letflow.Entities.Records` always builds an envelope
  # satisfying its own registered schema, so reaching this clause would mean
  # an internal construction bug or a schema tightening, not caller input --
  # exactly the framing `req228`'s own design table gives it. Mapped for
  # completeness, per this module's "unreachable but mapped" discipline; it
  # stays a 422 rather than a 500 because design §7's table assigns it one.
  defp render_record_command(conn, {:error, {:payload_validation_failed, _errors}}, _status),
    do: Response.unprocessable(conn, "entity record payload failed validation")

  defp render_record_command(conn, {:error, {:record_already_deleted, _record_id}}, _status),
    do: Response.conflict(conn, "entity record is already deleted")

  defp render_record_command(conn, {:error, :record_version_conflict}, _status),
    do: Response.send_problem(conn, Error.record_version_conflict())

  # GH #2812: a stored restricted value no longer validates; the same constant 403 as a body that
  # names a restricted key, so no restricted field name or value reaches the actor.
  defp render_record_command(conn, {:error, :preserved_value_invalid}, _status),
    do: restricted_fields_refusal(conn)

  defp render_record_command(conn, {:error, {:entity_append_only, _entity_type}}, _status),
    do: Response.send_problem(conn, Error.entity_append_only())

  defp render_record_command(conn, {:error, :idempotency_key_reuse}, _status),
    do: Response.send_problem(conn, Error.idempotency_key_reuse())

  # GH #2654: the write overlapped an activation of its type (re-checked under the
  # type's sequence lock). Nothing was appended; a retry re-resolves and
  # re-validates, so it is safe. Constant body (no type, no values).
  defp render_record_command(conn, {:error, {:definition_changed, _entity_type}}, _status),
    do: Response.conflict(conn, "entity definition changed during the write; retry")

  # GH #2583: reachable only when the managed-type read and the row
  # `Records` resolved disagree (a race); answers the guard's constant 403.
  defp render_record_command(conn, {:error, :entity_type_managed}, _status),
    do: Response.send_problem(conn, Error.entity_type_managed())

  # REQ-518 (2c-ii): the in-transaction scope recheck (old or new value; the race backstop of
  # the pre-checks above). The same bytes as the by-id 404 (decision 0051 D7); counted, not audited.
  defp render_record_command(conn, {:error, :scope_refused}, _status),
    do: scope_refused(conn, :EntitiesRecordsWrite, :write_value)

  # REQ-607 (decision 0065 D8 E-3): the pre-write hook could not complete the write (a lock timeout,
  # a deadlock or a statement timeout; or three fingerprint mismatches in a row). Nothing was
  # appended and a retry is safe. One constant body for both codes: no record data, script key,
  # version or error text.
  defp render_record_command(conn, {:error, :entity_write_contention}, _status),
    do: Response.service_unavailable(conn, @hook_unavailable)

  # REQ-618 (decision 0065 D6, slice E-4): one constant `{"error": "<code>"}` body per hook code,
  # nothing else in it. Placed before the logged 500, so none of these codes reaches it.
  defp render_record_command(conn, {:error, code}, _status)
       when code in [:derived_value_conflict, :script_busy],
       do: hook_error(conn, 503, code)

  defp render_record_command(conn, {:error, :script_rejected}, _status),
    do: hook_error(conn, 409, :script_rejected)

  defp render_record_command(conn, {:error, code}, _status)
       when code in [
              :script_error,
              :budget_exceeded,
              :memory_limit_exceeded,
              :timeout,
              :output_invalid
            ],
       do: hook_error(conn, 422, code)

  # The manifest-declared fail code (a binary the publisher declared in `fail_codes`).
  defp render_record_command(conn, {:error, {:script_failed, code}}, _status)
       when is_binary(code),
       do: hook_error(conn, 422, code)

  defp render_record_command(conn, {:error, reason}, _status)
       when reason in [:tenant_not_provisioned, :invalid_schema_name],
       do: Response.internal_error(conn)

  defp render_record_command(conn, {:error, reason}, _status) do
    Logger.warning("entity record command failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  defp hook_error(conn, status, code),
    do: Response.send_json(conn, status, %{"error" => to_string(code)})
end
