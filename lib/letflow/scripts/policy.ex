defmodule Letflow.Scripts.Policy do
  @moduledoc """
  GH 2534 PR 7b-2a (decision 0053 D5, D7 "Kill switch"; advisor Q3): the tenant's script policy
  state. Design: `lib/letflow/design/gh2534-7b2a-script-policy.md` sections 1, 3.2, 5, 6, 7, 8.

    * The kill switch: two latches in the singleton `script_policy` row (P1). A tenant-wide
      TENANT_ADMIN flips the tenant latch, the platform operator the platform latch; the
      effective switch is either latch on and neither actor can change the other's latch.
      While on, dry-run, publish and (7c) every run are refused with `scripts_disabled`;
      drafts, reads, retire and revoke stay allowed (P2, supervisor ruling).
    * Readable masters (advisor Q3 interim flag): the entity types tenant scripts may read.
    * `check_reads/2,3`: the DB-side check of a manifest's `reads` (flagged type, active
      definition, no type restriction, known fields, a restricted match field opted in), called
      at save, at publish (twice, the second under `FOR SHARE`) and by 7c at every run
      (section 8, normative for 7c; nothing here may be cached across runs).

  Every write requires `credential: :oidc` (P4, the 7b ruling), else `:api_token_not_allowed`,
  checked first. Every state change is audited in the same transaction (section 7); a no-op
  writes and audits nothing (P9). The tenant prefix comes only from the caller's
  `scoped_opts` (tenant routes) or from the DB-resolved target tenant (platform routes); no
  request value selects a schema (INV-1). Errors are stable atoms; nothing echoes input.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Entities.Definitions
  alias Letflow.Repo
  alias Letflow.Scripts.ReadableMaster
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Scripts.Validation

  @max_masters 200
  @references_cap 100
  @entity_type_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @type tenant_actor :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:credential) => :oidc | :api_token | nil,
          optional(:trace_id) => String.t() | nil
        }

  @type operator :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:credential) => :oidc | :api_token | nil,
          optional(:trace_id) => String.t() | nil,
          required(:platform_prefix) => String.t() | nil
        }

  @type script_reference :: %{key: String.t(), version: pos_integer(), status: String.t()}

  @type error ::
          :not_found
          | :api_token_not_allowed
          | :invalid_reason
          | :invalid_state
          | :unknown_entity_type
          | :entity_type_restricted
          | :too_many_masters
          | :reads_not_allowed
          | :scripts_disabled
          | :audit_failed

  # ── reads (6.1) ────────────────────────────────────────────────────────────

  @doc "The policy row. A missing row is a provisioning defect (`:not_found`, never fabricated)."
  @spec get(String.t()) :: {:ok, ScriptPolicy.t()} | {:error, :not_found}
  def get(prefix) do
    case Repo.get(ScriptPolicy, 1, prefix: prefix) do
      %ScriptPolicy{} = policy -> {:ok, policy}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Whether the effective kill switch is on: either latch, or the row is ABSENT (P7, fail
  closed). A database error raises; it is never read as "off".
  """
  @spec kill_switch_on?(String.t()) :: boolean()
  def kill_switch_on?(prefix) do
    query =
      from(p in ScriptPolicy,
        where: p.id == 1,
        select: {p.tenant_kill_switch, p.platform_kill_switch}
      )

    case Repo.one(query, prefix: prefix) do
      nil -> true
      {tenant, platform} -> tenant == true or platform == true
    end
  end

  @doc "Every flagged entity type, ordered by `entity_type` (at most 200)."
  @spec list_readable_masters(String.t()) :: [ReadableMaster.t()]
  def list_readable_masters(prefix) do
    Repo.all(from(m in ReadableMaster, order_by: [asc: m.entity_type]), prefix: prefix)
  end

  @doc "Whether `entity_type` is flagged."
  @spec readable_master?(String.t(), String.t()) :: boolean()
  def readable_master?(prefix, entity_type) when is_binary(entity_type) do
    Repo.exists?(from(m in ReadableMaster, where: m.entity_type == ^entity_type),
      prefix: prefix
    )
  end

  def readable_master?(_prefix, _entity_type), do: false

  @doc """
  The tenant check of a manifest's `reads` (section 3.2): for every entry, the type is
  flagged, has an ACTIVE definition and no `entity_type_restrictions` row; every `fields`,
  `restricted_fields` and `match.field` name is a field of that active definition; and a
  `match.field` that currently has an `entity_field_restrictions` row is listed in
  `restricted_fields` (P12). One code for every cause. An empty `reads` answers `:ok`
  without a query.

  `lock: :share` reads the master rows `FOR SHARE` (publish, inside its transaction), so a
  concurrent clear waits for the publish to commit (P5).
  """
  @spec check_reads(String.t(), map(), keyword()) :: :ok | {:error, :reads_not_allowed}
  def check_reads(prefix, manifest, opts \\ [])

  def check_reads(prefix, manifest, opts) when is_map(manifest) do
    case Map.get(manifest, "reads", []) do
      [] ->
        :ok

      reads when is_list(reads) ->
        lock = Keyword.get(opts, :lock)

        if Enum.all?(reads, &read_allowed?(prefix, &1, lock)),
          do: :ok,
          else: {:error, :reads_not_allowed}

      _other ->
        {:error, :reads_not_allowed}
    end
  end

  def check_reads(_prefix, _manifest, _opts), do: {:error, :reads_not_allowed}

  defp read_allowed?(prefix, %{"entity_type" => entity_type} = read, lock)
       when is_binary(entity_type) do
    with true <- master_present?(prefix, entity_type, lock),
         {:ok, definition} <- Definitions.get_active_definition_by_name(entity_type, prefix),
         false <- type_restricted?(prefix, entity_type),
         true <- fields_known?(definition, read) do
      match_field_opted_in?(prefix, entity_type, read)
    else
      _ -> false
    end
  end

  defp read_allowed?(_prefix, _read, _lock), do: false

  defp master_present?(prefix, entity_type, :share) do
    query =
      from(m in ReadableMaster,
        where: m.entity_type == ^entity_type,
        select: 1,
        lock: "FOR SHARE"
      )

    Repo.all(query, prefix: prefix) != []
  end

  defp master_present?(prefix, entity_type, _no_lock), do: readable_master?(prefix, entity_type)

  defp type_restricted?(prefix, entity_type) do
    Repo.exists?(from(r in "entity_type_restrictions", where: r.entity_type == ^entity_type),
      prefix: prefix
    )
  end

  defp fields_known?(definition, read) do
    known = definition_fields(definition)
    match_field = get_in(read, ["match", "field"])

    named =
      Map.get(read, "fields", []) ++
        Map.get(read, "restricted_fields", []) ++ List.wrap(match_field)

    named != [] and Enum.all?(named, &MapSet.member?(known, &1))
  end

  defp definition_fields(definition) do
    definition.definition_json
    |> field_defs()
    |> Enum.flat_map(fn field ->
      case Map.get(field, "name") || Map.get(field, :name) do
        name when is_binary(name) -> [name]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp field_defs(%{"fields" => fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp field_defs(%{fields: fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp field_defs(_definition_json), do: []

  # P12 / SEC F1: the same table FieldGrants.load_restrictions/3 reads, WITHOUT its per-user
  # grant anti-join (the script principal has no user and no grants).
  defp match_field_opted_in?(prefix, entity_type, %{"match" => %{"field" => field}} = read) do
    restricted? =
      Repo.exists?(
        from(r in "entity_field_restrictions",
          where: r.entity_type == ^entity_type and r.field_name == ^field
        ),
        prefix: prefix
      )

    not restricted? or field in Map.get(read, "restricted_fields", [])
  end

  defp match_field_opted_in?(_prefix, _entity_type, _id_match), do: true

  @doc """
  The published or retired versions whose manifest `reads` names `entity_type` (jsonb
  containment with a BOUND parameter, INV-7): at most 100 by `(key, version)`, plus the total.
  """
  @spec references(String.t(), String.t()) :: {[script_reference()], non_neg_integer()}
  def references(prefix, entity_type) do
    pattern = %{"reads" => [%{"entity_type" => entity_type}]}

    base =
      from(r in ScriptRule,
        where:
          r.status in ["published", "retired"] and
            fragment("? @> ?", r.manifest, type(^pattern, :map))
      )

    items =
      Repo.all(
        from(r in base,
          order_by: [asc: r.key, asc: r.version],
          limit: ^@references_cap,
          select: %{key: r.key, version: r.version, status: r.status}
        ),
        prefix: prefix
      )

    total = Repo.one(from(r in base, select: count(r.id)), prefix: prefix)
    {items, total}
  end

  # ── kill switch writes (6.2) ───────────────────────────────────────────────

  @doc """
  Flips the TENANT latch. Order: OIDC credential, boolean `on` (`:invalid_state`), reason
  (`:invalid_reason`); then, under `FOR UPDATE` on the row, a no-op returns the row unchanged
  (P9), else the latch, its user, time and reason are written and audited.
  """
  @spec set_tenant_kill_switch(String.t(), term(), term(), tenant_actor()) ::
          {:ok, ScriptPolicy.t()} | {:error, error()}
  def set_tenant_kill_switch(prefix, on, reason, actor) do
    with :ok <- require_interactive(actor),
         :ok <- boolean(on),
         {:ok, reason} <- Validation.reason(reason) do
      transaction(prefix, fn ->
        policy = lock_policy!(prefix)

        if policy.tenant_kill_switch == on do
          policy
        else
          updated =
            policy
            |> ScriptPolicy.tenant_latch_changeset(%{
              tenant_kill_switch: on,
              tenant_kill_switch_set_by: actor.user_id,
              tenant_kill_switch_set_at: now(),
              tenant_kill_switch_reason: reason
            })
            |> Repo.update!(prefix: prefix)

          audit!(prefix, %{
            actor_id: actor.user_id,
            action: "script_policy.kill_switch_set",
            resource_type: "script_policy",
            resource_id: "1",
            trace_id: Map.get(actor, :trace_id),
            before_state: %{"tenant_kill_switch" => policy.tenant_kill_switch},
            after_state: %{
              "tenant_kill_switch" => on,
              "reason" => reason,
              "effective" => ScriptPolicy.effective?(updated)
            }
          })

          updated
        end
      end)
    end
  end

  @doc """
  Flips the PLATFORM latch of the tenant whose schema is `prefix` (`tenant_id` is that
  tenant's id, from the DB-resolved target). Same order as the tenant latch, plus a binary
  `operator.platform_prefix` (else `:audit_failed`, nothing written: the ISS-1032 fail-closed
  rule). In one transaction: the row `FOR UPDATE`, the update, a TENANT-chain entry with a nil
  actor, nil trace id and `actor_class: platform_operator`, then a PLATFORM-chain entry
  carrying the operator id (lock order: policy row, tenant chain, platform chain).
  """
  @spec set_platform_kill_switch(String.t(), Ecto.UUID.t(), term(), term(), operator()) ::
          {:ok, ScriptPolicy.t()} | {:error, error()}
  def set_platform_kill_switch(prefix, tenant_id, on, reason, operator) do
    with :ok <- require_interactive(operator),
         :ok <- boolean(on),
         {:ok, reason} <- Validation.reason(reason),
         platform_prefix when is_binary(platform_prefix) <-
           Map.get(operator, :platform_prefix) || {:error, :audit_failed} do
      transaction(prefix, fn ->
        policy = lock_policy!(prefix)

        if policy.platform_kill_switch == on do
          policy
        else
          updated =
            policy
            |> ScriptPolicy.platform_latch_changeset(%{
              platform_kill_switch: on,
              platform_kill_switch_set_at: now(),
              platform_kill_switch_reason: reason
            })
            |> Repo.update!(prefix: prefix)

          # Tenant administrators read this chain: no operator id, no operator trace id.
          audit!(prefix, %{
            actor_id: nil,
            action: "script_policy.platform_kill_switch_set",
            resource_type: "script_policy",
            resource_id: "1",
            trace_id: nil,
            before_state: %{"platform_kill_switch" => policy.platform_kill_switch},
            after_state: %{
              "platform_kill_switch" => on,
              "reason" => reason,
              "effective" => ScriptPolicy.effective?(updated),
              "actor_class" => "platform_operator"
            }
          })

          audit!(platform_prefix, %{
            actor_id: operator.user_id,
            action: "platform.tenant_script_kill_switch.set",
            resource_type: "tenant",
            resource_id: tenant_id,
            trace_id: Map.get(operator, :trace_id),
            before_state: nil,
            after_state: %{
              "tenant_id" => tenant_id,
              "platform_kill_switch" => on,
              "reason" => reason
            }
          })

          updated
        end
      end)
    end
  end

  # ── readable-master writes (6.3) ───────────────────────────────────────────

  @doc """
  Flags `entity_type` as readable by scripts. The type must have an ACTIVE definition
  (`:unknown_entity_type`) and no `entity_type_restrictions` row (`:entity_type_restricted`,
  P6). Under a per-tenant advisory lock: an existing flag is `:unchanged` (no write, no audit);
  the 201st flag is `:too_many_masters`.

  [SEC F3] Stated residual: the definition and type-restriction checks run before the
  transaction without a lock, so a concurrent deactivation or type restriction can leave a
  flag on a type that is, at commit, inactive or restricted. No read follows from it:
  `check_reads/2` re-checks both at save, at publish and at every 7c run.
  """
  @spec set_readable_master(String.t(), term(), term(), tenant_actor()) ::
          {:ok, :created | :unchanged, ReadableMaster.t()} | {:error, error()}
  def set_readable_master(prefix, entity_type, reason, actor) do
    with :ok <- require_interactive(actor),
         true <- entity_type?(entity_type) || {:error, :unknown_entity_type},
         {:ok, reason} <- Validation.reason(reason),
         {:ok, _definition} <- active_definition(prefix, entity_type),
         :ok <- not_type_restricted(prefix, entity_type) do
      result =
        transaction(prefix, fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            prefix <> ":script_readable_masters"
          ])

          case Repo.get(ReadableMaster, entity_type, prefix: prefix) do
            %ReadableMaster{} = existing ->
              {:unchanged, existing}

            nil ->
              if Repo.aggregate(ReadableMaster, :count, prefix: prefix) >= @max_masters,
                do: Repo.rollback(:too_many_masters)

              master =
                Repo.insert!(
                  %ReadableMaster{
                    entity_type: entity_type,
                    set_by: actor.user_id,
                    set_at: now(),
                    reason: reason
                  },
                  prefix: prefix
                )

              audit!(prefix, %{
                actor_id: actor.user_id,
                action: "script_policy.readable_master_set",
                resource_type: "script_readable_master",
                resource_id: entity_type,
                trace_id: Map.get(actor, :trace_id),
                before_state: nil,
                after_state: %{"entity_type" => entity_type, "reason" => reason}
              })

              {:created, master}
          end
        end)

      case result do
        {:ok, {outcome, master}} -> {:ok, outcome, master}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Clears a flag. Never blocked by referencing scripts (P5): it takes effect immediately (7c
  fails a run closed when a declared read's type is not flagged). The DELETE waits for any
  publish holding the row `FOR SHARE`; the referencing published/retired versions are then
  listed in the result and in the audit entry. An unknown or unflagged type is `:not_found`.
  """
  @spec clear_readable_master(String.t(), term(), term(), tenant_actor()) ::
          {:ok,
           %{
             entity_type: String.t(),
             referenced_by: [script_reference()],
             referenced_total: non_neg_integer()
           }}
          | {:error, error()}
  def clear_readable_master(prefix, entity_type, reason, actor) do
    with :ok <- require_interactive(actor),
         true <- entity_type?(entity_type) || {:error, :not_found},
         {:ok, reason} <- Validation.reason(reason) do
      transaction(prefix, fn ->
        query = from(m in ReadableMaster, where: m.entity_type == ^entity_type, select: m)

        cleared =
          case Repo.delete_all(query, prefix: prefix) do
            {1, [cleared]} -> cleared
            _none -> Repo.rollback(:not_found)
          end

        {referenced_by, referenced_total} = references(prefix, entity_type)

        audit!(prefix, %{
          actor_id: actor.user_id,
          action: "script_policy.readable_master_cleared",
          resource_type: "script_readable_master",
          resource_id: entity_type,
          trace_id: Map.get(actor, :trace_id),
          before_state: %{
            "entity_type" => entity_type,
            "set_by" => cleared.set_by,
            "set_at" => cleared.set_at
          },
          after_state: %{
            "entity_type" => entity_type,
            "reason" => reason,
            "referenced_by" =>
              Enum.map(referenced_by, fn ref ->
                %{"key" => ref.key, "version" => ref.version, "status" => ref.status}
              end),
            "referenced_total" => referenced_total
          }
        })

        %{
          entity_type: entity_type,
          referenced_by: referenced_by,
          referenced_total: referenced_total
        }
      end)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp require_interactive(%{credential: :oidc}), do: :ok
  defp require_interactive(_actor), do: {:error, :api_token_not_allowed}

  defp boolean(on) when is_boolean(on), do: :ok
  defp boolean(_on), do: {:error, :invalid_state}

  defp entity_type?(value), do: is_binary(value) and Regex.match?(@entity_type_pattern, value)

  defp active_definition(prefix, entity_type) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, definition} -> {:ok, definition}
      {:error, _not_found_or_invalid_schema} -> {:error, :unknown_entity_type}
    end
  end

  defp not_type_restricted(prefix, entity_type) do
    if type_restricted?(prefix, entity_type),
      do: {:error, :entity_type_restricted},
      else: :ok
  end

  defp lock_policy!(prefix) do
    query = from(p in ScriptPolicy, where: p.id == 1, lock: "FOR UPDATE")

    case Repo.one(query, prefix: prefix) do
      %ScriptPolicy{} = policy -> policy
      nil -> Repo.rollback(:not_found)
    end
  end

  defp transaction(prefix, fun) do
    case Repo.transaction(fun, prefix: prefix) do
      {:ok, value} -> {:ok, value}
      {:error, {:audit_failed, _reason}} -> {:error, :audit_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit!(prefix, attrs) do
    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp now, do: DateTime.utc_now()
end
