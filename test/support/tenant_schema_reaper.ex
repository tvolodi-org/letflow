defmodule Letflow.TenantSchemaReaper do
  @moduledoc """
  Suite-boundary reaper for orphaned `tenant_schemas` rows (ISS-0064).

  See `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` for the full design
  and rationale — this module implements that design exactly; do not add behavior
  beyond it without a design update.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs`) —
  **not** part of the shipped application and never added to
  `lib/letflow/application.ex`'s supervision tree. Not a GenServer, not a supervised
  process of any kind — a plain module with one public function.

  ## Why this exists

  30+ test files provision a real (non-sandboxed) tenant schema via
  `Letflow.TenantProvisioning.provision_tenant_schema/1` and rely solely on a
  manually-registered `on_exit/1` callback to clean it up. `on_exit/1` callbacks only
  run if ExUnit gets the chance to schedule them — a killed or hard-timed-out test
  process silently orphans the `tenant_schemas` row (and its real Postgres schema),
  and orphans accumulate across `mix test` invocations, eventually tripping
  `test/letflow/identity_migration_test.exs`'s `DropLegacyPublicIdentityTables` guard
  tests (ISS-0048/ISS-0050/ISS-0064).

  `sweep_orphans/2` is called once before `ExUnit.start()` and once via
  `ExUnit.after_suite/1` (`test/test_helper.exs`) — the two points in every `mix test`
  invocation where "currently active" is guaranteed to be the empty set FOR THIS
  INVOCATION. See the design doc §2 for the full argument.

  ## ISS-0110 — liveness guard against a concurrent invocation

  The argument above only ever covered THIS invocation's own activity. It says
  nothing about a second, concurrently-running `mix test` invocation sharing the same
  database (ISS-0107 showed a nested invocation really can — it inherits
  `LETFLOW_DB_PORT`/`MIX_TEST_PARTITION` via `Port.open`'s environment inheritance)
  whose own tenant schemas are still genuinely in use despite being older than
  `min_age_seconds` (the suite now regularly runs 564-609s, well past the original
  300s default).

  This module has no per-row ownership tracking (adding one would mean a migration on
  the production `tenant_schemas` table for a test-only concern, or hooking every one
  of the ~40 test-file call sites that provision a tenant schema — both rejected as
  disproportionate to the actual hazard). Instead it asks a coarser, sufficient
  question: **is any OTHER `mix test` invocation currently connected to this database
  at all, right now?** `config/test.exs` tags every connection this invocation opens
  with `application_name: "letflow_mixtest_\#{System.pid()}"` — stable for this
  invocation's whole lifetime, and distinct per invocation (a nested invocation is a
  distinct OS process, hence a distinct `System.pid()`). `sweep_orphans/2` checks
  `pg_stat_activity` for any *other* `letflow_mixtest_*` tag before touching anything.

  If another invocation is present, the sweep defers ENTIRELY for this call — not just
  for that invocation's own rows, since without per-row ownership there is no way to
  tell which old rows belong to the live invocation and which are genuinely orphaned
  from some third, already-dead one. This trades promptness (orphan cleanup can be
  delayed while a second invocation is running) for correctness (never guesses), which
  is the direction ISS-0110 asks for explicitly. The next sweep — this invocation's
  own `after_suite`, or a later invocation's own pre-`ExUnit.start()` sweep — retries
  and proceeds normally once the database is single-occupant again.

  This does NOT weaken the original ISS-0064 guarantee: a schema whose owning
  invocation's OS process has genuinely died closes every connection it held (TCP-level,
  unconditionally), so its `application_name` tag stops appearing in `pg_stat_activity`
  and the very next sweep (by any invocation) reclaims it exactly as before.

  ## ISS-0217 — sibling `test_parallel.sh` partitions are not a hazard

  The ISS-0110 guard above has a false-positive: `scripts/test_parallel.sh` launches
  N `mix test` processes for ONE logical test run, each its own OS process and
  therefore its own distinct `letflow_mixtest_<pid>` tag. From any one partition's
  point of view, the other N-1 partitions look identical to a genuinely separate,
  externally-nested invocation — the guard deferred every sweep unconditionally for
  the whole run, making `reclaimed`/`skipped` always `{0, 0}` regardless of what a
  test's own fixtures actually did.

  `scripts/test_parallel.sh` now generates one `TEST_PARALLEL_GROUP` value
  (`$$`, its own shell PID) before forking its N partitions, and exports it so every
  partition inherits it. `config/test.exs` folds a present `TEST_PARALLEL_GROUP` into
  the connection tag as a `_grp<id>` suffix. `concurrent_invocation_present?/2`
  extracts that suffix from both its own tag and each other connection's tag found in
  `pg_stat_activity`, and excludes a match from counting as a hazard — same group,
  same test_parallel.sh invocation, expected sibling, not deferred.

  This does not touch the original protection: a plain `mix test` (no
  `TEST_PARALLEL_GROUP` set) still has no group to match against, so every other
  `letflow_mixtest_*` tag it sees is still treated as external and still defers,
  exactly as ISS-0110 specified. Likewise a genuinely nested invocation inside a
  `test_parallel.sh` run (ISS-0107's scenario) carries no group tag of its own, so it
  never matches the parent run's group and still correctly triggers deferral.

  ## ISS-0941 -- a third, independent sweep for orphaned "Tenant Template Build
  ## (throwaway)" rows that `sweep_orphans/2` detects but can never reclaim

  `sweep_template_build_orphans/2` is this module's third responsibility. See
  `lib/letflow/design/iss0941-orphan-tenant-row-reaper.md` for the full design and
  rationale.

  `test/support/tenant_template.ex`'s `build_template!/0` inserts a throwaway
  `tenants`/`tenant_schemas` row pair (`display_name: "Tenant Template Build
  (throwaway)"`) pointing at a freshly-created staging schema
  (`"tenant_template_build_" <> 32 hex chars`), and deletes both rows itself on the
  success path, before its own schema rename. On a failure path after that insert
  (any exception, or a hard process kill), the row survives with its backing schema
  already dropped (or never cleaned up) -- but the staging name's shape never matches
  `sweep_orphans/2`'s own `@schema_name_format` regex, so that sweep's
  `skipped_invalid_format` branch unconditionally skips it, by shape, independent of
  whether the row's schema still exists. This function asks the question
  `sweep_orphans/2` never does for this row shape: a direct, live
  `information_schema.schemata` lookup for the row's own `schema_name`, confirming
  absence before ever deleting anything. It only ever deletes the two bookkeeping
  rows -- it never issues a `DROP SCHEMA` of its own, even when it could (the schema
  is already confirmed absent by the time it would run); a row whose schema is
  confirmed *present* is left untouched and logged, not reclaimed (see the design
  doc §1 for why that case is deliberately out of scope here).

  Reuses `current_application_name/1` and `concurrent_invocation_present?/2` verbatim
  (same private helpers the other two sweeps use, same ISS-0414 §2.2 same-module-call
  rationale) and the identical `try/rescue/after` failure-mode contract: never raises
  to its caller, restores `Sandbox.mode(repo, :manual)` in an `after` block regardless
  of outcome.

  ## ISS-0414 -- a second, independent sweep for orphaned `service_catalog` rows

  `sweep_service_catalog_orphans/1` is this module's second responsibility, added for
  ISS-0414. See `lib/letflow/design/iss0414-service-catalog-safety-net.md` for the full
  design and rationale.

  `service_catalog` (`lib/letflow/service_catalog.ex`) is this codebase's only table
  with no per-tenant-schema `DROP SCHEMA ... CASCADE` fallback -- a row left behind by
  an interrupted test process (one that never reached its own `on_exit/1`) has no other
  cleanup mechanism at all. The same suite-boundary argument as `sweep_orphans/2`'s own
  applies here (before `ExUnit.start()`, and `ExUnit.after_suite/1` -- the two points
  where "currently active, legitimately, for this invocation" is always the empty set),
  but simpler: no `service_catalog` row is ever held open for a whole test's duration
  the way a tenant schema is (every test that creates one deletes it in its own
  `on_exit/1` -- confirmed by grepping every test file that touches
  `Letflow.ServiceCatalog`), so there is no in-progress-row race to guard against and no
  `min_age_seconds`-equivalent parameter -- finding ANY row at a boundary is itself the
  anomaly, unconditionally.

  This function reuses `current_application_name/1` and
  `concurrent_invocation_present?/2` verbatim (same private helpers `sweep_orphans/2`
  uses) rather than duplicating the `pg_stat_activity` check in a second module -- both
  responsibilities live in this one file so that reuse is a same-module function call,
  not a new cross-module dependency (design doc §2.2). It follows the identical
  `try/rescue/after` failure-mode contract: never raises to its caller, restores
  `Sandbox.mode(repo, :manual)` in an `after` block regardless of outcome.
  """

  require Logger

  alias Ecto.Adapters.SQL.Sandbox

  # Mirrors Letflow.TenantProvisioning.Registration's own @schema_name_format
  # (lib/letflow/tenant_provisioning/registration.ex) — literal duplicate, not a
  # shared reference, since that module attribute is private and this is a
  # test-only module living outside lib/letflow/ (design doc §4 INV-R-1, §8 OQ-3).
  # Keep both in sync if either ever changes.
  @schema_name_format ~r/^tenant_[0-9a-f]{32}$/

  @default_min_age_seconds 300

  # The exact literal test/support/tenant_template.ex's build_template!/0 inserts as
  # its throwaway tenants row's display_name (ISS-0941 design doc §0/§1). Not a regex
  # -- an exact match, deliberately narrower scoping than sweep_orphans/2's own
  # format-based check.
  @template_build_display_name "Tenant Template Build (throwaway)"

  @doc """
  Reclaims `tenant_schemas` rows old enough (`provisioned_at` older than
  `min_age_seconds`) to no longer plausibly belong to an in-progress test, in this
  invocation — but only once it has confirmed (ISS-0110) that no OTHER `mix test`
  invocation is currently connected to this database at all. If one is, the sweep
  defers entirely (see the moduledoc's "ISS-0110" section for why entirely, not just
  for that invocation's own rows) and reports the same shape as a genuinely empty
  sweep, distinguishable only via the log line.

  Never raises to its caller — an outer failure (e.g. the bulk `SELECT` itself
  raising, or either `Sandbox.mode/2` call raising) is caught, logged, and reported
  back identically to a genuinely empty sweep (`{:ok, %{reclaimed: 0,
  skipped_invalid_format: 0}}`); only the log output distinguishes the two cases.
  See the design doc §3.1/§3.2 for the full failure-mode contract.
  """
  @spec sweep_orphans(repo :: module(), min_age_seconds :: non_neg_integer()) ::
          {:ok, %{reclaimed: non_neg_integer(), skipped_invalid_format: non_neg_integer()}}
  def sweep_orphans(repo \\ Letflow.Repo, min_age_seconds \\ @default_min_age_seconds) do
    try do
      Sandbox.mode(repo, :auto)

      own_tag = current_application_name(repo)

      if concurrent_invocation_present?(repo, own_tag) do
        Logger.info(
          "TenantSchemaReaper.sweep_orphans/2: deferring this sweep entirely -- " <>
            "another mix test invocation (application_name != #{inspect(own_tag)}) is " <>
            "currently connected to this database, and this module tracks no per-row " <>
            "ownership, so an age-based reap right now could reclaim that invocation's " <>
            "still-live tenant schema (ISS-0110). Retrying on the next boundary sweep."
        )

        {:ok, %{reclaimed: 0, skipped_invalid_format: 0}}
      else
        cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_age_seconds, :second)

        %{rows: rows} =
          repo.query!(
            "SELECT id, tenant_id, schema_name FROM tenant_schemas WHERE provisioned_at < $1",
            [cutoff]
          )

        {reclaimed, skipped_invalid_format} =
          Enum.reduce(rows, {0, 0}, fn [id, tenant_id, schema_name],
                                       {reclaimed_acc, skipped_acc} ->
            if Regex.match?(@schema_name_format, schema_name) do
              if reclaim_row(repo, %{id: id, tenant_id: tenant_id, schema_name: schema_name}) do
                {reclaimed_acc + 1, skipped_acc}
              else
                {reclaimed_acc, skipped_acc}
              end
            else
              Logger.warning(
                "TenantSchemaReaper.sweep_orphans/2: skipping tenant_schemas row id=#{Ecto.UUID.cast!(id)} " <>
                  "tenant_id=#{Ecto.UUID.cast!(tenant_id)} with malformed schema_name=#{inspect(schema_name)}"
              )

              {reclaimed_acc, skipped_acc + 1}
            end
          end)

        {:ok, %{reclaimed: reclaimed, skipped_invalid_format: skipped_invalid_format}}
      end
    rescue
      exception ->
        Logger.error(
          "TenantSchemaReaper.sweep_orphans/2 aborted: #{Exception.format(:error, exception, __STACKTRACE__)}"
        )

        {:ok, %{reclaimed: 0, skipped_invalid_format: 0}}
    after
      Sandbox.mode(repo, :manual)
    end
  end

  @doc """
  Reclaims every `service_catalog` row found at a suite boundary (before
  `ExUnit.start()`, or in `ExUnit.after_suite/1`) -- but only once it has confirmed
  (reusing the same ISS-0110/ISS-0217 check `sweep_orphans/2` uses) that no OTHER
  `mix test` invocation is currently connected to this database at all. If one is, the
  sweep defers entirely, touching nothing, exactly like `sweep_orphans/2`'s own
  deferral. See the moduledoc's "ISS-0414" section and
  `lib/letflow/design/iss0414-service-catalog-safety-net.md` for the full rationale --
  in particular, why no `min_age_seconds`-equivalent parameter is needed here.

  Never raises to its caller -- an outer failure (the `SELECT`/`DELETE` itself raising,
  either `Sandbox.mode/2` call raising, or the concurrency check's own query raising) is
  caught, logged at `:error`, and reported back as `{:ok, %{deleted: 0}}`; only the log
  output distinguishes that case from a genuinely empty sweep.
  """
  @spec sweep_service_catalog_orphans(repo :: module()) ::
          {:ok, %{deleted: non_neg_integer()}} | {:deferred, :concurrent_invocation}
  def sweep_service_catalog_orphans(repo \\ Letflow.Repo) do
    try do
      Sandbox.mode(repo, :auto)

      own_tag = current_application_name(repo)

      if concurrent_invocation_present?(repo, own_tag) do
        Logger.info(
          "TenantSchemaReaper.sweep_service_catalog_orphans/1: deferring this sweep " <>
            "entirely -- another mix test invocation (application_name != " <>
            "#{inspect(own_tag)}) is currently connected to this database, and this " <>
            "sweep has no per-row ownership tracking, so it cannot safely tell that " <>
            "invocation's still-live service_catalog rows apart from a genuinely " <>
            "orphaned one (ISS-0414). Retrying on the next boundary sweep."
        )

        {:deferred, :concurrent_invocation}
      else
        %{rows: rows} = repo.query!("SELECT service_id, scope FROM service_catalog")

        case rows do
          [] ->
            {:ok, %{deleted: 0}}

          rows ->
            found =
              rows
              |> Enum.map(fn [service_id, scope] -> "#{service_id} (scope=#{scope})" end)
              |> Enum.join(", ")

            Logger.warning(
              "TenantSchemaReaper.sweep_service_catalog_orphans/1: found #{length(rows)} " <>
                "service_catalog row(s) at a suite boundary, where the correct content is " <>
                "always empty (ISS-0414) -- deleting unconditionally: #{found}"
            )

            repo.query!("DELETE FROM service_catalog")

            {:ok, %{deleted: length(rows)}}
        end
      end
    rescue
      exception ->
        Logger.error(
          "TenantSchemaReaper.sweep_service_catalog_orphans/1 aborted: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        {:ok, %{deleted: 0}}
    after
      Sandbox.mode(repo, :manual)
    end
  end

  @doc """
  Reclaims `tenant_schemas`/`tenants` row pairs belonging to a
  `"Tenant Template Build (throwaway)"` row (ISS-0941) old enough (`provisioned_at`
  older than `min_age_seconds`) not to still be a plausible in-progress
  `test/support/tenant_template.ex` build, but only once a direct,
  live `information_schema.schemata` lookup confirms the row's own `schema_name` no
  longer exists -- and only once it has confirmed (reusing the same ISS-0110/ISS-0217
  check the other two sweeps use) that no OTHER `mix test` invocation is currently
  connected to this database at all. If one is, the sweep defers entirely, touching
  nothing, exactly like the other two sweeps' own deferral.

  A row matching the `display_name` filter and old enough, but whose `schema_name` is
  confirmed to still exist, is left untouched -- this function never issues a
  `DROP SCHEMA` of its own (see the design doc §1/§2.2 for why that case is out of
  scope here) -- and counted in `:skipped_schema_present` instead, logged at
  `:warning` per row.

  Never raises to its caller -- an outer failure (the candidate-row `SELECT`, a
  per-row `information_schema.schemata` lookup, either `Sandbox.mode/2` call, or
  `current_application_name/1`'s own query) not already caught by the per-row
  try/rescue below is caught here, logged at `:error`, and reported back as
  `{:ok, %{deleted: 0, skipped_schema_present: 0}}`; only the log output distinguishes
  that case from a genuinely empty sweep. See the design doc §2.4/§2.5 for the full
  algorithm and failure-mode contract.
  """
  @spec sweep_template_build_orphans(repo :: module(), min_age_seconds :: non_neg_integer()) ::
          {:ok, %{deleted: non_neg_integer(), skipped_schema_present: non_neg_integer()}}
          | {:deferred, :concurrent_invocation}
  def sweep_template_build_orphans(
        repo \\ Letflow.Repo,
        min_age_seconds \\ @default_min_age_seconds
      ) do
    try do
      Sandbox.mode(repo, :auto)

      own_tag = current_application_name(repo)

      if concurrent_invocation_present?(repo, own_tag) do
        Logger.info(
          "TenantSchemaReaper.sweep_template_build_orphans/2: deferring this sweep " <>
            "entirely -- another mix test invocation (application_name != " <>
            "#{inspect(own_tag)}) is currently connected to this database, and this " <>
            "sweep has no per-row ownership tracking, so it cannot safely tell that " <>
            "invocation's still-live tenant_template_build row apart from a genuinely " <>
            "orphaned one (ISS-0941). Retrying on the next boundary sweep."
        )

        {:deferred, :concurrent_invocation}
      else
        cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_age_seconds, :second)

        %{rows: rows} =
          repo.query!(
            "SELECT ts.id, ts.tenant_id, ts.schema_name " <>
              "FROM tenant_schemas ts JOIN tenants t ON t.id = ts.tenant_id " <>
              "WHERE t.display_name = $1 AND ts.schema_name LIKE 'tenant_template_build_%' " <>
              "AND ts.provisioned_at < $2",
            [@template_build_display_name, cutoff]
          )

        {deleted, skipped_schema_present} =
          Enum.reduce(rows, {0, 0}, fn [id, tenant_id, schema_name], {deleted_acc, skipped_acc} ->
            row = %{id: id, tenant_id: tenant_id, schema_name: schema_name}

            if schema_exists?(repo, schema_name) do
              Logger.warning(
                "TenantSchemaReaper.sweep_template_build_orphans/2: tenant_schemas row " <>
                  "id=#{Ecto.UUID.cast!(id)} tenant_id=#{Ecto.UUID.cast!(tenant_id)} " <>
                  "schema_name=#{inspect(schema_name)} matches the throwaway " <>
                  "template-build display_name and is old enough, but its schema still " <>
                  "exists -- leaving it untouched (ISS-0941 design doc §1)."
              )

              {deleted_acc, skipped_acc + 1}
            else
              if reclaim_template_build_row(repo, row) do
                {deleted_acc + 1, skipped_acc}
              else
                {deleted_acc, skipped_acc}
              end
            end
          end)

        {:ok, %{deleted: deleted, skipped_schema_present: skipped_schema_present}}
      end
    rescue
      exception ->
        Logger.error(
          "TenantSchemaReaper.sweep_template_build_orphans/2 aborted: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        {:ok, %{deleted: 0, skipped_schema_present: 0}}
    after
      Sandbox.mode(repo, :manual)
    end
  end

  # Direct, live existence check against information_schema.schemata -- deliberately
  # not the regex-based format check sweep_orphans/2 uses (ISS-0941 design doc §0: the
  # staging name's shape never matches that regex, which is the actual mechanism
  # behind the issue this function exists to fix).
  defp schema_exists?(repo, schema_name) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
        [schema_name]
      )

    rows != []
  end

  # Deletes the tenant_schemas row, then its parent tenants row -- no DROP SCHEMA,
  # unlike reclaim_row/2, since this branch's own caller has already confirmed the
  # schema does not exist (ISS-0941 design doc §2.4 step 4). Returns true on success,
  # false if this row's own cleanup raised (left for the next sweep to retry) -- a
  # per-row failure never aborts the sweep for the remaining rows.
  defp reclaim_template_build_row(repo, %{id: id, tenant_id: tenant_id, schema_name: schema_name}) do
    repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [id])
    repo.query!("DELETE FROM tenants WHERE id = $1", [tenant_id])
    true
  rescue
    exception ->
      Logger.warning(
        "TenantSchemaReaper.sweep_template_build_orphans/2: failed to reclaim " <>
          "tenant_schemas row id=#{Ecto.UUID.cast!(id)} tenant_id=#{Ecto.UUID.cast!(tenant_id)} " <>
          "schema_name=#{schema_name}: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      false
  end

  # The application_name this connection was opened with -- config/test.exs sets it
  # to "letflow_mixtest_#{System.pid()}" for every connection this invocation opens
  # (ISS-0110), so any connection this repo hands back reports the same value.
  defp current_application_name(repo) do
    %{rows: [[name]]} = repo.query!("SHOW application_name")
    name
  end

  # True if pg_stat_activity shows a connection tagged for a DIFFERENT mix test
  # invocation than this one. Matches only the "letflow_mixtest_" tag prefix this
  # project's own config/test.exs writes -- a bare Postgres session with no such tag
  # (e.g. a human's psql shell) is not a mix test invocation and is correctly ignored.
  #
  # ISS-0217: a tag optionally carries a "_grp<id>" suffix (config/test.exs, when
  # TEST_PARALLEL_GROUP is set) shared by every sibling partition one
  # scripts/test_parallel.sh invocation launches. A connection whose group matches
  # our own is an EXPECTED sibling, not a hazard -- excluded from this check. A
  # connection with no group, or a different group, is a genuinely separate
  # invocation and still counts as concurrent, exactly as ISS-0110 originally
  # required (this preserves that protection for the plain-`mix test`,
  # solo-invocation, and nested-invocation cases, none of which carry a matching
  # group tag).
  defp concurrent_invocation_present?(repo, own_tag) do
    own_group = group_tag_of(own_tag)

    %{rows: rows} =
      repo.query!(
        "SELECT application_name FROM pg_stat_activity " <>
          "WHERE application_name LIKE 'letflow_mixtest_%' AND application_name <> $1",
        [own_tag]
      )

    concurrent? =
      Enum.any?(rows, fn [name] -> is_nil(own_group) or group_tag_of(name) != own_group end)

    log_guard_read(repo, own_tag, rows, concurrent?)
    concurrent?
  end

  # GH #2441 diagnostics: a CI sweep once reclaimed rows although another invocation's
  # connection was alive, i.e. this read returned no foreign tag. The log is the
  # evidence the issue asks for: what the read returned and whether the Repo
  # connection was inside a transaction (a per-transaction snapshot would explain a
  # stale pg_stat_activity view). Quiet in the ordinary case -- no foreign tag read
  # and no transaction -- so only the interesting reads reach the CI log.
  defp log_guard_read(repo, own_tag, rows, concurrent?) do
    in_tx? = repo.in_transaction?()

    if in_tx? or rows != [] do
      Logger.warning(
        "TenantSchemaReaper guard read (GH #2441): own_tag=#{inspect(own_tag)} " <>
          "foreign_tags=#{inspect(List.flatten(rows))} in_transaction=#{in_tx?} " <>
          "concurrent=#{concurrent?}"
      )
    end

    :ok
  end

  # Extracts the trailing "_grp<id>" suffix an application_name may carry (ISS-0217),
  # or nil if it carries none (a plain "letflow_mixtest_<pid>" tag, ISS-0110's
  # original shape).
  defp group_tag_of(tag) do
    case Regex.run(~r/_grp(.+)$/, tag) do
      [_, group] -> group
      nil -> nil
    end
  end

  # Drops the row's real Postgres schema and deletes its tenant_schemas/tenants
  # rows. schema_name has already been validated by the caller. Returns true on
  # success, false if this row's own cleanup raised (left for the next sweep to
  # retry) — a per-row failure never aborts the sweep for the remaining rows.
  defp reclaim_row(repo, %{id: id, tenant_id: tenant_id, schema_name: schema_name}) do
    repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
    repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [id])
    repo.query!("DELETE FROM tenants WHERE id = $1", [tenant_id])
    true
  rescue
    exception ->
      Logger.warning(
        "TenantSchemaReaper.sweep_orphans/2: failed to reclaim tenant_schemas row id=#{Ecto.UUID.cast!(id)} " <>
          "tenant_id=#{Ecto.UUID.cast!(tenant_id)} schema_name=#{schema_name}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      false
  end
end
