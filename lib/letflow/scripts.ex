defmodule Letflow.Scripts do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1, D6, D9, D10): the tenant-script registry. Design:
  `lib/letflow/design/gh2534-7b1-script-registry.md`.

  Every function takes the tenant prefix from the caller's `scoped_opts` (INV-1) and an actor
  map `%{user_id, credential}` built from the DB-resolved auth context. Every WRITE requires
  `credential: :oidc` (section 6.1: a tenant admin can mint a token for any user, so a token
  write could launder authorship); reads and dry-run do not.

  Errors are stable atoms; nothing returned echoes a submitted value.

  GH 2534 PR 7b-2a (`lib/letflow/design/gh2534-7b2a-script-policy.md` sections 3, 4, 5, 10):
  a manifest may declare `reads`, checked against the tenant's readable masters by
  `Letflow.Scripts.Policy.check_reads/2` at save and at publish (the second time under
  `FOR SHARE`); stored test cases and dry-run carry `reads` fixtures (no entity is read). While
  the effective kill switch is on, dry-run and publish are refused with `:scripts_disabled`;
  publish re-checks before every stored test case and inside its transaction. Draft
  create/save/discard, retire and revoke are unaffected (P2).
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Repo
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Scripts.Validation

  @hook_kinds ["service_task"]
  @test_budget_ms 30_000
  @max_version 2_147_483_647
  @zero_instance "00000000-0000-0000-0000-000000000000"

  @type actor :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:credential) => atom(),
          optional(:trace_id) => String.t() | nil
        }
  @type error ::
          :not_found
          | :api_token_not_allowed
          | :scripts_disabled
          | :version_immutable
          | :content_changed
          | :publisher_is_contributor
          | :restricted_inputs_not_allowed
          | :test_cases_required
          | :test_case_failed
          | :test_budget_exceeded
          | :script_busy
          | :invalid_manifest
          | :invalid_test_case
          | :invalid_hook_kind
          | :invalid_source
          | :reads_not_allowed
          | :invalid_input
          | :invalid_reason
          | :audit_failed
          | {:audit_failed, term()}

  # ── reads ──────────────────────────────────────────────────────────────────

  @doc "A page of version summaries ordered by key, version (no source, D9)."
  @spec list(String.t(), pos_integer(), {String.t(), pos_integer()} | nil) ::
          {[ScriptRule.t()], {String.t(), pos_integer()} | nil}
  def list(prefix, page_size, after_cursor) do
    query =
      from(r in ScriptRule,
        order_by: [asc: r.key, asc: r.version],
        limit: ^(page_size + 1)
      )

    query =
      case after_cursor do
        nil ->
          query

        {key, version} ->
          from(r in query, where: r.key > ^key or (r.key == ^key and r.version > ^version))
      end

    rows = Repo.all(query, prefix: prefix)
    {page, rest} = Enum.split(rows, page_size)

    next =
      case {rest, List.last(page)} do
        {[], _} -> nil
        {_more, %ScriptRule{key: key, version: version}} -> {key, version}
      end

    {page, next}
  end

  @doc "One readable (non-discarded) version, or `:not_found`."
  @spec get(String.t(), term(), term()) :: {:ok, ScriptRule.t()} | {:error, :not_found}
  def get(prefix, key, version) do
    with {:ok, version} <- parse_version(version),
         true <- Validation.key?(key) || {:error, :not_found},
         %ScriptRule{status: status} = rule when status != "discarded" <-
           Repo.get_by(ScriptRule, [key: key, version: version], prefix: prefix) do
      {:ok, rule}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── drafts (section 6.2) ───────────────────────────────────────────────────

  @doc "Creates draft `max(version) + 1` of `key` (discarded versions included)."
  @spec create_draft(String.t(), String.t(), map(), actor()) ::
          {:ok, ScriptRule.t()} | {:error, error()}
  def create_draft(prefix, key, body, actor) do
    with :ok <- require_interactive(actor),
         true <- Validation.key?(key) || {:error, :not_found},
         {:ok, content} <- content(body),
         :ok <- Policy.check_reads(prefix, content.manifest) do
      transaction(
        prefix,
        fn ->
          lock_key!(prefix, key)

          version =
            (Repo.one(from(r in ScriptRule, where: r.key == ^key, select: max(r.version)),
               prefix: prefix
             ) || 0) + 1

          %ScriptRule{
            key: key,
            version: version,
            hook_kind: content.hook_kind,
            status: "draft",
            source: content.source,
            manifest: content.manifest,
            test_cases: content.test_cases,
            sha256: "pending",
            contributors: [actor.user_id]
          }
          |> Repo.insert!(prefix: prefix)
          |> rehash!(prefix)
          |> tap(
            &audit!(
              &1,
              "script_rule.draft_created",
              nil,
              %{"contributors" => &1.contributors},
              actor,
              prefix
            )
          )
        end
      )
    end
  end

  @doc "Replaces a draft's content; the caller joins the contributor set."
  @spec save_draft(String.t(), String.t(), term(), map(), actor()) ::
          {:ok, ScriptRule.t()} | {:error, error()}
  def save_draft(prefix, key, version, body, actor) do
    with :ok <- require_interactive(actor),
         {:ok, version} <- parse_version(version),
         {:ok, content} <- content(body),
         :ok <- Policy.check_reads(prefix, content.manifest) do
      transaction(prefix, fn ->
        rule = lock_row!(prefix, key, version)
        if rule.status != "draft", do: Repo.rollback(:version_immutable)
        before_sha = rule.sha256

        rule
        |> Ecto.Changeset.change(
          source: content.source,
          manifest: content.manifest,
          test_cases: content.test_cases,
          contributors: Enum.uniq(rule.contributors ++ [actor.user_id])
        )
        |> Repo.update!(prefix: prefix)
        |> rehash!(prefix)
        |> tap(
          &audit!(
            &1,
            "script_rule.draft_updated",
            %{"sha256" => before_sha},
            %{"contributors" => &1.contributors},
            actor,
            prefix
          )
        )
      end)
    end
  end

  @doc "Discards a draft (rows are never deleted; its contributors keep counting for SoD)."
  @spec discard(String.t(), String.t(), term(), actor()) ::
          {:ok, ScriptRule.t()} | {:error, error()}
  def discard(prefix, key, version, actor) do
    with :ok <- require_interactive(actor),
         {:ok, version} <- parse_version(version) do
      transaction(prefix, fn ->
        rule = lock_row!(prefix, key, version)
        if rule.status != "draft", do: Repo.rollback(:version_immutable)
        now = now()

        rule
        |> Ecto.Changeset.change(status: "discarded", discarded_at: now)
        |> Repo.update!(prefix: prefix)
        |> tap(
          &audit!(&1, "script_rule.draft_discarded", nil, %{"discarded_at" => now}, actor, prefix)
        )
      end)
    end
  end

  # ── publish (section 6.3) ──────────────────────────────────────────────────

  @doc """
  Publishes a draft. `actor` must be interactive; `may_publish_restricted?` says whether the
  caller holds `:EntitiesRestrictionsManage` (recomputed by the router). Cheap refusals run
  first; the stored test cases run with no connection held; the final checks repeat under
  the per-key lock and the row lock.

  7b-2a: the kill switch is checked after the fetch (before SoD and the tests), before EVERY
  stored test case and once inside the transaction; the manifest's reads are checked in the
  pre-checks and again inside the transaction with the master rows `FOR SHARE` (P5).
  `may_publish_restricted?` also covers a read with a non-empty `restricted_fields`.

  `opts[:before_case]` (a 1-arity function given the 1-based case index, called immediately
  before that case's kill-switch check) is a TEST seam, honoured only when
  `Application.get_env(:letflow, :scripts_test_hooks)` is `true` (set only in
  `config/test.exs`); no route passes it.
  """
  @spec publish(String.t(), String.t(), term(), term(), actor(), boolean(), keyword()) ::
          {:ok, ScriptRule.t()} | {:error, error()} | {:error, :test_case_failed, map()}
  def publish(prefix, key, version, reviewed_sha, actor, may_publish_restricted?, opts \\ []) do
    with :ok <- require_interactive(actor),
         {:ok, version} <- parse_version(version),
         {:ok, rule} <- fetch(prefix, key, version),
         :ok <- scripts_enabled(prefix),
         :ok <- publishable(prefix, rule, reviewed_sha, actor, may_publish_restricted?),
         :ok <- Policy.check_reads(prefix, rule.manifest),
         :ok <- run_test_cases(prefix, rule, opts) do
      transaction(prefix, fn ->
        lock_key!(prefix, key)
        rule = lock_row!(prefix, key, version)

        # Plain read, no lock: a flip committing after it only means a version got published;
        # it still cannot run (7c checks at run time).
        if Policy.kill_switch_on?(prefix), do: Repo.rollback(:scripts_disabled)

        case publishable(prefix, rule, reviewed_sha, actor, may_publish_restricted?) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        case Policy.check_reads(prefix, rule.manifest, lock: :share) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        now = now()

        rule
        |> Ecto.Changeset.change(
          status: "published",
          publisher_id: actor.user_id,
          published_at: now
        )
        |> Repo.update!(prefix: prefix)
        |> tap(fn published ->
          audit!(
            published,
            "script_rule.published",
            nil,
            %{
              "publisher_id" => actor.user_id,
              "contributors" => published.contributors,
              "test_cases_sha256" =>
                :sha256
                |> :crypto.hash(Hash.canon(published.test_cases))
                |> Base.encode16(case: :lower),
              "restricted_inputs_checked" => restricted_opt_in?(published)
            },
            actor,
            prefix
          )
        end)
      end)
    end
  end

  defp publishable(prefix, rule, reviewed_sha, actor, may_publish_restricted?) do
    cond do
      rule.status != "draft" ->
        {:error, :version_immutable}

      reviewed_sha != rule.sha256 ->
        {:error, :content_changed}

      rule.test_cases == [] ->
        {:error, :test_cases_required}

      actor.user_id in sod_set(prefix, rule) ->
        {:error, :publisher_is_contributor}

      restricted_opt_in?(rule) and not may_publish_restricted? ->
        {:error, :restricted_inputs_not_allowed}

      true ->
        :ok
    end
  end

  # D6 strict: contributors of every version above the last published one (draft and
  # discarded included) plus this version's own (covers publishing an older draft).
  defp sod_set(prefix, %ScriptRule{key: key} = rule) do
    last_published =
      Repo.one(
        from(r in ScriptRule,
          where: r.key == ^key and not is_nil(r.published_at),
          select: max(r.version)
        ),
        prefix: prefix
      ) || 0

    since =
      Repo.all(
        from(r in ScriptRule,
          where: r.key == ^key and r.version > ^last_published,
          select: r.contributors
        ),
        prefix: prefix
      )

    since |> List.flatten() |> Kernel.++(rule.contributors) |> Enum.uniq()
  end

  # 7b-1 restricted inputs, or (7b-2a section 3.1) any read opting in restricted fields: both
  # need the publisher's :EntitiesRestrictionsManage.
  defp restricted_opt_in?(rule) do
    Map.get(rule.manifest, "restricted_inputs", []) != [] or
      Enum.any?(
        Validation.declared_reads(rule.manifest),
        &(Map.get(&1, "restricted_fields", []) != [])
      )
  end

  defp scripts_enabled(prefix) do
    if Policy.kill_switch_on?(prefix), do: {:error, :scripts_disabled}, else: :ok
  end

  # Section 4: every case in order under a 30 s total budget; no connection is held. 7b-2a:
  # the kill switch is re-checked before each case (no further case runs once it is on).
  defp run_test_cases(prefix, rule, opts) do
    deadline = System.monotonic_time(:millisecond) + @test_budget_ms
    before_case = before_case_hook(opts)

    rule.test_cases
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {test_case, index}, :ok ->
      before_case.(index)

      cond do
        Policy.kill_switch_on?(prefix) ->
          {:halt, {:error, :scripts_disabled}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, {:error, :test_budget_exceeded}}

        true ->
          case run_case(prefix, rule, test_case, index) do
            :pass ->
              {:cont, :ok}

            {:fail, code} ->
              {:halt, {:error, :test_case_failed, %{name: test_case["name"], outcome: code}}}

            :busy ->
              {:halt, {:error, :script_busy}}
          end
      end
    end)
  end

  # [CDV 2] the test seam is honoured only when :scripts_test_hooks is exactly true
  # (config/test.exs); anywhere else it is ignored.
  defp before_case_hook(opts) do
    case Keyword.get(opts, :before_case) do
      hook when is_function(hook, 1) ->
        if Application.get_env(:letflow, :scripts_test_hooks, false) == true,
          do: hook,
          else: fn _index -> :ok end

      _none ->
        fn _index -> :ok end
    end
  end

  defp run_case(prefix, rule, test_case, index) do
    ctx = %{instance_id: @zero_instance, node_id: "test", token_id: "case-#{index}", now: now()}
    input = Validation.with_reads(test_case["input"], test_case["reads"], rule.manifest)

    case ScriptRunner.run(rule.source, input, runner_opts(prefix, rule, ctx)) do
      {:error, :script_busy, _} ->
        :busy

      result ->
        case {result, test_case["expect"]} do
          {{:ok, %{output: output}}, %{"output" => expected}} ->
            if Hash.canon(output) == Hash.canon(expected) and
                 Letflow.EventStore.Registry.JsonSchema.validate(
                   output,
                   rule.manifest["output_schema"]
                 ) == [],
               do: :pass,
               else: {:fail, "output_mismatch"}

          {{:error, :script_failed, %{fail: %{code: code}}}, %{"fail" => code}} ->
            :pass

          {{:ok, _}, _} ->
            {:fail, "unexpected_output"}

          {{:error, code, _}, _} ->
            {:fail, Atom.to_string(code)}
        end
    end
  end

  defp runner_opts(prefix, rule, ctx) do
    limits = Map.get(rule.manifest, "limits", %{})

    [
      tenant: prefix,
      ctx: ctx,
      fail_codes: rule.manifest["fail_codes"],
      instructions: limits["instructions"],
      timeout_ms: limits["timeout_ms"],
      heap_words: limits["heap_words"]
    ]
  end

  # ── retire / revoke (section 6.4) ──────────────────────────────────────────

  @doc "published -> retired."
  @spec retire(String.t(), String.t(), term(), term(), actor()) ::
          {:ok, ScriptRule.t()} | {:error, error()}
  def retire(prefix, key, version, reason, actor),
    do: transition(prefix, key, version, reason, actor, ["published"], "retired", :retired_at)

  @doc "published or retired -> revoked."
  @spec revoke(String.t(), String.t(), term(), term(), actor()) ::
          {:ok, ScriptRule.t()} | {:error, error()}
  def revoke(prefix, key, version, reason, actor),
    do:
      transition(
        prefix,
        key,
        version,
        reason,
        actor,
        ["published", "retired"],
        "revoked",
        :revoked_at
      )

  defp transition(prefix, key, version, reason, actor, from, to, stamp) do
    with :ok <- require_interactive(actor),
         {:ok, version} <- parse_version(version),
         {:ok, reason} <- Validation.reason(reason) do
      transaction(prefix, fn ->
        rule = lock_row!(prefix, key, version)
        if rule.status not in from, do: Repo.rollback(:version_immutable)
        now = now()

        rule
        |> Ecto.Changeset.change([{:status, to}, {stamp, now}])
        |> Repo.update!(prefix: prefix)
        |> tap(
          &audit!(
            &1,
            "script_rule.#{to}",
            nil,
            %{Atom.to_string(stamp) => now, "reason" => reason},
            actor,
            prefix
          )
        )
      end)
    end
  end

  # ── dry-run (section 7) ────────────────────────────────────────────────────

  @doc """
  Runs a version on caller input (no reads, no writes except the audit entry). Returns a map
  `%{outcome, output?, fail?, stats?, author}`.

  7b-2a: `reads_fixture` (`nil` = absent) supplies the declared reads' rows under the stored
  test-case fixture rules; still NO entity is read. While the kill switch is on the version is
  not run (`:scripts_disabled`, not audited as a dry-run); an unknown version stays the 404.
  """
  @spec dry_run(String.t(), String.t(), term(), term(), term(), actor()) ::
          {:ok, map()} | {:error, error()}
  def dry_run(prefix, key, version, input, reads_fixture, actor) do
    with {:ok, rule} <- get(prefix, key, version),
         :ok <- scripts_enabled(prefix),
         :ok <- Validation.dry_run_input(input, reads_fixture, rule.manifest) do
      ctx = %{instance_id: @zero_instance, node_id: "dry-run", token_id: "dry-run", now: now()}

      result =
        ScriptRunner.run(
          rule.source,
          Validation.with_reads(input, reads_fixture, rule.manifest),
          [author_detail: true] ++ runner_opts(prefix, rule, ctx)
        )

      response = dry_run_response(result, rule)

      attrs =
        audit_attrs(rule, "script_rule.dry_run", nil, %{"outcome" => response.outcome}, actor)

      case Audit.insert_entry(Repo, attrs, prefix) do
        {:ok, _entry} -> {:ok, response}
        {:error, _reason} -> {:error, :audit_failed}
      end
    end
  end

  defp dry_run_response({:ok, %{output: output, stats: stats} = ok}, rule) do
    if Letflow.EventStore.Registry.JsonSchema.validate(output, rule.manifest["output_schema"]) ==
         [] do
      %{outcome: "ok", output: output, stats: stats, author: Map.get(ok, :author)}
    else
      %{outcome: "output_invalid", stats: stats, author: Map.get(ok, :author)}
    end
  end

  defp dry_run_response({:error, code, detail}, _rule) do
    %{
      outcome: Atom.to_string(code),
      fail: Map.get(detail, :fail),
      author: Map.get(detail, :author)
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp require_interactive(%{credential: :oidc}), do: :ok
  defp require_interactive(_actor), do: {:error, :api_token_not_allowed}

  defp content(%{
         "hook_kind" => hook_kind,
         "source" => source,
         "manifest" => manifest,
         "test_cases" => cases
       }) do
    cond do
      hook_kind not in @hook_kinds ->
        {:error, :invalid_hook_kind}

      not is_binary(source) or byte_size(source) > 65_536 or not String.valid?(source) ->
        {:error, :invalid_source}

      true ->
        with :ok <- Validation.manifest(manifest),
             :ok <- Validation.test_cases(cases, manifest) do
          {:ok, %{hook_kind: hook_kind, source: source, manifest: manifest, test_cases: cases}}
        end
    end
  end

  # A missing field gets the code of that field.
  defp content(body) when is_map(body) do
    cond do
      not Map.has_key?(body, "hook_kind") -> {:error, :invalid_hook_kind}
      not Map.has_key?(body, "source") -> {:error, :invalid_source}
      not Map.has_key?(body, "test_cases") -> {:error, :invalid_test_case}
      true -> {:error, :invalid_manifest}
    end
  end

  defp content(_body), do: {:error, :invalid_manifest}

  # `version` is an int4 column: anything outside 1..2^31-1 is an unknown version (404), never
  # a driver error.
  defp parse_version(version)
       when is_integer(version) and version > 0 and version <= @max_version,
       do: {:ok, version}

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} -> parse_version(n)
      _ -> {:error, :not_found}
    end
  end

  defp parse_version(_version), do: {:error, :not_found}

  defp fetch(prefix, key, version) do
    case Validation.key?(key) &&
           Repo.get_by(ScriptRule, [key: key, version: version], prefix: prefix) do
      %ScriptRule{status: status} = rule when status != "discarded" -> {:ok, rule}
      _ -> {:error, :not_found}
    end
  end

  defp lock_key!(prefix, key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [prefix <> ":script_rules:" <> key])
  end

  defp lock_row!(prefix, key, version) do
    query =
      from(r in ScriptRule, where: r.key == ^key and r.version == ^version, lock: "FOR UPDATE")

    # A discarded version answers 404 on every route, like the reads (INV-5 consistency).
    case Validation.key?(key) && Repo.one(query, prefix: prefix) do
      %ScriptRule{status: status} = rule when status != "discarded" -> rule
      _ -> Repo.rollback(:not_found)
    end
  end

  # sha256 is always computed from the row AS RELOADED (jsonb round-trip, design section 2).
  defp rehash!(%ScriptRule{} = rule, prefix) do
    reloaded = Repo.get!(ScriptRule, rule.id, prefix: prefix)

    sha =
      Hash.compute(
        reloaded.key,
        reloaded.version,
        reloaded.hook_kind,
        reloaded.manifest,
        reloaded.test_cases,
        reloaded.source
      )

    reloaded |> Ecto.Changeset.change(sha256: sha) |> Repo.update!(prefix: prefix)
  end

  defp transaction(prefix, fun) do
    Repo.transaction(fun, prefix: prefix)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:pg_code] == "LF001",
        do: {:error, :version_immutable},
        else: reraise(error, __STACKTRACE__)
  end

  defp audit!(rule, action, before_extra, after_extra, actor, prefix) do
    case Audit.insert_entry(
           Repo,
           audit_attrs(rule, action, before_extra, after_extra, actor),
           prefix
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp audit_attrs(rule, action, before_extra, after_extra, actor) do
    base = %{
      "key" => rule.key,
      "version" => rule.version,
      "status" => rule.status,
      "sha256" => rule.sha256
    }

    %{
      actor_id: actor.user_id,
      action: action,
      resource_type: "script_rule",
      resource_id: rule.id,
      before_state: before_extra && Map.merge(base, before_extra),
      after_state: Map.merge(base, after_extra || %{}),
      trace_id: nil
    }
  end

  defp now, do: DateTime.utc_now()
end
