defmodule Letflow.TenantFixtureDispatchTest do
  @moduledoc """
  ISS-0427, REVIEWER finding-8(c) (`handoffs/WF03-ISS0427-20260904/step-03c-reviewer.json`):
  "a small regression test on `provision_schema!/2`'s dispatch itself -- confirm
  `template: :clone` is genuinely the default with no explicit option (`opts \\\\ []`) and
  that `template: :replay` still produces a working schema via the original path, so a
  future edit cannot silently flip the default or remove the escape hatch without a test
  noticing."

  This is the performance-regression guard the whole ISS-0427 win rests on: if a future
  edit to `Letflow.TenantFixture.provisioned_tenant!/1` silently reverts the default from
  `:clone` back to `:replay` (or drops the `:clone` branch/the `:replay` escape hatch
  entirely), every test in the suite keeps passing functionally -- both paths produce a
  schema `assert_schema_complete!/2` accepts -- but the 2.0x measured win (this run's own
  cost measurement, see the handoff) silently disappears with nothing failing to say so.
  This file is that "nothing failing" gap closed: it asserts, mechanically and without
  timing, WHICH primitive actually ran, not merely that a schema came back.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. `async: false`, same reasoning as
  `tenant_template_test.exs`'s own moduledoc (shared physical schema names, template
  build serialization).

  ## How "which primitive ran" is asserted without timing

  Deliberately NOT a timing-based test (this suite has two documented flake sources,
  ISS-0352 and ISS-0426, and a wall-clock comparison would risk becoming a third) --
  instead asserts on OBSERVABLE STRUCTURAL SIDE EFFECTS that mechanically distinguish the
  two paths:

    * The `:clone` path always builds/uses `"tenant_template"` (via `ensure_template!/0`)
      and the resulting schema always carries FK-repointed constraints + recreated
      sequences whose default's schema is checked by `Letflow.Test.TenantTemplate`'s own
      dimension #5 -- but the simplest, most direct observable is Postgres's own
      `pg_stat_user_tables`/`schema_migrations` timing: a `:replay`-provisioned schema's
      `schema_migrations` rows get `inserted_at` timestamps written DURING this test
      (via `Ecto.Migrator.run/4`, which stamps each version as it applies), while a
      `:clone`-provisioned schema's `schema_migrations` rows are copied VERBATIM from the
      template's own (older, pre-test) rows (`do_clone/2` step 8's `INSERT INTO ...
      SELECT * FROM "tenant_template".schema_migrations`) -- so a clone schema's own rows
      have `inserted_at` values from whenever the template was BUILT (already in the
      past relative to this test), not from this test's own execution.

      This is deterministic and mechanical, not a race: it does not depend on which of
      two events happens first under contention, only on which of two already-decided
      code paths wrote a given row and when that row was ORIGINALLY written, which is a
      structural fact fixed_by construction of `do_clone/2` vs `replay_migrations/2`
      long before this test observes it -- not a timing race this test could win or lose.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Repo
  alias Letflow.TenantFixture

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  describe "provisioned_tenant!/1's :template default" do
    test "with no :template opt, the schema is built via the :clone (template-copy) path, not :replay" do
      # ensure_template!/0 is idempotent -- calling it here first just lets
      # this test read the template's OWN schema_migrations timestamps as a
      # known "old" baseline BEFORE provisioning the fixture under test, so
      # the comparison below has a concrete "these rows were written before
      # this test ran" reference rather than an implicit one.
      :ok = Letflow.Test.TenantTemplate.ensure_template!()

      template_schema = Letflow.Test.TenantTemplate.template_schema_name()

      template_migration_timestamps =
        applied_at_timestamps(template_schema)

      assert template_migration_timestamps != [],
             "test bug: template schema has no schema_migrations rows to compare against"

      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "dispatch-default-test")

      fixture_migration_timestamps = applied_at_timestamps(schema_name)

      # The DEFINING assertion: if provisioned_tenant!/1's default silently
      # reverted from :clone to :replay, this schema's schema_migrations
      # rows would carry FRESH timestamps (written by THIS test's own
      # Ecto.Migrator.run/4 call, executing right now) instead of the
      # template's OLD, already-known timestamps (copied verbatim by
      # do_clone/2's data-copy step). Asserting the exact SET equality
      # (not just "some overlap") is what makes this non-vacuous: a
      # :replay-built schema's timestamps would share the same COLUMN
      # values in general (both are real Ecto.Migrator.run/4 applications
      # of the identical manifest) but would NOT match the template's own
      # already-fixed, already-known timestamp values, captured above
      # BEFORE this fixture call ran.
      assert fixture_migration_timestamps == template_migration_timestamps,
             "provisioned_tenant!/1's default did not clone the template -- schema_migrations " <>
               "timestamps differ from the template's own (fixture=#{inspect(fixture_migration_timestamps)}, " <>
               "template=#{inspect(template_migration_timestamps)}), which is what a :replay build " <>
               "(fresh Ecto.Migrator.run/4 timestamps) would produce instead of a :clone " <>
               "(copied-verbatim timestamps). If :template's default was intentionally " <>
               "changed away from :clone, update this test's expectation deliberately -- " <>
               "do not let it regress silently."

      teardown_tenant!(tenant_id)
    end

    test "template: :replay still produces a working, independently-migrated schema (the escape hatch is not removed)" do
      :ok = Letflow.Test.TenantTemplate.ensure_template!()
      template_schema = Letflow.Test.TenantTemplate.template_schema_name()
      template_migration_timestamps = applied_at_timestamps(template_schema)

      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "dispatch-replay-test", template: :replay)

      replay_migration_timestamps = applied_at_timestamps(schema_name)

      # The mirror-image assertion: a :replay-built schema's timestamps must
      # NOT match the template's own frozen timestamps (this schema ran its
      # own fresh migration replay, seconds ago, not the template's build
      # from earlier in this partition's lifetime).
      refute replay_migration_timestamps == template_migration_timestamps,
             "template: :replay produced schema_migrations timestamps identical to the " <>
               "template's own -- this should be structurally impossible for a genuinely " <>
               "independent replay_migrations/2 run and suggests the :replay escape hatch " <>
               "silently started routing through the :clone path instead."

      # And the schema must still be genuinely complete (the same
      # completeness oracle every fixture call already runs) -- this proves
      # :replay is not merely "produces different timestamps" but actually
      # "still works as a full provisioning path."
      assert :ok = TenantFixture.assert_schema_complete!(tenant_id)

      teardown_tenant!(tenant_id)
    end
  end

  defp applied_at_timestamps(schema_name) do
    %{rows: rows} =
      Repo.query!(~s(SELECT version, inserted_at FROM "#{schema_name}".schema_migrations))

    rows |> Enum.map(fn [version, inserted_at] -> {version, inserted_at} end) |> Enum.sort()
  end

  defp teardown_tenant!(tenant_id) do
    case Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, _} -> :ok
    end

    Repo.delete_all(
      from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
    )

    Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id))
  end
end

defmodule Letflow.TenantFixtureDispatchPoolSmokeTest do
  @moduledoc """
  ISS-1042 smoke tests for the dispatch point of `Letflow.TenantFixture.provisioned_tenant!/1`
  (design `lib/letflow/design/iss1042-pooled-tenant-fixture.md` sections 7 and 12.1).

  Deliberately minimal: the full M1..M22 mutation/isolation proof is
  `test/letflow/support/tenant_fixture_pool_test.exs` (TEST-DESIGNER). This module only proves
  that the opt-in wiring works end to end and that the bypass options reach the unchanged
  default path.

  Every pooled test has the same shape (design 9.1), so the result does not depend on which
  test runs first: assert the slot is pristine, then leave data behind.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.TenantFixture

  # Audit (design 6.2): no Task / spawn / start_supervised / GenServer.cast in this module;
  # no lib/ fire-and-forget worker is reachable (only Repo and TenantFixture are called); no
  # ETS / Application.put_env / telemetry state is touched.
  setup_all context do
    TenantFixture.start_pool!(context, slots: [[slug_prefix: "pool-smoke"]])
  end

  setup context do
    TenantFixture.attach_pool!(context)
  end

  defp leave_data_behind!(%{schema_name: schema_name, tenant_id: tenant_id}) do
    Repo.query!(
      ~s|INSERT INTO "#{schema_name}".groups (id, name, inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), 'leftover', now(), now())|
    )

    Repo.query!(~s|SELECT nextval('"#{schema_name}".events_global_seq_seq')|)
    tenant_id
  end

  defp group_count(schema_name),
    do: Repo.query!(~s|SELECT count(*) FROM "#{schema_name}".groups|).rows |> hd() |> hd()

  for n <- 1..3 do
    test "pooled acquire #{n} starts pristine and leaves data behind" do
      fixture = TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke")

      assert group_count(fixture.schema_name) == 0
      assert %{clean?: true} = TenantFixture.pool_dirty_report(fixture)

      leave_data_behind!(fixture)

      assert %{dirty_tables: ["groups"], dirty_sequences: [_ | _], clean?: false} =
               TenantFixture.pool_dirty_report(fixture)
    end
  end

  test "pooled calls return the same schema in one module; pool: false and :replay bypass it",
       ctx do
    pooled = TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke")
    stats = TenantFixture.pool_stats(ctx.tenant_pool)
    assert stats.slots == 1

    assert Map.keys(pooled) |> Enum.sort() == [:schema_name, :tenant, :tenant_id]

    bypass = TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke", pool: false)
    refute bypass.schema_name == pooled.schema_name

    replay =
      TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke", template: :replay)

    refute replay.schema_name == pooled.schema_name
  end

  test "an undeclared shape raises instead of cloning silently" do
    assert_raise ArgumentError, ~r/did not declare/, fn ->
      TenantFixture.provisioned_tenant!(slug_prefix: "never-declared")
    end
  end

  test "a second attach in the same process raises", ctx do
    assert_raise ArgumentError, ~r/twice/, fn -> TenantFixture.attach_pool!(ctx) end
  end

  test "definition drift (a new table) rebuilds the slot instead of resetting it", ctx do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke")
    before_rebuilds = TenantFixture.pool_stats(ctx.tenant_pool).rebuilds

    Repo.query!(~s|CREATE TABLE "#{fixture.schema_name}".zz_smoke_probe (id integer)|)
    assert %{definition_drift: [_ | _]} = TenantFixture.pool_dirty_report(fixture)

    TenantFixture.recycle_pool!()
    again = TenantFixture.provisioned_tenant!(slug_prefix: "pool-smoke")

    assert again.schema_name == fixture.schema_name
    assert TenantFixture.pool_stats(ctx.tenant_pool).rebuilds == before_rebuilds + 1

    assert Repo.query!(
             "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 " <>
               "AND table_name = 'zz_smoke_probe'",
             [again.schema_name]
           ).rows == []
  end
end

defmodule Letflow.TenantFixtureDispatchPoolAsyncRejectTest do
  @moduledoc "ISS-1042 design section 8: an async module can neither create nor attach a pool."

  use ExUnit.Case, async: true

  test "start_pool!/2 rejects an async or unknown module context" do
    assert_raise ArgumentError, ~r/async: false/, fn ->
      Letflow.TenantFixture.start_pool!(%{module: __MODULE__, async: true}, slots: [[]])
    end

    assert_raise ArgumentError, ~r/async: false/, fn ->
      Letflow.TenantFixture.start_pool!(%{module: __MODULE__}, slots: [[]])
    end
  end

  test "attach_pool!/1 rejects an async context" do
    assert_raise ArgumentError, ~r/async: false/, fn ->
      Letflow.TenantFixture.attach_pool!(%{async: true})
    end
  end
end
