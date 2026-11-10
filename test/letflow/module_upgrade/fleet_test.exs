Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.ModuleUpgrade.FleetTest do
  @moduledoc """
  RU-S6 / T-1594 (F1..F11, N2, N3, S1): `Letflow.ModuleUpgrade.Fleet`, the platform fleet driver.
  Stock tenants are made older as in `boot_test.exs`, then rolled forward through the real plan/apply
  path. Committed tenants, Sandbox `:auto`, `async: false`. Every call passes `only_tenants:` so a
  tenant left by another test in the shared cluster is never touched; outcomes are read for the
  test's own tenants only.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EntityDefinition
  alias Letflow.ModuleUpgrade.Fleet
  alias Letflow.ModuleUpgrade.Settings
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Platform.ModuleRollout.Outcome
  alias Letflow.Platform.ModuleRollout.Rollout
  alias Letflow.StockFixture, as: S

  @old_hash String.duplicate("7", 64)
  @old_version "0.10.0"

  setup do
    S.setup_oidc!([:x])
    {:ok, entry} = Catalog.fetch("stock")
    actor = Ecto.UUID.generate()
    on_exit(fn -> Application.delete_env(:letflow, :module_rollout_halt_after) end)
    on_exit(fn -> Application.delete_env(:letflow, :module_rollout_batch) end)
    %{compiled_version: entry.manifest().version, actor: actor}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  # `n` committed stock tenants, sorted by tenant id (the order the driver works in).
  defp tenants!(n) do
    tenants =
      for i <- 1..n do
        S.tenant!("flt#{i}", Letflow.TenantSlugFixture.unique_realm("flt#{i}"))
      end

    ids = Enum.map(tenants, & &1.tenant_id)

    # The outcome rows reference the tenants: remove them before the fixture drops the tenants.
    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      rollout_ids = Repo.all(from(o in Outcome, where: o.tenant_id in ^ids, select: o.rollout_id))
      Repo.delete_all(from(o in Outcome, where: o.rollout_id in ^rollout_ids))
      Repo.delete_all(from(r in Rollout, where: r.id in ^rollout_ids))
    end)

    Enum.sort_by(tenants, & &1.tenant_id)
  end

  defp only(tenants), do: [only_tenants: Enum.map(tenants, & &1.tenant_id)]

  defp with_triggers_off(schema, table, fun) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" DISABLE TRIGGER USER))

    try do
      fun.()
    after
      Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" ENABLE TRIGGER USER))
    end
  end

  defp age!(schema) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [version: @old_version, manifest_hash: @old_hash, accepted_manifest_hashes: []]],
        prefix: schema
      )

    with_triggers_off(schema, "process_definitions", fn ->
      {n, _} =
        Repo.update_all(
          from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
          [set: [owner_manifest_hash: @old_hash]],
          prefix: schema
        )

      assert n >= 1
    end)
  end

  # A class C change: a managed type renamed away. The plan needs an acknowledgement the driver
  # never sends, so the tenant's outcome is `failed`.
  defp class_c!(schema, name \\ "stock_gone", from_name \\ "stock_receipt_line") do
    with_triggers_off(schema, "entity_definitions", fn ->
      {1, _} =
        Repo.update_all(
          from(d in EntityDefinition, where: d.name == ^from_name and d.status == :active),
          [set: [name: name]],
          prefix: schema
        )
    end)
  end

  defp fix_class_c!(schema), do: class_c!(schema, "stock_receipt_line", "stock_gone")

  defp row(schema), do: Repo.get_by!(TenantModule, [module_id: "stock"], prefix: schema)

  defp journal_done(schema),
    do: Repo.all(from(u in TenantModuleUpgrade, where: u.state == :done), prefix: schema)

  defp outcome_of(result, tenant),
    do: Enum.find(result.outcomes, &(&1.tenant_id == tenant.tenant_id))

  defp statuses(result, tenants),
    do: Enum.map(tenants, &outcome_of(result, &1).status)

  # ── S1: the setting ──────────────────────────────────────────────────────────────────

  describe "S1 the halt setting" do
    test "S1 parse_rollout_halt_after/1: default 3, 1..1000, anything else raises without echoing" do
      assert Settings.parse_rollout_halt_after(nil) == 3
      assert Settings.parse_rollout_halt_after("5") == 5
      assert Settings.parse_rollout_halt_after("1000") == 1000

      for bad <- ["0", "x", "1001", "", "3.5", "-1", "secret-9"] do
        error = assert_raise RuntimeError, fn -> Settings.parse_rollout_halt_after(bad) end
        if String.length(bad) > 4, do: refute(error.message =~ bad)
        assert error.message =~ "LETFLOW_MODULE_ROLLOUT_HALT_AFTER"
      end
    end

    test "S1b rollout_halt_after/0 reads the app key and falls back to 3" do
      assert Settings.rollout_halt_after() == 3
      Application.put_env(:letflow, :module_rollout_halt_after, 7)
      assert Settings.rollout_halt_after() == 7
      Application.put_env(:letflow, :module_rollout_halt_after, 0)
      assert Settings.rollout_halt_after() == 3
    end

    test "S1c the env var is documented in the deploy runbook" do
      assert File.read!("docs/runbooks/deploy-rules.md") =~ "LETFLOW_MODULE_ROLLOUT_HALT_AFTER"
    end
  end

  # ── F1..F4, N2: the run ──────────────────────────────────────────────────────────────

  describe "start" do
    test "F1 F2 F3 N2 older tenants are upgraded per tenant, a current one is skipped, a repeat changes nothing",
         ctx do
      [t1, t2, t3] = tenants = tenants!(3)
      age!(t1.schema_name)
      age!(t2.schema_name)
      # t3 stays current; t2 also gets a class A entity change so its plan differs from t1's.
      with_triggers_off(t2.schema_name, "entity_definitions", fn ->
        active =
          Repo.one!(
            from(d in EntityDefinition, where: d.name == "stock_receipt" and d.status == :active),
            prefix: t2.schema_name
          )

        trimmed =
          Map.update!(active.definition_json, "fields", fn fs ->
            Enum.reject(fs, &(&1["name"] == "note"))
          end)

        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^active.id),
          [
            set: [
              definition_json: trimmed,
              content_hash: :crypto.hash(:sha256, "older-receipt"),
              logical_shape_version: :crypto.hash(:sha256, "older-receipt-shape")
            ]
          ],
          prefix: t2.schema_name
        )
      end)

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))
      assert result.rollout.status == "completed"
      assert result.rollout.module_id == "stock"
      assert result.rollout.to_version == ctx.compiled_version
      assert result.rollout.halt_after == 3
      assert length(result.outcomes) == 3

      assert statuses(result, [t1, t2, t3]) == ["succeeded", "succeeded", "skipped"]
      assert outcome_of(result, t3).error_code == "up_to_date"
      assert outcome_of(result, t3).plan_hash == nil

      for t <- [t1, t2] do
        assert row(t.schema_name).version == ctx.compiled_version
        assert [done] = journal_done(t.schema_name)
        assert done.actor_id == ctx.actor
        assert done.rationale == "fleet rollout " <> result.rollout.id
        # N2: each outcome carries the plan hash of its own tenant's journal row
        assert outcome_of(result, t).plan_hash == done.plan_hash
      end

      assert journal_done(t3.schema_name) == []
      refute outcome_of(result, t1).plan_hash == outcome_of(result, t2).plan_hash

      # F3: a repeat returns the same rollout and writes no new journal row
      assert {:ok, again} = Fleet.start("stock", ctx.actor, only(tenants))
      assert again.rollout.id == result.rollout.id
      assert again.outcomes == result.outcomes
      assert Enum.map([t1, t2], &length(journal_done(&1.schema_name))) == [1, 1]
    end

    test "start of an unknown module is an error and writes nothing", ctx do
      before = Repo.aggregate(Rollout, :count, :id)
      assert Fleet.start("no_such_module", ctx.actor) == {:error, :unknown_module}
      assert Repo.aggregate(Rollout, :count, :id) == before
    end

    test "F4 a plan that needs an acknowledgement is a failed outcome and the tenant is untouched",
         ctx do
      [t1, t2] = tenants = tenants!(2)
      age!(t1.schema_name)
      age!(t2.schema_name)
      class_c!(t1.schema_name)
      version_before = row(t1.schema_name)

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))

      failed = outcome_of(result, t1)
      assert failed.status == "failed"
      assert is_binary(failed.error_code) and failed.error_code != ""
      assert row(t1.schema_name) == version_before
      assert journal_done(t1.schema_name) == []

      assert outcome_of(result, t2).status == "succeeded"
      assert result.rollout.consecutive_failures == 0
    end

    test "N3 a tenant whose schema cannot be read fails alone; the next tenant is still upgraded (INV-8)",
         ctx do
      [t1, t2, t3] = tenants = tenants!(3)
      for t <- tenants, do: age!(t.schema_name)

      Repo.query!(~s(ALTER TABLE "#{t2.schema_name}".tenant_modules RENAME TO tenant_modules_x))

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        Repo.query(
          ~s(ALTER TABLE IF EXISTS "#{t2.schema_name}".tenant_modules_x RENAME TO tenant_modules)
        )
      end)

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))
      assert outcome_of(result, t2).status == "failed"
      assert outcome_of(result, t2).error_code in ["tenant_unreadable", "internal_error"]
      assert outcome_of(result, t1).status == "succeeded"
      assert outcome_of(result, t3).status == "succeeded"
    end
  end

  # ── F5, F6: halt ─────────────────────────────────────────────────────────────────────

  describe "halt after N consecutive failures" do
    test "F5 with halt_after 2 and four failing tenants exactly two are attempted", ctx do
      Application.put_env(:letflow, :module_rollout_halt_after, 2)
      tenants = tenants!(4)

      for t <- tenants do
        age!(t.schema_name)
        class_c!(t.schema_name)
      end

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))
      assert result.rollout.status == "halted"
      assert result.rollout.halt_after == 2
      assert result.rollout.consecutive_failures == 2
      assert result.rollout.halted_at

      assert Enum.sort(Enum.map(result.outcomes, & &1.status)) ==
               ~w(failed failed pending pending)

      # a start of a halted rollout does not run it
      assert {:ok, still} = Fleet.start("stock", ctx.actor, only(tenants))
      assert Enum.sort(Enum.map(still.outcomes, & &1.status)) == ~w(failed failed pending pending)
    end

    test "F6 a success between failures resets the counter: fail, ok, fail, fail with N=3 does not halt",
         ctx do
      Application.put_env(:letflow, :module_rollout_halt_after, 3)
      [t1, _t2, t3, t4] = tenants = tenants!(4)

      for t <- tenants, do: age!(t.schema_name)
      for t <- [t1, t3, t4], do: class_c!(t.schema_name)

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))
      assert statuses(result, tenants) == ["failed", "succeeded", "failed", "failed"]
      assert result.rollout.status == "completed"
      assert result.rollout.consecutive_failures == 2
    end
  end

  # ── F7..F10: resume ──────────────────────────────────────────────────────────────────

  describe "resume" do
    test "F7 a halted rollout is reopened; failed and pending are processed, succeeded rows are untouched",
         ctx do
      Application.put_env(:letflow, :module_rollout_halt_after, 2)
      [t1, t2, t3, t4] = tenants = tenants!(4)
      for t <- tenants, do: age!(t.schema_name)
      for t <- [t2, t3, t4], do: class_c!(t.schema_name)

      assert {:ok, halted} = Fleet.start("stock", ctx.actor, only(tenants))
      assert halted.rollout.status == "halted"
      assert statuses(halted, tenants) == ["succeeded", "failed", "failed", "pending"]
      first = outcome_of(halted, t1)
      journal_before = journal_done(t1.schema_name)

      for t <- [t2, t3, t4], do: fix_class_c!(t.schema_name)

      assert {:ok, result} = Fleet.resume(halted.rollout.id, ctx.actor, only(tenants))
      assert result.rollout.status == "completed"
      assert result.rollout.consecutive_failures == 0
      assert result.rollout.halted_at == nil
      assert statuses(result, tenants) == List.duplicate("succeeded", 4)
      assert outcome_of(result, t1) == first
      assert journal_done(t1.schema_name) == journal_before
      assert row(t4.schema_name).version == ctx.compiled_version
    end

    test "F8 a completed rollout with no failed outcome is not written by resume", ctx do
      [t1, t2] = tenants = tenants!(2)
      age!(t1.schema_name)
      assert {:ok, done} = Fleet.start("stock", ctx.actor, only(tenants))
      assert done.rollout.status == "completed"
      assert statuses(done, [t1, t2]) == ["succeeded", "skipped"]

      assert {:ok, again} = Fleet.resume(done.rollout.id, ctx.actor, only(tenants))
      assert again == done
    end

    test "F9 a running claim older than 15 minutes is re-claimed, a fresh one is not", ctx do
      [t1, t2] = tenants = tenants!(2)
      for t <- tenants, do: age!(t.schema_name)

      assert {:ok, started} = Fleet.start("stock", ctx.actor, only(tenants))
      rollout_id = started.rollout.id

      # Rewind both outcomes into a crashed state: t1 stale, t2 claimed a moment ago.
      stale = NaiveDateTime.add(NaiveDateTime.utc_now(), -20 * 60, :second)
      fresh = NaiveDateTime.utc_now()

      for {t, at} <- [{t1, stale}, {t2, fresh}] do
        Repo.update_all(
          from(o in Outcome, where: o.rollout_id == ^rollout_id and o.tenant_id == ^t.tenant_id),
          set: [status: "running", attempted_at: at, completed_at: nil]
        )
      end

      Repo.update_all(from(r in Rollout, where: r.id == ^rollout_id), set: [status: "running"])
      # the stale tenant is already upgraded, so its re-claim ends as a skip, not a second upgrade
      assert {:ok, result} = Fleet.resume(rollout_id, ctx.actor, only(tenants))
      assert outcome_of(result, t1).status == "skipped"
      assert outcome_of(result, t2).status == "running"
      assert result.rollout.status == "running"
      assert length(journal_done(t1.schema_name)) == 1
    end

    test "F10 a rollout of a version the running build no longer carries is not resumed", ctx do
      [t1] = tenants = tenants!(1)
      age!(t1.schema_name)
      class_c!(t1.schema_name)
      assert {:ok, started} = Fleet.start("stock", ctx.actor, only(tenants))
      rollout_id = started.rollout.id
      Repo.update_all(from(r in Rollout, where: r.id == ^rollout_id), set: [to_version: "0.0.1"])
      fix_class_c!(t1.schema_name)

      assert Fleet.resume(rollout_id, ctx.actor, only(tenants)) == {:error, :version_superseded}
      assert row(t1.schema_name).version == @old_version
      assert Fleet.resume("not-a-uuid", ctx.actor) == {:error, :not_found}
      assert Fleet.resume(Ecto.UUID.generate(), ctx.actor) == {:error, :not_found}
    end

    test "an admin's rollback is not undone by the fleet (skipped rolled_back)", ctx do
      [t1] = tenants = tenants!(1)
      age!(t1.schema_name)

      now = DateTime.utc_now()

      {:ok, _} =
        %TenantModuleUpgrade{}
        |> TenantModuleUpgrade.changeset(%{
          module_id: "stock",
          from_version: ctx.compiled_version,
          to_version: @old_version,
          kind: :rollback,
          state: :done,
          actor_id: Ecto.UUID.generate(),
          rationale: "admin rollback",
          started_at: now,
          finished_at: now
        })
        |> Repo.insert(prefix: t1.schema_name)

      assert {:ok, result} = Fleet.start("stock", ctx.actor, only(tenants))
      assert outcome_of(result, t1).status == "skipped"
      assert outcome_of(result, t1).error_code == "rolled_back"
      assert row(t1.schema_name).version == @old_version
    end
  end

  # ── F11, status, list ────────────────────────────────────────────────────────────────

  describe "batch, status, list" do
    test "F11 each call works through at most the batch size", ctx do
      Application.put_env(:letflow, :module_rollout_batch, 2)
      tenants = tenants!(3)

      assert {:ok, first} = Fleet.start("stock", ctx.actor, only(tenants))
      assert first.rollout.status == "running"
      assert Enum.count(first.outcomes, &(&1.status == "skipped")) == 2
      assert Enum.count(first.outcomes, &(&1.status == "pending")) == 1

      assert {:ok, second} = Fleet.start("stock", ctx.actor, only(tenants))
      assert second.rollout.status == "completed"
      assert Enum.all?(second.outcomes, &(&1.status == "skipped"))
      assert Fleet.batch_size() == 2
    end

    test "status and list are read-only and report the rollout", ctx do
      [t1] = tenants = tenants!(1)
      age!(t1.schema_name)
      assert {:ok, started} = Fleet.start("stock", ctx.actor, only(tenants))

      assert {:ok, status} = Fleet.status(started.rollout.id)
      assert status == started
      assert Fleet.status("not-a-uuid") == {:error, :not_found}
      assert Fleet.status(Ecto.UUID.generate()) == {:error, :not_found}

      assert %{counts: %{"succeeded" => 1}} =
               Enum.find(Fleet.list(), &(&1.rollout.id == started.rollout.id))

      assert Fleet.status(started.rollout.id) == {:ok, started}
    end
  end

  # ── T-1640 W4..W11: the optional per-tenant upgrade window ───────────────────────────

  describe "window" do
    alias Letflow.Identity.Tenant

    @noon ~U[2026-11-10 12:00:00.000000Z]

    # Window stored as the settings key would hold it; zone UTC so the instants below are local.
    defp window!(t, window, zone \\ "UTC") do
      settings = %{"timezone" => zone, "module_upgrade.window" => window}

      {1, _} =
        Repo.update_all(from(x in Tenant, where: x.id == ^t.tenant_id), set: [settings: settings])
    end

    defp aged!(n) do
      tenants = tenants!(n)
      Enum.each(tenants, &age!(&1.schema_name))
      tenants
    end

    defp win(s, e), do: %{"start" => s, "end" => e}

    test "W4 no window: upgraded at any time", ctx do
      [t1] = tenants = aged!(1)

      assert {:ok, r} =
               Fleet.start("stock", ctx.actor, only(tenants) ++ [now: ~U[2026-11-10 03:00:00Z]])

      assert outcome_of(r, t1).status == "succeeded"
    end

    test "W5 W8 W11 inside is upgraded, outside is outside_window and untouched; a later call finishes",
         ctx do
      [t1, t2, t3] = tenants = aged!(3)
      window!(t1, win("09:00", "17:00"))
      window!(t2, win("13:00", "17:00"))
      # t3 has no window

      opts = only(tenants)
      assert {:ok, r} = Fleet.start("stock", ctx.actor, opts ++ [now: @noon])
      assert statuses(r, [t1, t2, t3]) == ["succeeded", "outside_window", "succeeded"]
      assert r.rollout.status == "running"

      deferred = outcome_of(r, t2)
      assert deferred.error_code == nil
      assert deferred.plan_hash == nil
      assert deferred.completed_at == nil
      assert row(t2.schema_name).version == @old_version
      assert journal_done(t2.schema_name) == []
      assert row(t1.schema_name).version == ctx.compiled_version
      # the response rows carry ids and codes only: no window value
      refute inspect(r.outcomes) =~ "13:00"

      # still outside: stays deferred, rollout stays running
      assert {:ok, r2} = Fleet.start("stock", ctx.actor, opts ++ [now: @noon])
      assert outcome_of(r2, t2).status == "outside_window"
      assert r2.rollout.status == "running"

      assert {:ok, r3} = Fleet.start("stock", ctx.actor, opts ++ [now: ~U[2026-11-10 14:00:00Z]])
      assert outcome_of(r3, t2).status == "succeeded"
      assert r3.rollout.status == "completed"
      assert row(t2.schema_name).version == ctx.compiled_version
    end

    test "W6 a window across midnight; end is exclusive", ctx do
      [t1, t2, t3] = tenants = aged!(3)
      Enum.each(tenants, &window!(&1, win("22:00", "04:00")))

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert Enum.all?(r.outcomes, &(&1.status == "outside_window"))

      assert {:ok, r} =
               Fleet.start("stock", ctx.actor, only([t1]) ++ [now: ~U[2026-11-10 04:00:00Z]])

      assert outcome_of(r, t1).status == "outside_window"

      assert {:ok, r} =
               Fleet.start("stock", ctx.actor, only([t1]) ++ [now: ~U[2026-11-10 23:30:00Z]])

      assert outcome_of(r, t1).status == "succeeded"

      assert {:ok, r} =
               Fleet.start("stock", ctx.actor, only([t2]) ++ [now: ~U[2026-11-11 03:00:00Z]])

      assert outcome_of(r, t2).status == "succeeded"
      assert outcome_of(r, t3).status == "outside_window"
    end

    test "W6b the window is judged in the tenant's own zone", ctx do
      [t1] = tenants = aged!(1)
      # 12:00 UTC is 17:00 in Asia/Almaty (UTC+5): inside 16:00-18:00 there, outside in UTC
      window!(t1, win("16:00", "18:00"), "Asia/Almaty")
      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert outcome_of(r, t1).status == "succeeded"
    end

    test "W7 outside_window is neutral for the halt count", ctx do
      Application.put_env(:letflow, :module_rollout_halt_after, 2)
      [a, b, c] = tenants = tenants!(3)
      Enum.each([a, c], fn t -> age!(t.schema_name) && class_c!(t.schema_name) end)
      age!(b.schema_name)
      window!(b, win("13:00", "14:00"))

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert statuses(r, [a, b, c]) == ["failed", "outside_window", "failed"]
      assert r.rollout.status == "halted"
      assert r.rollout.consecutive_failures == 2
    end

    test "W7b deferred tenants alone never halt, even with halt_after 1", ctx do
      Application.put_env(:letflow, :module_rollout_halt_after, 1)
      tenants = aged!(3)
      Enum.each(tenants, &window!(&1, win("13:00", "14:00")))

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert Enum.all?(r.outcomes, &(&1.status == "outside_window"))
      assert r.rollout.status == "running"
      assert r.rollout.consecutive_failures == 0
    end

    test "W7c resume also re-checks windows and picks deferred tenants up", ctx do
      [t1] = tenants = aged!(1)
      window!(t1, win("13:00", "14:00"))
      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert outcome_of(r, t1).status == "outside_window"

      assert {:ok, r2} =
               Fleet.resume(
                 r.rollout.id,
                 ctx.actor,
                 only(tenants) ++ [now: ~U[2026-11-10 13:30:00Z]]
               )

      assert outcome_of(r2, t1).status == "succeeded"
      assert r2.rollout.status == "completed"
    end

    test "W9 deferred rows do not starve pending ones inside a batch", ctx do
      Application.put_env(:letflow, :module_rollout_batch, 2)
      [t1, t2, t3, t4] = tenants = aged!(4)
      Enum.each([t1, t2, t3], &window!(&1, win("13:00", "14:00")))

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only([t1, t2, t3]) ++ [now: @noon])
      assert Enum.count(r.outcomes, &(&1.status == "outside_window")) == 2
      assert Enum.count(r.outcomes, &(&1.status == "pending")) == 1

      # the next call has two deferred rows and two pending: the pending ones go first
      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert outcome_of(r, t4).status == "succeeded"
      assert Enum.count(r.outcomes, &(&1.status == "outside_window")) == 3
    end

    test "W10 an invalid stored window or an unknown zone is treated as no window", ctx do
      [t1, t2] = tenants = aged!(2)
      window!(t1, win("zz", "yy"))
      window!(t2, win("13:00", "14:00"), "Mars/Olympus")

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert statuses(r, [t1, t2]) == ["succeeded", "succeeded"]
    end

    test "W11 one tenant's window never defers another tenant", ctx do
      [a, b] = tenants = aged!(2)
      window!(a, win("13:00", "14:00"))

      assert {:ok, r} = Fleet.start("stock", ctx.actor, only(tenants) ++ [now: @noon])
      assert outcome_of(r, a).status == "outside_window"
      assert outcome_of(r, b).status == "succeeded"
      assert row(b.schema_name).version == ctx.compiled_version
      assert row(a.schema_name).version == @old_version
    end
  end
end
