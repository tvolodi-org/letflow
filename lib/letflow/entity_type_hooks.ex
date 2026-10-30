defmodule Letflow.EntityTypeHooks do
  @moduledoc """
  REQ-567 slice E-1 part 1 (GH #3217, decision 0065 D4/D8) -- the pin of one published
  `entity_write` script version to one entity type: its pre-write hook.

  **Nothing is written by a run.** This module stores, replaces, removes and lists pins and refuses a
  bad pin at bind time. `dry_run/4` is the one function that runs a bound script (REQ-633); it writes
  nothing. The routes are `Letflow.Routers.EntityTypeHooks`.

  `bind/4`, `rebind/4` and `unbind/3` each run one `Ecto.Multi` whose last step is
  `Letflow.Audit.append_multi/4`, so the audit entry and the row change commit or roll back together.
  A real audit failure RAISES inside `Audit.insert_entry/3` (`Repo.transaction/1` does not convert
  raises), so `run_multi/2` rescues it and returns `{:error, {:transaction_failed, exception}}`
  (the shape `Letflow.Definitions` uses); the transaction has rolled back, so no row remains (INV-8).

  Check order: credential, input shape, type exists, type not managed (authority is
  `Letflow.Entities.ManagedTypes`, never request data), the binding row, the script version (found,
  published, `entity_write`, sha256), bound-state, `entity_type_hooked`. Credential and input shape
  come first and say nothing about existence, so an invalid body answers `:invalid_input` for an
  existing and an absent type alike; a valid body on a type absent in this tenant answers `:not_found`
  whatever else the request holds (INV-5/INV-10).

  `entity_type_hooked`: an ACTIVE definition with an `entity_writes` or `module_writes` (handler) line
  on the type refuses the bind (a step write and a pre-write hook on one type is the ambiguity 0065
  closes). Draft, deprecated and archived definitions never match. The activation-time half (refuse
  activating such a definition on a bound type) is NOT built here, so a concurrent activation can
  race with a bind; that is a known gap, not a guarantee.

  Retiring a bound version is refused by `Letflow.Scripts` (`:version_in_use`, via
  `referenced_by_binding?/3`); revoke is never blocked. Every `Repo` call passes `prefix:` (INV-1,
  INV-6), `tenant_id` comes from the prefix, and every query uses bound parameters (INV-7).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.Repo
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantProvisioning

  require Logger

  @hook_kind "entity_write"
  @max_version 2_147_483_647
  @sha ~r/\A[0-9a-f]{64}\z/
  @index :entity_type_hook_bindings_entity_type_index

  @type actor :: %{
          required(:user_id) => String.t() | nil,
          required(:credential) => atom(),
          optional(:trace_id) => String.t() | nil
        }
  @type error ::
          :api_token_not_allowed
          | :invalid_input
          | :not_found
          | :entity_type_managed
          | :script_not_found
          | :script_not_published
          | :hook_kind_mismatch
          | :sha_mismatch
          | :already_bound
          | :entity_type_hooked
          | {:transaction_failed, term()}

  @doc "The tenant's bindings, ordered by entity type."
  @spec list(String.t()) :: [Binding.t()]
  def list(prefix) when is_binary(prefix) do
    Repo.all(from(b in Binding, order_by: [asc: b.entity_type]), prefix: prefix)
  end

  @doc "True when a binding pins `(key, version)`. Used by `Letflow.Scripts` for the retire block."
  @spec referenced_by_binding?(String.t(), String.t(), pos_integer()) :: boolean()
  def referenced_by_binding?(prefix, key, version)
      when is_binary(prefix) and is_binary(key) and is_integer(version) do
    Repo.exists?(
      from(b in Binding, where: b.script_key == ^key and b.script_version == ^version),
      prefix: prefix
    )
  end

  @doc "Pins `params` (`script_key`, `script_version`, `script_sha256`) to `entity_type`."
  @spec bind(String.t(), term(), term(), actor()) :: {:ok, Binding.t()} | {:error, error()}
  def bind(prefix, entity_type, params, actor),
    do: write(:bind, prefix, entity_type, params, actor)

  @doc "Replaces the pin of an already bound `entity_type`."
  @spec rebind(String.t(), term(), term(), actor()) :: {:ok, Binding.t()} | {:error, error()}
  def rebind(prefix, entity_type, params, actor),
    do: write(:rebind, prefix, entity_type, params, actor)

  @doc "Removes the pin of `entity_type`; `{:error, :not_found}` when none exists."
  @spec unbind(String.t(), term(), actor()) :: {:ok, Binding.t()} | {:error, error()}
  def unbind(prefix, entity_type, actor), do: write(:unbind, prefix, entity_type, nil, actor)

  @stat_keys [:instructions_used, :heap_words_at_end, :duration_us]

  @doc """
  REQ-633 (GH #3530, decision 0065 D9 E-5): runs the script bound to `entity_type` on the draft
  `candidate`, with real reads under `prefix`, and returns what it derived. Writes nothing: no
  record, event, sequence or audit row (the audit row is part B). The binding is read without a
  lock or a transaction (`EntityWrite.run_audited/4` must not run inside one when it declares reads).

  `{:error, :api_token_not_allowed}` for a non-OIDC credential (the script reads tenant rows);
  `{:error, :not_found}` for an absent, unbound or foreign type alike (only `prefix` is queried).
  A script outcome other than success is still `{:ok, _}` with the outcome name.
  """
  @spec dry_run(String.t(), term(), map(), actor()) ::
          {:ok,
           %{outcome: String.t(), derived: map() | nil, fail_code: String.t() | nil, stats: map()}}
          | {:error, :api_token_not_allowed | :not_found}
  def dry_run(prefix, entity_type, candidate, actor)
      when is_binary(prefix) and is_map(candidate) do
    with :ok <- require_interactive(actor),
         {:ok, type} <- type_name(entity_type),
         %Binding{} = binding <- Repo.get_by(Binding, [entity_type: type], prefix: prefix) do
      pin = %{
        script_key: binding.script_key,
        script_version: binding.script_version,
        script_sha256: binding.script_sha256
      }

      facts = %{entity_type: type, candidate: candidate, now: DateTime.utc_now()}

      {result, _hmac} =
        EntityWrite.run_audited(prefix, pin, facts, publisher_may_restricted?: false)

      {:ok, dry_run_result(result)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp dry_run_result({:ok, %{derived: derived, stats: stats}}),
    do: %{outcome: "ok", derived: derived, fail_code: nil, stats: Map.take(stats, @stat_keys)}

  defp dry_run_result({:error, {:script_failed, code}, stats}),
    do: %{
      outcome: "script_failed",
      derived: nil,
      fail_code: code,
      stats: Map.take(stats, @stat_keys)
    }

  # D6 has no tenant code for `input_invalid`; `Entities.WriteHook` normalises it the same way.
  defp dry_run_result({:error, :input_invalid, stats}),
    do: %{
      outcome: "script_rejected",
      derived: nil,
      fail_code: nil,
      stats: Map.take(stats, @stat_keys)
    }

  defp dry_run_result({:error, code, stats}) when is_atom(code),
    do: %{
      outcome: Atom.to_string(code),
      derived: nil,
      fail_code: nil,
      stats: Map.take(stats, @stat_keys)
    }

  # ── shared path ──────────────────────────────────────────────────────────────

  defp write(mode, prefix, entity_type, params, actor) do
    with :ok <- require_interactive(actor),
         {:ok, pin} <- parse_params(mode, params),
         {:ok, type} <- type_name(entity_type),
         {:ok, tenant_id} <- tenant_id(prefix) do
      run_multi(prefix, multi(mode, prefix, tenant_id, type, pin, actor))
    end
  end

  # One Multi: the checks run as the first step (so their locks are held until commit), then the
  # row write, then the audit entry (`Audit.append_multi/4`) built from the written row.
  defp multi(mode, prefix, tenant_id, type, pin, actor) do
    Multi.new()
    |> Multi.run(:checked, fn _repo, _changes -> checks(mode, prefix, type, pin) end)
    |> Multi.merge(fn %{checked: existing} ->
      write_multi(mode, prefix, tenant_id, type, pin, existing, actor)
    end)
  end

  defp checks(mode, prefix, type, pin) do
    with :ok <- require_type(prefix, type),
         :ok <- require_unmanaged(prefix, type),
         _ <- ManagedTypes.lock_names([type], prefix),
         existing = Repo.one(binding_query(type), prefix: prefix),
         :ok <- require_pin(mode, prefix, pin),
         :ok <- require_mode(mode, existing),
         :ok <- require_not_hooked(mode, prefix, type) do
      {:ok, existing}
    end
  end

  defp write_multi(:bind, prefix, tenant_id, type, pin, nil, actor) do
    changeset =
      %Binding{tenant_id: tenant_id, entity_type: type, bound_by: actor.user_id}
      |> Ecto.Changeset.change(pin_fields(pin))
      |> Ecto.Changeset.unique_constraint(:entity_type, name: @index)

    Multi.new()
    |> Multi.insert(:binding, changeset, prefix: prefix)
    |> audit("entity_type_hook.bound", nil, :after, actor, prefix)
  end

  defp write_multi(:rebind, prefix, _tenant_id, _type, pin, existing, actor) do
    changeset =
      existing
      |> Ecto.Changeset.change(Map.put(pin_fields(pin), :bound_by, actor.user_id))
      |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())

    Multi.new()
    |> Multi.update(:binding, changeset, prefix: prefix)
    |> audit("entity_type_hook.rebound", state(existing), :after, actor, prefix)
  end

  defp write_multi(:unbind, prefix, _tenant_id, _type, _pin, existing, actor) do
    Multi.new()
    |> Multi.delete(:binding, existing, prefix: prefix)
    |> audit("entity_type_hook.unbound", state(existing), :none, actor, prefix)
  end

  defp audit(multi, action, before_state, after_mode, actor, prefix) do
    Multi.merge(multi, fn %{binding: binding} ->
      Audit.append_multi(
        Multi.new(),
        :audit,
        %{
          actor_id: actor.user_id,
          action: action,
          resource_type: "entity_type_hook_binding",
          resource_id: binding.id,
          before_state: before_state,
          after_state: if(after_mode == :after, do: state(binding)),
          trace_id: Map.get(actor, :trace_id)
        },
        prefix
      )
    end)
  end

  # A real audit failure RAISES inside `Audit.insert_entry/3`; the transaction has rolled back, so
  # no row remains. Only the exception module is logged (INV-4), never its message.
  defp run_multi(prefix, multi) do
    case Repo.transaction(multi, prefix: prefix) do
      {:ok, %{binding: binding}} -> {:ok, binding}
      {:error, :checked, reason, _} -> {:error, reason}
      {:error, :binding, %Ecto.Changeset{}, _} -> {:error, :already_bound}
      {:error, _step, reason, _} -> {:error, {:transaction_failed, reason}}
    end
  rescue
    error ->
      Logger.error("entity type hook write failed: #{inspect(error.__struct__)}")
      {:error, {:transaction_failed, error}}
  end

  # ── checks ───────────────────────────────────────────────────────────────────

  defp require_interactive(%{credential: :oidc}), do: :ok
  defp require_interactive(_actor), do: {:error, :api_token_not_allowed}

  defp type_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp type_name(_name), do: {:error, :not_found}

  defp tenant_id(prefix) when is_binary(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp tenant_id(_prefix), do: {:error, :not_found}

  defp parse_params(:unbind, _params), do: {:ok, nil}

  defp parse_params(_mode, %{
         "script_key" => key,
         "script_version" => version,
         "script_sha256" => sha
       })
       when is_binary(key) and key != "" and is_binary(sha) do
    with {:ok, version} <- parse_version(version),
         true <- Regex.match?(@sha, sha) do
      {:ok, %{key: key, version: version, sha: sha}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp parse_params(_mode, _params), do: {:error, :invalid_input}

  defp parse_version(v) when is_integer(v) and v >= 1 and v <= @max_version, do: {:ok, v}

  defp parse_version(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 1 and n <= @max_version -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_version(_v), do: :error

  defp require_type(prefix, type) do
    if Repo.exists?(from(d in EntityDefinition, where: d.name == ^type), prefix: prefix),
      do: :ok,
      else: {:error, :not_found}
  end

  defp require_unmanaged(prefix, type) do
    case ManagedTypes.check_tenant_write(type, prefix) do
      :ok -> :ok
      {:error, :entity_type_managed} -> {:error, :entity_type_managed}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp binding_query(type),
    do: from(b in Binding, where: b.entity_type == ^type, lock: "FOR UPDATE")

  # Unbind carries no script. FOR SHARE serialises with `Scripts` retire (FOR UPDATE on the row).
  defp require_pin(:unbind, _prefix, _pin), do: :ok

  defp require_pin(_mode, prefix, %{key: key, version: version, sha: sha}) do
    rule =
      Repo.one(
        from(r in ScriptRule,
          where: r.key == ^key and r.version == ^version,
          lock: "FOR SHARE"
        ),
        prefix: prefix
      )

    cond do
      is_nil(rule) or rule.status == :discarded -> {:error, :script_not_found}
      rule.status != :published -> {:error, :script_not_published}
      rule.hook_kind != @hook_kind -> {:error, :hook_kind_mismatch}
      rule.sha256 != sha -> {:error, :sha_mismatch}
      true -> :ok
    end
  end

  defp require_mode(:bind, nil), do: :ok
  defp require_mode(:bind, %Binding{}), do: {:error, :already_bound}
  defp require_mode(_mode, nil), do: {:error, :not_found}
  defp require_mode(_mode, %Binding{}), do: :ok

  defp require_not_hooked(:unbind, _prefix, _type), do: :ok

  defp require_not_hooked(_mode, prefix, type) do
    if hooked?(prefix, type), do: {:error, :entity_type_hooked}, else: :ok
  end

  # An ACTIVE definition with a declarative `entity_writes` line on the type (jsonb containment,
  # the document is a bound parameter) or a `module_writes` handler line that targets it.
  defp hooked?(prefix, type) do
    document = %{
      "nodes" => [%{"attributes" => %{"entity_writes" => [%{"entity_type" => type}]}}]
    }

    Repo.exists?(
      from(d in ProcessDefinition,
        where: d.status == :active and fragment("? @> ?", d.graph, type(^document, :map))
      ),
      prefix: prefix
    ) or handler_hooked?(prefix, type)
  end

  defp handler_hooked?(prefix, type) do
    from(d in ProcessDefinition,
      where:
        d.status == :active and
          fragment("jsonb_path_exists(?, '$.nodes[*].attributes.module_writes')", d.graph),
      select: d.graph
    )
    |> Repo.all(prefix: prefix)
    |> Enum.any?(fn graph ->
      graph
      |> Map.get("nodes", [])
      |> Enum.any?(fn node ->
        lines = get_in(node, ["attributes", "module_writes"])
        is_list(lines) and type in ManagedTypes.module_write_targets(lines)
      end)
    end)
  end

  defp pin_fields(%{key: key, version: version, sha: sha}),
    do: %{script_key: key, script_version: version, script_sha256: sha}

  defp state(%Binding{} = b),
    do: %{
      "entity_type" => b.entity_type,
      "script_key" => b.script_key,
      "script_version" => b.script_version,
      "script_sha256" => b.script_sha256
    }
end
