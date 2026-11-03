defmodule Letflow.Modules.Codes do
  @moduledoc """
  Foundation module `codes` (GH #3588 / REQ-648, assets phase A item A5; decisions 0076, 0050 D2/D3,
  owner decisions D-065 to D-067): codes for tags and labels (barcode, QR, EPC, TID).

  Three managed types, shipped by the pack `priv/modules/codes/pack.json` (generated from
  `priv/modules/codes/entity_definitions/` by `priv/modules/codes/generate_pack.exs`):
  `code_tag` (the code record: one tag or label), `code_assignment` (one row of the assignment
  history) and `code_value_change` (one row of the value history). `code_id` of the two history types
  is a real foreign key onto `code_tag` (D-066), promoted at install; `target_type` / `target_id` are
  declarative and not validated here (0050 D3.5 and D3.6): the module that writes or reads a code
  validates the target through the owning module's lookup.

  ## Model rules

    * R1 the record id of a code never changes; everything names this id.
    * R2 the value is unique in the tenant over every status (`uq_code_tag_value`), compared exactly
      (no trimming, no case folding). "Tenant" means the tenant schema: two tenants never clash.
    * R3 the value of a rewritable tag may change; old values stay in `code_value_change`.
    * R4 at most one open assignment (`released_at` empty) per code; status is `assigned` exactly then.
      No storage guard exists (no partial unique index); the write functions of REQ-663 keep it.
    * R5 assignment and value-history rows are never deleted; an assignment changes once, when closed.
    * R6 a scan resolves only through the open assignment.
    * R7 a `retired` code never comes back.
    * R8 movements and ledger rows name the object's record id, never the code.

  The types are declared in `manages_entity_types`, so after install the generic entity routes answer
  403 `entity_type_managed`. The write routes (GH #3611 / REQ-667, version 0.2.0, `Letflow.Modules.Codes.Router`) are gated by the module
  permission `:CodesWrite`; no role grants (only TENANT_ADMIN and PLATFORM_ADMIN hold it). The write functions are in
  `Letflow.Modules.Codes.Writes` (GH #3615 / REQ-663): `receive_codes/3` (bulk, at most 1000 entries,
  UAT assumption), `assign_code/5` (targets `location_node`, `catalog_item`, `catalog_lot`),
  `release_code/3`, `retire_code/3` and `change_code_value/4`. The routes call them.

  ## Scope (D-067, decision 0051 M4)

  All three types are `:tenant_wide` in `scope_declarations`, immutable once set. `resolve/2` and the
  other read functions take no principal and apply no scope: a scan route must check the scope of
  the resolved target (`Letflow.Api.Scope.allowed?/3`) and answer an out-of-scope target with the
  same 404 as an unknown code.

  ## Read API contract

  `prefix` must be derived server-side from the authenticated tenant, never from HTTP input:
  isolation is by `prefix` alone. The never-raise guarantee holds for a provisioned tenant prefix.
  Every value is bound as a query parameter (INV-7). There is no `active?/2`: the code types have no
  `active` field and no other module references a code by id (R8).

  `on_install/3` activates and promotes the packed definitions inside the install transaction
  (decision 0052 D2) through `Letflow.Modules.EntityActivation`, `code_tag` first so that the foreign
  keys of the history types find their target table.
  """

  @behaviour Letflow.Modules.Module

  import Ecto.Query, only: [from: 2]
  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.EntityActivation
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types ["code_tag", "code_assignment", "code_value_change"]

  @impl true
  defmanifest(
    id: "codes",
    version: "0.2.0",
    depends_on: [],
    pack: "modules/codes/pack.json",
    permissions: [:CodesWrite],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/receive", :CodesWrite},
      {"POST", "/:id/assign", :CodesWrite},
      {"POST", "/:id/release", :CodesWrite},
      {"POST", "/:id/retire", :CodesWrite},
      {"POST", "/:id/value", :CodesWrite}
    ],
    manages_entity_types: ["code_tag", "code_assignment", "code_value_change"],
    scope_declarations: %{
      "code_tag" => :tenant_wide,
      "code_assignment" => :tenant_wide,
      "code_value_change" => :tenant_wide
    }
  )

  @impl true
  def router, do: Letflow.Modules.Codes.Router

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, @types)
  end

  @doc "Receives new tags in bulk as not assigned (GH #3615 / REQ-663); see `Letflow.Modules.Codes.Writes`."
  defdelegate receive_codes(prefix, entries, opts), to: Letflow.Modules.Codes.Writes

  @doc "Assigns a not-assigned code to a master record (GH #3615 / REQ-663); see `Letflow.Modules.Codes.Writes`."
  defdelegate assign_code(prefix, code_id, target_type, target_id, opts),
    to: Letflow.Modules.Codes.Writes

  @doc "Releases an assigned code (GH #3615 / REQ-663); see `Letflow.Modules.Codes.Writes`."
  defdelegate release_code(prefix, code_id, opts), to: Letflow.Modules.Codes.Writes

  @doc "Retires a code for good (GH #3615 / REQ-663); see `Letflow.Modules.Codes.Writes`."
  defdelegate retire_code(prefix, code_id, opts), to: Letflow.Modules.Codes.Writes

  @doc "Changes the value of a rewritable tag (GH #3615 / REQ-663); see `Letflow.Modules.Codes.Writes`."
  defdelegate change_code_value(prefix, code_id, new_value, opts),
    to: Letflow.Modules.Codes.Writes

  @doc """
  The live record `id` (a `record_id` uuid) of any of the three types in tenant schema `prefix`: a map
  with string keys `"record_id"`, `"entity_type"` and every stored field. A non-uuid, unknown or
  soft-deleted id, another type's id and a non-text `prefix` are all `{:error, :not_found}`.
  """
  @spec lookup(prefix :: String.t(), id :: term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id), do: ReadApi.lookup(prefix, id, @types)

  @doc """
  Resolves a scanned text through the open assignment only. Exact, case-sensitive match on the live
  `code_tag` value.

    * no such code, or non-text `scanned_text` / `prefix`: `{:error, :not_found}`
    * status `retired`: `{:error, :code_retired}`
    * `not_assigned` with no open assignment: `{:ok, map}` with nil `"target_type"`, `"target_id"`,
      `"assignment_id"`
    * `assigned` with exactly one open assignment: `{:ok, map}` with that assignment's target
    * any other combination: `{:error, :assignment_conflict}`

  Every `{:ok, map}` has exactly the keys `"code_id"`, `"value"`, `"kind"`, `"status"`,
  `"target_type"`, `"target_id"`, `"assignment_id"`. No scope is applied (see the moduledoc).
  """
  @spec resolve(prefix :: term(), scanned_text :: term()) ::
          {:ok, map()} | {:error, :not_found | :code_retired | :assignment_conflict}
  def resolve(prefix, text) when is_binary(prefix) and is_binary(text) do
    if storable?(text) do
      case tag_by_value(prefix, text) do
        nil -> {:error, :not_found}
        tag -> decide(tag, open_assignments(prefix, tag.record_id))
      end
    else
      {:error, :not_found}
    end
  end

  def resolve(_prefix, _text), do: {:error, :not_found}

  defp decide(%{field_values: %{"status" => "retired"}}, _open), do: {:error, :code_retired}

  defp decide(%{field_values: %{"status" => "not_assigned"}} = tag, []),
    do: {:ok, shape(tag, nil)}

  defp decide(%{field_values: %{"status" => "assigned"}} = tag, [one]),
    do: {:ok, shape(tag, one)}

  defp decide(_tag, _open), do: {:error, :assignment_conflict}

  @doc """
  One map of the `resolve/2` shape (case iv) for every code that has an open assignment to
  (`target_type`, `target_id`), ordered by value ascending (byte order); the stored status is shown.
  `[]` when there is none or an argument is not text.
  """
  @spec codes_for(prefix :: term(), target_type :: term(), target_id :: term()) :: [map()]
  def codes_for(prefix, target_type, target_id)
      when is_binary(prefix) and is_binary(target_type) and is_binary(target_id) do
    if storable?(target_type) and storable?(target_id) do
      assignments =
        Repo.all(
          from(l in Latest,
            where:
              l.entity_type == "code_assignment" and l.deleted == false and
                fragment("?->>'target_type' = ?", l.field_values, ^target_type) and
                fragment("?->>'target_id' = ?", l.field_values, ^target_id) and
                fragment("?->>'released_at' IS NULL", l.field_values)
          ),
          prefix: prefix
        )

      assignments
      |> Enum.flat_map(fn a ->
        case ReadApi.lookup(prefix, a.field_values["code_id"], ["code_tag"]) do
          {:ok, tag} -> [shape(%{record_id: tag["record_id"], field_values: tag}, a)]
          _ -> []
        end
      end)
      |> Enum.sort_by(& &1["value"])
    else
      []
    end
  end

  def codes_for(_prefix, _target_type, _target_id), do: []

  @doc """
  The assignment rows of a code, open and closed, ordered by `assigned_at` then `assignment_id`.
  `[]` for a non-uuid, unknown or other-tenant id.
  """
  @spec assignment_history(prefix :: term(), code_id :: term()) :: [map()]
  def assignment_history(prefix, code_id) do
    prefix
    |> history_rows("code_assignment", code_id)
    |> Enum.map(fn r ->
      f = r.field_values

      %{
        "assignment_id" => r.record_id,
        "target_type" => f["target_type"],
        "target_id" => f["target_id"],
        "assigned_at" => f["assigned_at"],
        "assigned_by" => f["assigned_by"],
        "released_at" => f["released_at"],
        "released_by" => f["released_by"]
      }
    end)
    |> Enum.sort_by(&{&1["assigned_at"], &1["assignment_id"]})
  end

  @doc "The value changes of a code ordered by `changed_at` (then record id). `[]` as for `assignment_history/2`."
  @spec value_history(prefix :: term(), code_id :: term()) :: [map()]
  def value_history(prefix, code_id) do
    prefix
    |> history_rows("code_value_change", code_id)
    |> Enum.sort_by(&{&1.field_values["changed_at"], &1.record_id})
    |> Enum.map(fn r ->
      f = r.field_values

      %{
        "old_value" => f["old_value"],
        "new_value" => f["new_value"],
        "changed_at" => f["changed_at"],
        "changed_by" => f["changed_by"]
      }
    end)
  end

  defp history_rows(prefix, type, code_id) when is_binary(prefix) do
    case Ecto.UUID.cast(code_id) do
      {:ok, id} ->
        Repo.all(
          from(l in Latest,
            where:
              l.entity_type == ^type and l.deleted == false and
                fragment("?->>'code_id' = ?", l.field_values, ^id)
          ),
          prefix: prefix
        )

      _ ->
        []
    end
  end

  defp history_rows(_prefix, _type, _code_id), do: []

  defp tag_by_value(prefix, text) do
    Repo.one(
      from(l in Latest,
        where:
          l.entity_type == "code_tag" and l.deleted == false and
            fragment("?->>'value' = ?", l.field_values, ^text),
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp open_assignments(prefix, code_id) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "code_assignment" and l.deleted == false and
            fragment("?->>'code_id' = ?", l.field_values, ^code_id) and
            fragment("?->>'released_at' IS NULL", l.field_values)
      ),
      prefix: prefix
    )
  end

  defp shape(tag, assignment) do
    f = tag.field_values

    %{
      "code_id" => tag.record_id,
      "value" => f["value"],
      "kind" => f["kind"],
      "status" => f["status"],
      "target_type" => assignment && assignment.field_values["target_type"],
      "target_id" => assignment && assignment.field_values["target_id"],
      "assignment_id" => assignment && assignment.record_id
    }
  end

  # Postgres rejects NUL in text and invalid UTF-8; such a text cannot be a stored value.
  defp storable?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)
end
