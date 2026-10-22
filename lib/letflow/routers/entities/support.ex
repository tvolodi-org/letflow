defmodule Letflow.Routers.Entities.Support do
  @moduledoc """
  Request helpers shared by `Letflow.Routers.Entities` and its handler modules
  (`RecordWrites`, `RecordImport`, `RecordAttachments`), extracted from the router
  under GH #2833. Each function is a pure function of its arguments.

  `prefix!/1` is still the one source of the tenant prefix (INV-1): it reads
  `conn.assigns.scoped_opts` and nothing else.
  """

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Entities.Definition.Validator.Violation, as: DefinitionViolation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.ScopedWrites
  alias Letflow.EventStore.Registry.ValidationFailure

  @spec strict_specs_for(String.t(), String.t()) :: Decimals.specs()
  def strict_specs_for(entity_type, prefix), do: Definitions.strict_specs(entity_type, prefix)

  # `tenant_id` is deliberately NOT in this allowlist -- a caller is already
  # scoped to exactly one tenant and echoing the id back adds nothing but a
  # tenant identifier on the wire.
  @spec record_map(Latest.t(), Decimals.specs()) :: map()
  def record_map(%Latest{} = record, specs) do
    %{
      "record_id" => record.record_id,
      "entity_type" => record.entity_type,
      "field_values" => Decimals.render_field_values(record.field_values, specs),
      "deleted" => record.deleted,
      "entity_def_version" => Base.encode16(record.entity_def_version, case: :lower),
      "last_event_global_seq" => record.last_event_global_seq
    }
  end

  # INV-1: the ONE source of prefix on every route in this module. Never a
  # path, query or body value.
  #
  # Every delegate in `Letflow.Entities.*` takes a BARE `prefix ::
  # String.t()` positional argument (see each one's own @spec), not the
  # `[prefix: schema]` keyword list `Letflow.Routers.Definitions`/
  # `Letflow.Routers.Instances` hand straight to their own
  # `Letflow.Definitions.*`/`Letflow.Repository.*` delegates as `opts`. So
  # this router unwraps `conn.assigns.scoped_opts` here rather than passing
  # it through -- the difference is in the delegates' signatures, not in
  # where the value comes from, which is identical to every other router.
  # `Keyword.fetch!/2` deliberately raises rather than defaulting: reaching a
  # handler without `:scoped_opts` assigned is structurally impossible
  # (`Letflow.Plugs.Authorize` assigns it before `:dispatch` or halts), and a
  # silent default would be a tenant-scoping bug, not a recoverable one.
  @spec prefix!(Plug.Conn.t()) :: String.t()
  def prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  def object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  def validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # The two violation shapes this module can receive have DISJOINT fields, so
  # each gets its own clause rather than one Map.get-based reader that would
  # silently emit nils for whichever shape it was not written against:
  #
  #   * Letflow.Entities.Definition.Validator.Violation -- rule/path/message
  #     (from create_definition/2's {:validation, violations});
  #   * Letflow.EventStore.Registry.ValidationFailure -- field_path/
  #     constraint/actual (from Records' {:record_payload_invalid, violations}).
  #
  # Both become plain string-keyed maps: Letflow.Api.Error.serialise/1's
  # `errors: [_ | _]` clause hands the list straight to Jason.encode!/1.
  # `actual` (the caller's own rejected value) is deliberately NOT echoed --
  # it adds nothing the caller does not already have and keeps this body free
  # of arbitrary tenant data.
  @spec violation_map(DefinitionViolation.t() | ValidationFailure.t()) :: map()
  def violation_map(%DefinitionViolation{rule: rule, path: path, message: message}) do
    %{
      "code" => Atom.to_string(rule),
      "path" => Enum.map(path, &to_string/1),
      "message" => message
    }
  end

  def violation_map(%ValidationFailure{field_path: field_path, constraint: constraint}) do
    %{
      "code" => constraint,
      "path" => field_path,
      "message" => "#{field_path} violates #{constraint}"
    }
  end

  # Casting here (rather than letting Latest.get/3 receive a non-UUID string)
  # keeps a malformed id on the same zero-detail 404 path as an absent one.
  def cast_record_id(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, record_id} -> {:ok, record_id}
      :error -> {:error, :invalid_record_id}
    end
  end

  # REQ-518 (2c-ii) type gate of a scoped caller's CREATE and IMPORT: a hidden (denied or absent)
  # type, an undeclared type and a `:tenant_wide` master are one refusal, so a nonexistent type
  # name gives exactly the same answer as an undeclared one (SEC C-6). `:all` is not gated.
  def write_type_gate(_access, _entity_type, :all, _prefix), do: {:ok, :unscoped}
  def write_type_gate(:hidden, _entity_type, _scope, _prefix), do: :refused

  def write_type_gate({:open, _restricted}, entity_type, scope, prefix),
    do: ScopedWrites.type_gate(entity_type, scope, prefix)

  # The shared 403 detail of every restricted-field refusal (GH #2697 for the query routes, GH #2784
  # for the record writes): one constant, never a field, entity type or clause name.
  @restricted_fields_detail "one or more requested fields are restricted for this caller"

  def restricted_fields_refusal(conn), do: Response.forbidden(conn, @restricted_fields_detail)
end
