defmodule Letflow.Modules.Org.Masters do
  @moduledoc """
  Write path of the legal company and site masters of module `org` (GH #3619 / REQ-660):
  `create_legal_entity/3`, `update_legal_entity/4`, `retire_legal_entity/3`, `create_site/3`,
  `update_site/4` and `retire_site/3`, called through `Letflow.Modules.Org`. The module is the
  Owner of its types, so the writes go through `Letflow.Entities.Records` with the module
  authority; no route, permission, migration or scope declaration is added, and no function takes
  a caller identity or a scope set.

  Every writer runs in one transaction under one tenant advisory lock (key text
  `<prefix>:org_legal_entity_bin`, a bound parameter). The lock serialises the BIN check of the
  companies and the liveness / in-use checks of sites and companies. REQ-495's unit writers
  (`Letflow.Modules.Org.Units`) take the same lock, then the scope tree index lock. The writer appends one audit entry (`org_legal_entity.created|updated|retired`,
  `org_site.created|updated|retired`) in the same transaction; a refusal writes neither record
  nor audit entry.

  The BIN rule (D-065): exactly 12 ASCII digits, no control digit. Two live companies (`active`
  true) of one tenant never share a BIN; a retired company's BIN may be reused. `bin`,
  `org_unit.legal_entity_id` and `org_unit.site_id` are not queried columns, so these checks read
  `field_values` of the latest-record table with bound parameters.

  A call repeated with the same idempotency key skips the lock and the state-dependent checks
  (`bin_taken`, company liveness, in-use): the first call already changed that state, and
  `Records` answers the replay (the original record, or `:idempotency_key_reuse` for different
  input) without a second record or audit entry.

  `Records.update_record/3` replaces the whole document, so update and retire send the stored
  fields merged with the change. `prefix` must come from the authenticated tenant on the server
  side, never from attrs or opts.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @company "org_legal_entity"
  @site "org_site"
  @company_create_keys ~w(code name bin external_ref_system external_ref_id)
  @company_update_keys ~w(name bin external_ref_system external_ref_id)
  @site_create_keys ~w(code name legal_entity_id external_ref_system external_ref_id)
  @site_update_keys ~w(name legal_entity_id external_ref_system external_ref_id)
  @ext_keys ~w(external_ref_system external_ref_id)
  @kept ["record_id", "entity_type"]

  # --- companies ------------------------------------------------------------------------------

  @doc """
  Creates a legal company. `attrs` (string keys): `code`, `name`, `bin` required;
  `external_ref_system`, `external_ref_id` optional (nil is dropped). Refusals, in order:
  `{:field_not_allowed, key}`, `{:field_invalid, key}` (code, name, bin format, ext texts),
  `:bin_taken`, then the `Records` errors (`{:record_payload_invalid, violations}` for a duplicate
  code or external reference). `opts` is a map with `:actor_id` (uuid) and `:idempotency_key`
  (text); a missing one raises `ArgumentError`. Returns the record map of `Org.lookup/2`.
  """
  @spec create_legal_entity(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_legal_entity(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "create_legal_entity/3")

    run(prefix, attrs, actor, idem, "org_legal_entity.created", @company, fn replay? ->
      prepare_create_company(prefix, attrs, replay?)
    end)
  end

  @doc """
  Changes `name`, `bin`, `external_ref_system`, `external_ref_id` of a company (nil clears an
  external reference). `code`, `active` and any other key is `{:field_not_allowed, key}`. An
  unknown company (or the id of another type or tenant) is `{:error, :legal_entity_not_found}`,
  checked first. A changed `bin` held by another active company is `:bin_taken`.
  """
  @spec update_legal_entity(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_legal_entity(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "update_legal_entity/4")

    run(prefix, attrs, actor, idem, "org_legal_entity.updated", @company, fn replay? ->
      prepare_update_company(prefix, id, attrs, replay?)
    end)
  end

  @doc """
  Retires a company (`active` false). Already retired: `{:ok, map}` with no write and no audit
  entry. Refused with `:legal_entity_in_use` while an active `org_site` or `org_unit` names it.
  """
  @spec retire_legal_entity(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_legal_entity(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "retire_legal_entity/3")

    run(prefix, %{}, actor, idem, "org_legal_entity.retired", @company, fn replay? ->
      prepare_retire_company(prefix, id, replay?)
    end)
  end

  # --- sites ----------------------------------------------------------------------------------

  @doc """
  Creates a site of a live company. `attrs`: `code`, `name`, `legal_entity_id` required; the
  external reference pair optional. `legal_entity_id` that is not the id of a live company is
  `:legal_entity_not_found`; a retired company is `:legal_entity_inactive`.
  """
  @spec create_site(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_site(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "create_site/3")

    run(prefix, attrs, actor, idem, "org_site.created", @site, fn replay? ->
      prepare_create_site(prefix, attrs, replay?)
    end)
  end

  @doc """
  Changes `name`, `legal_entity_id` (same company check as on create), `external_ref_system`,
  `external_ref_id` of a site. `code`, `active` and any other key is `{:field_not_allowed, key}`.
  An unknown site is `{:error, :site_not_found}`, checked first.
  """
  @spec update_site(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_site(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "update_site/4")

    run(prefix, attrs, actor, idem, "org_site.updated", @site, fn replay? ->
      prepare_update_site(prefix, id, attrs, replay?)
    end)
  end

  @doc """
  Retires a site. Already retired: `{:ok, map}`, no write. Refused with `:site_in_use` while an
  active `org_unit` names it in `site_id`.
  """
  @spec retire_site(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_site(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "retire_site/3")

    run(prefix, %{}, actor, idem, "org_site.retired", @site, fn replay? ->
      prepare_retire_site(prefix, id, replay?)
    end)
  end

  # --- transaction ----------------------------------------------------------------------------

  @doc false
  def run(prefix, attrs, actor, idem, action, type, prepare) do
    if is_map(attrs) do
      persist(prefix, actor, idem, action, type, prepare)
    else
      {:error, {:field_invalid, "attrs"}}
    end
  end

  # `prepare.(replay?)` returns `{:write, kind, record_id | nil, before, fv}`, `{:noop, rec}` or
  # `{:error, _}`.
  defp persist(prefix, actor, idem, action, type, prepare) do
    if replay?(prefix, idem) do
      replay(prefix, actor, idem, type, prepare)
    else
      result =
        Repo.transaction(fn ->
          lock!(prefix)

          if replay?(prefix, idem), do: Repo.rollback(:replay_claimed)

          case prepare.(false) do
            {:noop, rec} ->
              rec

            {:write, kind, id, before, fv} ->
              apply_write(prefix, actor, idem, action, type, {kind, id, before, fv}, %{})

            {:write, kind, id, before, fv, extra} ->
              apply_write(prefix, actor, idem, action, type, {kind, id, before, fv}, extra)

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      case result do
        {:error, :replay_claimed} -> replay(prefix, actor, idem, type, prepare)
        other -> other
      end
    end
  end

  # The optional `extra` map of a 6-tuple carries `:action` (overrides the audit action) and
  # `:tree`: `{:before, change}` runs `ScopeNodePaths.write/2` before the record write (move,
  # retire); `{:after_insert, parent}` takes the index table lock before the record write and
  # inserts the index row after it (create). A tree refusal rolls the whole transaction back.
  defp apply_write(prefix, actor, idem, action, type, {kind, id, before, fv}, extra) do
    action = Map.get(extra, :action, action)
    tree = Map.get(extra, :tree)

    with :ok <- tree_before(tree, prefix),
         {:ok, record_id} <- write(prefix, type, kind, id, fv, actor, idem),
         :ok <- tree_after(tree, prefix, record_id),
         {:ok, rec} <- ReadApi.lookup(prefix, record_id, [type]),
         :ok <- audit(prefix, actor, action, type, record_id, before, state(rec)) do
      rec
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp tree_before({:after_insert, _parent}, prefix), do: ScopeNodePaths.lock!(prefix)

  defp tree_before({:before, change}, prefix) do
    case ScopeNodePaths.write(change, prefix) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp tree_before(nil, _prefix), do: :ok

  defp tree_after({:after_insert, parent}, prefix, record_id) do
    case ScopeNodePaths.write({:insert, record_id, parent}, prefix) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp tree_after(_tree, _prefix, _record_id), do: :ok

  # Records detects a replay by failing its own multi, which a surrounding transaction cannot
  # survive: a claimed key goes to Records alone and returns the original or the reuse error.
  defp replay(prefix, actor, idem, type, prepare) do
    with {kind, id, fv} <- replay_plan(prepare.(true)),
         {:ok, record_id} <- write(prefix, type, kind, id, fv, actor, idem) do
      ReadApi.lookup(prefix, record_id, [type])
    else
      {:noop, rec} -> {:ok, rec}
      {:error, _} = err -> err
    end
  end

  defp replay_plan({:write, kind, id, _before, fv}), do: {kind, id, fv}
  defp replay_plan({:write, kind, id, _before, fv, _extra}), do: {kind, id, fv}
  defp replay_plan(other), do: other

  defp replay?(prefix, idem) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem), prefix: prefix)
  end

  defp lock!(prefix) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":org_legal_entity_bin"
    ])

    :ok
  end

  defp write(prefix, type, :create, _id, fv, actor, idem) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: idem}

    # scope-all: SEC-518-R1 (org module, tenant-wide type; own-record system path)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  defp write(prefix, type, :update, id, fv, actor, idem) do
    attrs = %{
      entity_type: type,
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (org module, tenant-wide type; own-record system path)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Org)

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor, action, type, record_id, before, after_state) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: type,
      resource_id: record_id,
      before_state: before,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  # --- preparation: companies -----------------------------------------------------------------

  defp prepare_create_company(prefix, attrs, replay?) do
    with :ok <- check_keys(attrs, @company_create_keys),
         :ok <- check_required_text(attrs, "code"),
         :ok <- check_required_text(attrs, "name"),
         :ok <- check_bin(Map.get(attrs, "bin")),
         :ok <- check_ext(attrs),
         :ok <- check_bin_free(prefix, Map.get(attrs, "bin"), nil, replay?) do
      {:write, :create, nil, nil, attrs |> drop_nils() |> Map.put("active", true)}
    end
  end

  defp prepare_update_company(prefix, id, attrs, replay?) do
    with {:ok, rec} <- fetch(prefix, id, @company, :legal_entity_not_found),
         :ok <- check_keys(attrs, @company_update_keys),
         :ok <- check_optional_required_text(attrs, "name"),
         :ok <- check_update_bin(attrs),
         :ok <- check_ext(attrs),
         :ok <- check_update_bin_free(prefix, rec, attrs, replay?) do
      {:write, :update, rec["record_id"], state(rec), merged(rec, attrs)}
    end
  end

  defp prepare_retire_company(prefix, id, replay?) do
    with {:ok, rec} <- fetch(prefix, id, @company, :legal_entity_not_found) do
      cond do
        rec["active"] == false ->
          {:noop, rec}

        not replay? and
            named_by_active?(
              prefix,
              ["org_site", "org_unit"],
              "legal_entity_id",
              rec["record_id"]
            ) ->
          {:error, :legal_entity_in_use}

        true ->
          {:write, :update, rec["record_id"], state(rec),
           rec |> state() |> Map.put("active", false)}
      end
    end
  end

  defp check_update_bin(attrs) do
    if Map.has_key?(attrs, "bin"), do: check_bin(Map.get(attrs, "bin")), else: :ok
  end

  defp check_update_bin_free(_prefix, _rec, _attrs, true), do: :ok

  defp check_update_bin_free(prefix, rec, attrs, false) do
    if Map.has_key?(attrs, "bin") do
      check_bin_free(prefix, attrs["bin"], rec["record_id"], false)
    else
      :ok
    end
  end

  # --- preparation: sites ---------------------------------------------------------------------

  defp prepare_create_site(prefix, attrs, replay?) do
    with :ok <- check_keys(attrs, @site_create_keys),
         :ok <- check_required_text(attrs, "code"),
         :ok <- check_required_text(attrs, "name"),
         :ok <- check_ext(attrs),
         {:ok, company_id} <- check_company(prefix, Map.get(attrs, "legal_entity_id"), replay?) do
      fv =
        attrs |> drop_nils() |> Map.put("legal_entity_id", company_id) |> Map.put("active", true)

      {:write, :create, nil, nil, fv}
    end
  end

  defp prepare_update_site(prefix, id, attrs, replay?) do
    with {:ok, rec} <- fetch(prefix, id, @site, :site_not_found),
         :ok <- check_keys(attrs, @site_update_keys),
         :ok <- check_optional_required_text(attrs, "name"),
         :ok <- check_ext(attrs),
         {:ok, attrs} <- cast_company(prefix, attrs, replay?) do
      {:write, :update, rec["record_id"], state(rec), merged(rec, attrs)}
    end
  end

  defp prepare_retire_site(prefix, id, replay?) do
    with {:ok, rec} <- fetch(prefix, id, @site, :site_not_found) do
      cond do
        rec["active"] == false ->
          {:noop, rec}

        not replay? and named_by_active?(prefix, ["org_unit"], "site_id", rec["record_id"]) ->
          {:error, :site_in_use}

        true ->
          {:write, :update, rec["record_id"], state(rec),
           rec |> state() |> Map.put("active", false)}
      end
    end
  end

  defp cast_company(prefix, attrs, replay?) do
    if Map.has_key?(attrs, "legal_entity_id") do
      with {:ok, uuid} <- check_company(prefix, attrs["legal_entity_id"], replay?) do
        {:ok, Map.put(attrs, "legal_entity_id", uuid)}
      end
    else
      {:ok, attrs}
    end
  end

  # The company must be a live org_legal_entity. On replay the first call already checked it and
  # the company may have been retired since, so only the uuid cast and existence are re-read.
  @doc false
  def check_company(prefix, value, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, company} <- ReadApi.lookup(prefix, uuid, [@company]) do
      if replay? or company["active"] == true,
        do: {:ok, uuid},
        else: {:error, :legal_entity_inactive}
    else
      _ -> {:error, :legal_entity_not_found}
    end
  end

  # --- shared checks --------------------------------------------------------------------------

  @doc false
  def fetch(prefix, id, type, not_found) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rec} <- ReadApi.lookup(prefix, uuid, [type]) do
      {:ok, rec}
    else
      _ -> {:error, not_found}
    end
  end

  @doc false
  def state(rec), do: Map.drop(rec, @kept)

  # Stored fields merged with the change; a nil value clears the key.
  @doc false
  def merged(rec, attrs) do
    cleared = for {k, nil} <- attrs, do: k
    rec |> state() |> Map.drop(cleared) |> Map.merge(drop_nils(attrs))
  end

  @doc false
  def check_keys(attrs, allowed) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  @doc false
  def check_required_text(attrs, key) do
    v = Map.get(attrs, key)

    if is_binary(v) and String.trim(v) != "", do: :ok, else: {:error, {:field_invalid, key}}
  end

  @doc false
  def check_optional_required_text(attrs, key) do
    if Map.has_key?(attrs, key), do: check_required_text(attrs, key), else: :ok
  end

  @doc false
  def check_ext(attrs) do
    bad =
      Enum.find(@ext_keys, fn k ->
        v = Map.get(attrs, k)
        not is_nil(v) and not is_binary(v)
      end)

    if bad, do: {:error, {:field_invalid, bad}}, else: :ok
  end

  # ASCII digits only, `\z` so a trailing newline fails.
  defp check_bin(bin) do
    if is_binary(bin) and Regex.match?(~r/\A[0-9]{12}\z/, bin),
      do: :ok,
      else: {:error, {:field_invalid, "bin"}}
  end

  defp check_bin_free(_prefix, _bin, _own_id, true), do: :ok

  defp check_bin_free(prefix, bin, own_id, false) do
    base =
      from(r in Latest,
        where:
          r.entity_type == @company and not r.deleted and
            fragment("?->>'bin' = ?", r.field_values, ^bin) and
            fragment("?->>'active' = 'true'", r.field_values)
      )

    query = if own_id, do: from(r in base, where: r.record_id != ^own_id), else: base

    if Repo.exists?(query, prefix: prefix), do: {:error, :bin_taken}, else: :ok
  end

  # True when a live, active record of one of `types` names `id` in `field`. The stored side is
  # lowered because an older caller may store a non-canonical uuid; `id` is the canonical one.
  @doc false
  def named_by_active?(prefix, types, field, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      query =
        from(r in Latest,
          where:
            r.entity_type in ^types and not r.deleted and
              fragment("?->>'active' = 'true'", r.field_values) and
              fragment("lower(?->>?) = ?", r.field_values, type(^field, :string), ^uuid)
        )

      Repo.exists?(query, prefix: prefix)
    else
      _ -> false
    end
  end

  @doc false
  def drop_nils(attrs), do: attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  @doc false
  def opts!(opts, fun) do
    actor = Map.get(opts, :actor_id)
    idem = Map.get(opts, :idempotency_key)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "#{fun} opts :actor_id must be a uuid")

    unless is_binary(idem), do: raise(ArgumentError, "#{fun} opts :idempotency_key must be text")

    {actor, idem}
  end
end
