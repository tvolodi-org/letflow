defmodule Letflow.Modules.Org.Units do
  @moduledoc """
  Preparation of the org unit writers of module `org` (GH #3618 / REQ-495): `create_unit/3`,
  `update_unit/4`, `move_unit/4` and `retire_unit/3`, called through `Letflow.Modules.Org`.

  This module only checks arguments and state and builds a write plan. Every `Records` and audit
  call stays in `Letflow.Modules.Org.Masters`, whose transaction runner takes the tenant advisory
  lock (`<prefix>:org_legal_entity_bin`), then the lock of the scope tree index, and keeps the
  index (`Letflow.ScopeNodePaths.write/2`) in the same transaction as the record write and its one
  audit entry (`org_unit.created|renamed|updated|moved|retired`). A refusal of the tree index
  (`:cycle`, `:depth_exceeded`, `:node_has_grants`, ...) comes back unchanged and rolls back the
  record write. No function takes a caller identity, a scope set or a tenant id; `prefix` comes
  from the authenticated tenant on the server side.

  Unit ids and parent ids are canonical lowercase uuids; an unknown, soft-deleted, other-type or
  other-tenant id gets the same `:unit_not_found` / `:parent_not_found` (INV-5).

  Limits: the balance guard of a retire (D-065) is not built, since no module posts balances to a
  register naming an org unit yet; the first slice that does adds it to `retire_unit/3`. A unit
  record written without `create_unit/3` (a fixture) has no index row, so move and retire answer
  `:node_not_found` for it.
  """

  alias Letflow.Modules.Org.Masters
  alias Letflow.Modules.ReadApi

  @unit "org_unit"
  @site "org_site"
  @create_keys ~w(code name legal_entity_id site_id parent external_ref_system external_ref_id)
  @update_keys ~w(name legal_entity_id site_id external_ref_system external_ref_id)

  @doc """
  Creates a unit. `attrs` (string keys): `code`, `name`, `legal_entity_id`, `site_id` required;
  `parent` (nil or absent is a root), `external_ref_system`, `external_ref_id` optional.
  Refusals: `{:field_not_allowed, key}`, `{:field_invalid, key}`, `:parent_not_found`,
  `:parent_inactive`, `:legal_entity_not_found`, `:legal_entity_inactive`, `:site_not_found`,
  `:site_inactive`, `:depth_exceeded`, `{:record_payload_invalid, _}` (duplicate code or
  external reference).
  """
  @spec create_unit(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_unit(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "create_unit/3")

    Masters.run(prefix, attrs, actor, idem, "org_unit.created", @unit, fn replay? ->
      prepare_create(prefix, attrs, replay?)
    end)
  end

  @doc """
  Changes `name`, `legal_entity_id`, `site_id`, `external_ref_system`, `external_ref_id`.
  `code`, `parent` (use `move_unit/4`), `active` and any other key is `{:field_not_allowed, key}`.
  Audit action `org_unit.renamed` when the name changes, else `org_unit.updated`; an update that
  changes nothing writes nothing.
  """
  @spec update_unit(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_unit(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "update_unit/4")

    Masters.run(prefix, attrs, actor, idem, "org_unit.updated", @unit, fn replay? ->
      prepare_update(prefix, id, attrs, replay?)
    end)
  end

  @doc """
  Moves a unit (and so its subtree) under `new_parent_id` (nil makes it a root). Refusals:
  `:unit_not_found`, `:unit_inactive`, `:parent_not_found`, `:parent_inactive`, `:cycle`,
  `:depth_exceeded`. The same parent writes nothing. Only the `parent` field changes.
  """
  @spec move_unit(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def move_unit(prefix, unit_id, new_parent_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "move_unit/4")

    Masters.run(prefix, %{}, actor, idem, "org_unit.moved", @unit, fn replay? ->
      prepare_move(prefix, unit_id, new_parent_id, replay?)
    end)
  end

  @doc """
  Retires a unit (`active` false); its children stay live. Already retired: `{:ok, map}` with no
  write. Refused with `:unit_has_active_staff` while an active employee or position names it, and
  with `:node_has_grants` while a scope grant names it.
  """
  @spec retire_unit(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_unit(prefix, unit_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "retire_unit/3")

    Masters.run(prefix, %{}, actor, idem, "org_unit.retired", @unit, fn replay? ->
      prepare_retire(prefix, unit_id, replay?)
    end)
  end

  # --- preparation ----------------------------------------------------------------------------

  defp prepare_create(prefix, attrs, replay?) do
    with :ok <- Masters.check_keys(attrs, @create_keys),
         :ok <- Masters.check_required_text(attrs, "code"),
         :ok <- Masters.check_required_text(attrs, "name"),
         :ok <- Masters.check_ext(attrs),
         {:ok, parent} <- check_parent(prefix, Map.get(attrs, "parent"), replay?),
         {:ok, company_id} <-
           Masters.check_company(prefix, Map.get(attrs, "legal_entity_id"), replay?),
         {:ok, site_id} <- check_site(prefix, Map.get(attrs, "site_id"), replay?) do
      fv =
        attrs
        |> Masters.drop_nils()
        |> Map.put("legal_entity_id", company_id)
        |> Map.put("site_id", site_id)
        |> Map.put("active", true)
        |> put_or_drop("parent", parent)

      {:write, :create, nil, nil, fv, %{tree: {:after_insert, parent}}}
    end
  end

  defp prepare_update(prefix, id, attrs, replay?) do
    with {:ok, rec} <- Masters.fetch(prefix, id, @unit, :unit_not_found),
         :ok <- Masters.check_keys(attrs, @update_keys),
         :ok <- Masters.check_optional_required_text(attrs, "name"),
         :ok <- Masters.check_ext(attrs),
         {:ok, attrs} <- cast_refs(prefix, attrs, replay?) do
      fv = Masters.merged(rec, attrs)

      if fv == Masters.state(rec) do
        {:noop, rec}
      else
        action = if fv["name"] != rec["name"], do: "org_unit.renamed", else: "org_unit.updated"
        {:write, :update, rec["record_id"], Masters.state(rec), fv, %{action: action}}
      end
    end
  end

  defp prepare_move(prefix, unit_id, new_parent_id, replay?) do
    with {:ok, rec} <- Masters.fetch(prefix, unit_id, @unit, :unit_not_found),
         :ok <- check_active(rec, replay?),
         {:ok, parent} <- check_parent(prefix, new_parent_id, replay?) do
      if rec["parent"] == parent do
        {:noop, rec}
      else
        id = rec["record_id"]
        fv = rec |> Masters.state() |> put_or_drop("parent", parent)

        {:write, :update, id, Masters.state(rec), fv, %{tree: {:before, {:move, id, parent}}}}
      end
    end
  end

  defp prepare_retire(prefix, unit_id, replay?) do
    with {:ok, rec} <- Masters.fetch(prefix, unit_id, @unit, :unit_not_found) do
      id = rec["record_id"]

      cond do
        rec["active"] == false ->
          {:noop, rec}

        not replay? and
            Masters.named_by_active?(prefix, ["org_employee", "org_position"], "org_unit_id", id) ->
          {:error, :unit_has_active_staff}

        true ->
          {:write, :update, id, Masters.state(rec),
           rec |> Masters.state() |> Map.put("active", false), %{tree: {:before, {:retire, id}}}}
      end
    end
  end

  # nil / absent is a root. On replay the first call checked liveness.
  defp check_parent(_prefix, nil, _replay?), do: {:ok, nil}

  defp check_parent(prefix, value, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, parent} <- ReadApi.lookup(prefix, uuid, [@unit]) do
      if replay? or parent["active"] == true, do: {:ok, uuid}, else: {:error, :parent_inactive}
    else
      _ -> {:error, :parent_not_found}
    end
  end

  defp check_active(rec, replay?) do
    if replay? or rec["active"] == true, do: :ok, else: {:error, :unit_inactive}
  end

  defp check_site(prefix, value, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, site} <- ReadApi.lookup(prefix, uuid, [@site]) do
      if replay? or site["active"] == true, do: {:ok, uuid}, else: {:error, :site_inactive}
    else
      _ -> {:error, :site_not_found}
    end
  end

  defp cast_refs(prefix, attrs, replay?) do
    with {:ok, attrs} <-
           cast_ref(attrs, "legal_entity_id", &Masters.check_company(prefix, &1, replay?)),
         {:ok, attrs} <- cast_ref(attrs, "site_id", &check_site(prefix, &1, replay?)) do
      {:ok, attrs}
    end
  end

  defp cast_ref(attrs, key, check) do
    if Map.has_key?(attrs, key) do
      with {:ok, uuid} <- check.(attrs[key]), do: {:ok, Map.put(attrs, key, uuid)}
    else
      {:ok, attrs}
    end
  end

  defp put_or_drop(map, key, nil), do: Map.delete(map, key)
  defp put_or_drop(map, key, value), do: Map.put(map, key, value)
end
