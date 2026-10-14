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
    * GH 2534 PR 7b-2b (decision 0053 D6 + amendment; design
      `lib/letflow/design/gh2534-7b2b-script-sod.md` sections 1, 2, 4): the declared
      `scripts.sod` (`strict | solo_audited`), the platform flag allowing `solo_audited`
      (default forbidden), the COMPUTED effective value (`effective_sod/1`), the locked
      solo-publish decision with auto-strict (`solo_gate/3`) and the derived pending-review
      list. The admin count and admin set come ONLY from `Letflow.Identity`'s GH #2547
      helpers, and `Identity.lock_tenant_admins!/1` is the first lock of every 7b-2b
      transaction (never taken while holding the script-key lock or a row lock).

  Every write requires `credential: :oidc` (P4, the 7b ruling), else `:api_token_not_allowed`,
  checked first. Every state change is audited in the same transaction (section 7); a no-op
  writes and audits nothing (P9). The tenant prefix comes only from the caller's
  `scoped_opts` (tenant routes) or from the DB-resolved target tenant (platform routes); no
  request value selects a schema (INV-1). Errors are stable atoms; nothing echoes input.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Identity
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
          | :policy_missing
          | :not_tenant_wide_admin
          | :solo_audited_forbidden
          | :multiple_tenant_admins
          | :audit_failed

  @type sod :: :strict | :solo_audited
  @type sod_reason :: :declared_strict | :multiple_admins | :solo_allowed
  @type solo_gate_result :: :solo_allowed | {:refused, :auto_strict} | {:refused, :strict}

  @sod_values ["strict", "solo_audited"]
  @pending_review_cap 500

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
  `restricted_fields` and `match.field` name is a field of that active definition; a
  `match.field` is on the entity query allowlist (`queried: true`, GH 2534 7c-2 REVIEWER F1:
  otherwise the read could never run); and a `match.field` that currently has an `entity_field_restrictions` row is listed in
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
         true <- fields_known?(definition, read),
         true <- match_field_queryable?(prefix, entity_type, read) do
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
      case Map.get(field, "name") do
        name when is_binary(name) -> [name]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  # `definition_json` is always read back from jsonb here (string keys).
  defp field_defs(%{"fields" => fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp field_defs(_definition_json), do: []

  # GH 2534 7c-2 REVIEWER F1: a `match.field` must be on the entity query allowlist (a
  # `queried: true` field the compiler can filter on), the SAME allowlist the read port compiles
  # the equality query against. Otherwise the read could never run, so it is refused at save,
  # at publish and at every run alike.
  defp match_field_queryable?(prefix, entity_type, %{"match" => %{"field" => field}})
       when is_binary(field) do
    with {:ok, allowlist} <- Allowlist.load(entity_type, prefix),
         {:ok, _allowlisted} <- Allowlist.resolve_field(allowlist, field) do
      true
    else
      _not_queryable -> false
    end
  end

  defp match_field_queryable?(_prefix, _entity_type, _id_match), do: true

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
  (`:invalid_reason`); then, under `FOR UPDATE` on the row (absent: `:policy_missing`), a no-op returns the row unchanged
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
  rule). In one transaction: the row `FOR UPDATE` (absent: `:policy_missing`), the update, a TENANT-chain entry with a nil
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

  # ── separation of duties (7b-2b, design gh2534-7b2b-script-sod.md section 4) ──
  #
  # Binding lock order (design section 1): in every transaction below,
  # `Identity.lock_tenant_admins!/1` is the FIRST lock; then the policy row `FOR UPDATE`; then
  # the audit chain. `solo_gate/3` with `admin_lock_held: true` is the one exception that skips
  # the call: it runs inside the publish transaction, which took the admin lock first and must
  # never take it again while it holds the per-key lock or a row lock.

  @doc """
  The effective sod (S1): declared `strict` -> `{:strict, :declared_strict}`; declared
  `solo_audited` with `count_tenant_wide_admins/1 >= 2` -> `{:strict, :multiple_admins}`;
  otherwise `{:solo_audited, :solo_allowed}`. A missing row is `{:strict, :declared_strict}`.
  Authoritative only inside a transaction holding `Identity.lock_tenant_admins!/1`;
  elsewhere display-only (the count is read without the lock).
  """
  @spec effective_sod(String.t()) :: {sod(), sod_reason()}
  def effective_sod(prefix), do: effective_sod(prefix, Repo.get(ScriptPolicy, 1, prefix: prefix))

  @doc """
  `effective_sod/1` for an already-read policy row (so a response's declared and effective
  values describe the same row); `nil` (a missing row) is `{:strict, :declared_strict}`.
  """
  @spec effective_sod(String.t(), ScriptPolicy.t() | nil) :: {sod(), sod_reason()}
  def effective_sod(prefix, %ScriptPolicy{sod: "solo_audited"}) do
    if Identity.count_tenant_wide_admins(prefix) >= 2,
      do: {:strict, :multiple_admins},
      else: {:solo_audited, :solo_allowed}
  end

  def effective_sod(_prefix, _strict_or_missing), do: {:strict, :declared_strict}

  @doc """
  The locked solo-publish decision (design 4, 5 steps B and D). MUST run inside a transaction:
  with nothing locked yet (step B; this function takes `Identity.lock_tenant_admins!/1`
  first), or inside the publish transaction right after its row locks, with the admin lock
  already held (`opts[:admin_lock_held] == true`; the call is then skipped). Then the policy
  row `FOR UPDATE` and the recount:

    * declared `strict` -> `{:refused, :strict}` (no write);
    * declared `solo_audited` and count >= 2 -> AUTO-STRICT: `sod = 'strict'`, class
      `system`, `sod_set_by` nil, reason `auto_strict`, audited `script_policy.sod_auto_strict`
      (actor = the publishing user, `admin_count`, `opts[:key]`, `opts[:version]`);
      `{:refused, :auto_strict}`: the CALLER commits;
    * declared `solo_audited`, count <= 1 and `actor.user_id` in
      `Identity.tenant_wide_admin_user_ids/1` -> `:solo_allowed`;
    * otherwise `{:refused, :strict}` (no write).
  """
  @spec solo_gate(String.t(), tenant_actor(), keyword()) :: solo_gate_result()
  def solo_gate(prefix, actor, opts) do
    if Keyword.get(opts, :admin_lock_held, false) != true do
      Identity.lock_tenant_admins!(prefix)
    end

    policy = lock_policy!(prefix)

    if policy.sod == "solo_audited" do
      count = Identity.count_tenant_wide_admins(prefix)

      cond do
        count >= 2 ->
          auto_strict!(prefix, policy, actor, count, opts)
          {:refused, :auto_strict}

        actor.user_id in Identity.tenant_wide_admin_user_ids(prefix) ->
          :solo_allowed

        true ->
          {:refused, :strict}
      end
    else
      {:refused, :strict}
    end
  end

  defp auto_strict!(prefix, policy, actor, count, opts) do
    policy
    |> ScriptPolicy.sod_changeset(%{
      sod: "strict",
      sod_set_by: nil,
      sod_set_by_class: "system",
      sod_set_at: now(),
      sod_reason: "auto_strict"
    })
    |> Repo.update!(prefix: prefix)

    audit!(prefix, %{
      actor_id: actor.user_id,
      action: "script_policy.sod_auto_strict",
      resource_type: "script_policy",
      resource_id: "1",
      trace_id: Map.get(actor, :trace_id),
      before_state: %{"sod" => "solo_audited"},
      after_state: %{
        "sod" => "strict",
        "set_by_class" => "system",
        "cause" => "tenant_wide_admin_count",
        "admin_count" => count,
        "key" => Keyword.get(opts, :key),
        "version" => Keyword.get(opts, :version)
      }
    })
  end

  @doc """
  The tenant's declared sod (design 4, S5). Order: OIDC credential, `sod` in
  `["strict", "solo_audited"]` (`:invalid_state`), reason. Transaction:
  `Identity.lock_tenant_admins!/1` FIRST, the row `FOR UPDATE`, an equal declared value is a
  no-op (P9). To `solo_audited` only: the platform must allow it (`:solo_audited_forbidden`),
  the caller must be a counted tenant-wide admin (`:not_tenant_wide_admin`) and the count
  must be <= 1 (`:multiple_tenant_admins`). To `strict` no count or admin set is read.
  Audited `script_policy.sod_set`.
  """
  @spec set_sod(String.t(), term(), term(), tenant_actor()) ::
          {:ok, ScriptPolicy.t()} | {:error, error()}
  def set_sod(prefix, sod, reason, actor) do
    with :ok <- require_interactive(actor),
         :ok <- sod_value(sod),
         {:ok, reason} <- Validation.reason(reason) do
      transaction(prefix, fn ->
        Identity.lock_tenant_admins!(prefix)
        policy = lock_policy!(prefix)

        if policy.sod == sod do
          policy
        else
          if sod == "solo_audited", do: solo_switch_allowed!(prefix, policy, actor)

          updated =
            policy
            |> ScriptPolicy.sod_changeset(%{
              sod: sod,
              sod_set_by: actor.user_id,
              sod_set_by_class: "tenant_admin",
              sod_set_at: now(),
              sod_reason: reason
            })
            |> Repo.update!(prefix: prefix)

          audit!(prefix, %{
            actor_id: actor.user_id,
            action: "script_policy.sod_set",
            resource_type: "script_policy",
            resource_id: "1",
            trace_id: Map.get(actor, :trace_id),
            before_state: %{"sod" => policy.sod},
            after_state: %{"sod" => sod, "reason" => reason}
          })

          updated
        end
      end)
    end
  end

  # Runs under the admin lock and the policy row lock (set_sod/4).
  defp solo_switch_allowed!(prefix, policy, actor) do
    cond do
      policy.platform_solo_audited_allowed != true ->
        Repo.rollback(:solo_audited_forbidden)

      actor.user_id not in Identity.tenant_wide_admin_user_ids(prefix) ->
        Repo.rollback(:not_tenant_wide_admin)

      Identity.count_tenant_wide_admins(prefix) >= 2 ->
        Repo.rollback(:multiple_tenant_admins)

      true ->
        :ok
    end
  end

  @doc """
  The PLATFORM flag allowing `solo_audited` for the tenant whose schema is `prefix` (design 4,
  S2, S3). Order: credential, boolean `allowed` (`:invalid_state`), reason, a binary
  `operator.platform_prefix` (else `:audit_failed`, nothing written). Transaction:
  `Identity.lock_tenant_admins!/1` FIRST, the row `FOR UPDATE`, a no-op returns the row; a
  forbid (true -> false) with a declared `solo_audited` also resets `sod` to `strict` (class
  `platform_operator`, `sod_set_by` nil, the operator's reason). Then a tenant-chain entry with a
  nil actor and nil trace id, then a platform-chain entry carrying the operator id (9a8aa7ca).
  """
  @spec set_platform_solo_audited(String.t(), Ecto.UUID.t(), term(), term(), operator()) ::
          {:ok, ScriptPolicy.t()} | {:error, error()}
  def set_platform_solo_audited(prefix, tenant_id, allowed, reason, operator) do
    with :ok <- require_interactive(operator),
         :ok <- boolean(allowed),
         {:ok, reason} <- Validation.reason(reason),
         platform_prefix when is_binary(platform_prefix) <-
           Map.get(operator, :platform_prefix) || {:error, :audit_failed} do
      transaction(prefix, fn ->
        Identity.lock_tenant_admins!(prefix)
        policy = lock_policy!(prefix)

        if policy.platform_solo_audited_allowed == allowed do
          policy
        else
          now = now()

          reset =
            if allowed == false and policy.sod == "solo_audited",
              do: %{
                sod: "strict",
                sod_set_by: nil,
                sod_set_by_class: "platform_operator",
                sod_set_at: now,
                sod_reason: reason
              },
              else: %{}

          updated =
            policy
            |> ScriptPolicy.platform_solo_changeset(
              Map.merge(
                %{
                  platform_solo_audited_allowed: allowed,
                  platform_solo_audited_set_at: now,
                  platform_solo_audited_reason: reason
                },
                reset
              )
            )
            |> Repo.update!(prefix: prefix)

          # Tenant administrators read this chain: no operator id, no operator trace id.
          audit!(prefix, %{
            actor_id: nil,
            action: "script_policy.platform_solo_audited_set",
            resource_type: "script_policy",
            resource_id: "1",
            trace_id: nil,
            before_state: %{
              "platform_solo_audited_allowed" => policy.platform_solo_audited_allowed,
              "sod" => policy.sod
            },
            after_state: %{
              "platform_solo_audited_allowed" => allowed,
              "reason" => reason,
              "sod" => updated.sod,
              "actor_class" => "platform_operator"
            }
          })

          audit!(platform_prefix, %{
            actor_id: operator.user_id,
            action: "platform.tenant_script_solo_audited.set",
            resource_type: "tenant",
            resource_id: tenant_id,
            trace_id: Map.get(operator, :trace_id),
            before_state: nil,
            after_state: %{
              "tenant_id" => tenant_id,
              "platform_solo_audited_allowed" => allowed,
              "reason" => reason
            }
          })

          updated
        end
      end)
    end
  end

  @doc """
  The pending-review list, DERIVED at read time (S7): self-published, unconfirmed versions in
  status `published` or `retired`, ordered by `(key, version)`, at most 500 plus a truncation
  flag; `{[], false}` while `count_tenant_wide_admins/1 < 2` (count read WITHOUT the lock,
  advisory). No identity hook maintains it.
  """
  @spec pending_review(String.t()) :: {[ScriptRule.t()], boolean()}
  def pending_review(prefix) do
    if Identity.count_tenant_wide_admins(prefix) >= 2 do
      rows =
        Repo.all(
          from(r in ScriptRule,
            where:
              r.self_published and is_nil(r.confirmed_at) and
                r.status in ["published", "retired"],
            order_by: [asc: r.key, asc: r.version],
            limit: ^(@pending_review_cap + 1)
          ),
          prefix: prefix
        )

      {Enum.take(rows, @pending_review_cap), length(rows) > @pending_review_cap}
    else
      {[], false}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp sod_value(sod) when sod in @sod_values, do: :ok
  defp sod_value(_sod), do: {:error, :invalid_state}

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
      # A missing row is a provisioning defect (P7): 500 on every route, never a 404.
      nil -> Repo.rollback(:policy_missing)
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
