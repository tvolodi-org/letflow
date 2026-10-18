defmodule Letflow.Entities.ImportUpsert do
  @moduledoc """
  The `"upsert_by": "external_ref"` half of `POST /entities/records/:entity_type/import`
  (GH #2659 / REQ-505 PR 3; design `lib/letflow/design/gh2659-external-ref-idempotent-import.md`
  sections 4.5, 5.2, 5.3, 5.4). The router stays thin and Repo-free: it calls `precheck/3` once
  per request, then `run/6`, and shapes the returned entry results into JSON.

  ## `precheck/3` (once per request, before any entry is written)

  Does ALL four reads unconditionally and in this order, then decides, so that a denied type, an
  absent type and an outdated schema all do the same database work (the model is
  `Letflow.Entities.RequestAccess`, #2700): `TypeAccess.authorized?/3`, the active-definition
  existence read, `FieldGrants.load_restrictions/3`, and ONE
  `Registry.max_schema_version("ENTITY_RECORD_CREATED", prefix)`. A denied OR absent type (or any
  failed read) is the one `{:error, :not_found}`; a CREATED schema below v2 is
  `{:error, :event_schema_outdated}` (a tenant not yet replayed, design 2.4).

  ## `run/6` (per entry, sequential, per-entry report not whole-file rollback, design 5.4)

  Each entry is one `Records.upsert_record_by_external_ref/2` call with a server-derived
  idempotency key (`idempotency_key/2`). Before the call, in this order:

    1. the entry's `external_ref` must parse (`ExternalRef.parse/1`), else `:external_ref_invalid`;
    2. a ref already seen earlier in the file is `:duplicate_external_ref_in_request` (the first
       occurrence proceeds);
    3. write-side field restrictions, as step writes apply them: an entry naming a restricted
       field is `:field_restricted`; and if the actor has ANY restricted field on the type, an
       entry whose ref matches an existing record (live or deleted) is `:field_restricted` BEFORE
       any compare, so `unchanged` / `updated` cannot probe or erase a field the actor cannot see.

  Every error reason is a constant atom; none carries the entry's `system` or `id`. The
  primitive's `{:external_ref_record_deleted, ref}` is reduced to the bare atom here, so the ref
  never reaches the router, a response or a log.

  The lookup of step 3 and the upsert are two statements; a record created for the same ref by a
  DIFFERENT writer between them can make a restricted actor's entry resolve as `unchanged` or
  `updated` instead of `created` (a residual window of one concurrent writer, design 4.5 keeps
  the pre-check as a hint and the unique index as the arbiter).
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.TypeAccess
  alias Letflow.EventStore.Registry

  @created_event_type "ENTITY_RECORD_CREATED"
  @min_created_schema_version 2

  @type entry_result ::
          {:ok,
           %{
             record_id: Ecto.UUID.t(),
             source_record_id: term(),
             outcome: :created | :updated | :unchanged,
             external_ref: ExternalRef.t()
           }}
          | {:error, source_record_id :: term(), {:error, term()}}

  @doc """
  The per-request pre-check; returns the actor's restriction set on success. See the moduledoc.
  """
  @spec precheck(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :not_found | :event_schema_outdated}
  def precheck(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    # All four reads, no short-circuit (design 5.2 step 1).
    access = TypeAccess.authorized?(user_id, entity_type, prefix)
    definition = Definitions.get_active_definition_by_name(entity_type, prefix)
    restrictions = FieldGrants.load_restrictions(user_id, entity_type, prefix)
    version = Registry.max_schema_version(@created_event_type, prefix)

    with {:ok, :allowed} <- access,
         {:ok, _definition} <- definition,
         {:ok, restricted} <- restrictions do
      if is_integer(version) and version >= @min_created_schema_version,
        do: {:ok, restricted},
        else: {:error, :event_schema_outdated}
    else
      # Denied, absent, and any failed read are one exit: fail closed, indistinguishable.
      _denied_or_absent -> {:error, :not_found}
    end
  end

  @doc """
  The server-derived idempotency key of one upsert entry (design 5.3): exactly 128 bytes for any
  `id`, far under the 255 byte column a raw 255 byte id would risk. Never client-supplied.
  """
  @spec idempotency_key(request_id :: String.t(), ExternalRef.t()) :: String.t()
  def idempotency_key(request_id, %{system: system, id: id}) when is_binary(request_id) do
    digest = :crypto.hash(:sha256, [system, 0, id]) |> Base.encode16(case: :lower)
    "entities-record-import:#{request_id}:ext:#{digest}"
  end

  @doc """
  Imports `entries` in order and returns one `t:entry_result/0` per entry.
  """
  @spec run(
          entries :: [term()],
          entity_type :: String.t(),
          actor_id :: String.t(),
          import_request_id :: String.t(),
          restricted :: MapSet.t(String.t()),
          prefix :: String.t()
        ) :: [entry_result()]
  def run(entries, entity_type, actor_id, import_request_id, restricted, prefix) do
    ctx = %{
      entity_type: entity_type,
      actor_id: actor_id,
      request_id: import_request_id,
      restricted: restricted,
      prefix: prefix
    }

    {results, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn entry, seen -> import_entry(entry, seen, ctx) end)

    results
  end

  defp import_entry(entry, seen, ctx) do
    source_record_id = source_record_id(entry)

    case entry |> entry_ref() |> ExternalRef.parse() do
      {:error, :external_ref_invalid} ->
        {failure(source_record_id, :external_ref_invalid), seen}

      {:ok, %{system: system, id: id} = ref} ->
        if MapSet.member?(seen, {system, id}) do
          {failure(source_record_id, :duplicate_external_ref_in_request), seen}
        else
          {upsert_entry(entry, ref, source_record_id, ctx), MapSet.put(seen, {system, id})}
        end
    end
  end

  defp upsert_entry(entry, ref, source_record_id, ctx) do
    field_values = Map.get(entry, "field_values", %{})

    case check_restrictions(field_values, ref, ctx) do
      :ok ->
        attrs = %{
          entity_type: ctx.entity_type,
          external_ref: %{"system" => ref.system, "id" => ref.id},
          field_values: field_values,
          actor_id: ctx.actor_id,
          idempotency_key: idempotency_key(ctx.request_id, ref)
        }

        case Records.upsert_record_by_external_ref(attrs, ctx.prefix) do
          {:ok, %{record: %Latest{record_id: record_id}, outcome: outcome}} ->
            {:ok,
             %{
               record_id: record_id,
               source_record_id: source_record_id,
               outcome: outcome,
               external_ref: ref
             }}

          # The tuple carries the caller's own ref: reduce it before it can be serialised or logged.
          {:error, {:external_ref_record_deleted, _ref}} ->
            failure(source_record_id, :external_ref_record_deleted)

          {:error, reason} ->
            {:error, source_record_id, {:error, reason}}
        end

      {:error, reason} ->
        failure(source_record_id, reason)
    end
  end

  defp check_restrictions(field_values, ref, %{restricted: restricted} = ctx) do
    cond do
      MapSet.size(restricted) == 0 ->
        :ok

      is_map(field_values) and Enum.any?(Map.keys(field_values), &MapSet.member?(restricted, &1)) ->
        {:error, :field_restricted}

      # Any restricted field on the type: an existing record (live or deleted) is refused before
      # the compare. A failed lookup refuses too (fail closed).
      true ->
        case Latest.get_by_external_ref(ctx.entity_type, ref.system, ref.id, ctx.prefix) do
          {:error, :not_found} -> :ok
          _existing_or_error -> {:error, :field_restricted}
        end
    end
  end

  defp failure(source_record_id, reason), do: {:error, source_record_id, {:error, reason}}

  defp source_record_id(%{} = entry), do: Map.get(entry, "record_id")
  defp source_record_id(_entry), do: nil

  defp entry_ref(%{} = entry), do: Map.get(entry, "external_ref")
  defp entry_ref(_entry), do: nil
end
