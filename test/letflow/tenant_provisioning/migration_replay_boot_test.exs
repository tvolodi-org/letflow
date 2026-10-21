defmodule Letflow.TenantProvisioning.MigrationReplayBootTest do
  @moduledoc """
  Tests for `Letflow.TenantProvisioning.MigrationReplayBoot` (ISS-0771). See
  `test/specs/ISS-0771.md` for the full rationale, including why the WF-03
  fail-then-pass rule for this brand-new module is satisfied via mutation testing
  (recorded in this run's TEST-DESIGNER handoff) rather than a pre-fix/post-fix diff.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture.provisioned_tenant!/1`
  (`test/support/tenant_fixture.ex`) for real tenant provisioning -- no mocked
  database, no invented fixture machinery. `async: false` for the whole module,
  matching `test/letflow/tenant_provisioning_test.exs`'s own established pattern:
  `TenantFixture.provisioned_tenant!/1` flips `Letflow.Repo` to Sandbox `:auto` mode
  and does not restore it, so no other test's connection may run concurrently.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Test.LoggerCollector
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.MigrationReplayBoot
  alias Letflow.TenantProvisioning.Registration

  describe "start_link/1" do
    test "returns :ignore and logs the failing tenant even when a tenant's replay fails" do
      broken = TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-boot-broken")

      # Same "corrupt/unreachable schema" shape as
      # tenant_provisioning_test.exs's own replay_all_pending/0 isolation test --
      # forces Ecto.Migrator.run/4 to raise for this one tenant, without touching
      # any other currently-provisioned tenant.
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{broken.schema_name}" CASCADE))

      # ISS-0772: tenant_id/schema_name/reason are now passed as Logger metadata
      # rather than interpolated into the message string, so `metadata: :all` is
      # required here to make them visible in captured output at all -- see
      # `Letflow.Secrets.LogFilterTest` for why this matters (LogFilter only
      # redacts `log_event.meta`, never `log_event.msg`).
      {_, entries} =
        LoggerCollector.capture(
          fn ->
            # The core assertion this test exists for (design doc §2.2/§2.3, and the
            # property mutant 2 in test/specs/ISS-0771.md directly targets): start_link/1
            # must return :ignore -- never {:error, _}, never raise -- regardless of how
            # many tenants' replay failed. If this returned {:error, _} or raised instead,
            # this whole supervised child would take down Letflow.Supervisor.Infrastructure
            # on every boot.
            assert :ignore = MigrationReplayBoot.start_link(nil)
          end,
          attribute_to: self(),
          raw: true
        )

      log = LoggerCollector.text(entries)

      assert log =~ "tenant migration replay failed"
      assert log =~ "tenant_id: #{inspect(broken.tenant_id)}"
      assert log =~ "schema_name: #{inspect(broken.schema_name)}"

      # The always-emitted summary line (design doc §2.2: "log one Logger.info/1
      # summary line ... after the loop completes, always") must show at least this
      # one failure.
      assert [[failed_count_str]] =
               Regex.scan(~r/error_count: (\d+)/, log, capture: :all_but_first)

      assert String.to_integer(failed_count_str) >= 1
    end

    test "logs a 0-failed summary line on the healthy path" do
      # No tenant is deliberately broken here -- this proves the "logs nothing on the
      # healthy path is exactly the kind of gap that let ISS-0771 ship invisibly the
      # first time" property (design doc §2.2) is actually closed, not merely
      # asserted in prose. Provisioning one genuinely healthy tenant first guarantees
      # at least one real :ok pass through the loop body, not just an empty
      # list_registrations/0 result.
      TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-boot-healthy")

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            assert :ignore = MigrationReplayBoot.start_link(nil)
          end,
          attribute_to: self(),
          raw: true
        )

      log = LoggerCollector.text(entries)

      assert log =~ ~r/error_count: 0/
      refute log =~ "tenant migration replay failed"
    end

    test "GH #2727: a failed replay leaves a value-free signal until a later replay succeeds" do
      healthy = TenantFixture.provisioned_tenant!(slug_prefix: "gh2727-healthy")
      broken = TenantFixture.provisioned_tenant!(slug_prefix: "gh2727-broken")

      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{broken.schema_name}" CASCADE))

      # Boot still completes (AC 7) and records the failure (AC 2/4).
      assert :ignore = MigrationReplayBoot.start_link(nil)

      failures = TenantProvisioning.list_replay_failures()
      assert [entry] = Enum.filter(failures, &(&1.tenant_id == broken.tenant_id))
      assert Map.keys(entry) |> Enum.sort() == [:failed_at, :reason_code, :tenant_id]
      assert entry.reason_code == "migration_failed"
      assert %NaiveDateTime{} = entry.failed_at
      refute Enum.any?(failures, &(&1.tenant_id == healthy.tenant_id))

      # Still visible after a second failing boot.
      assert :ignore = MigrationReplayBoot.start_link(nil)

      assert Enum.any?(
               TenantProvisioning.list_replay_failures(),
               &(&1.tenant_id == broken.tenant_id)
             )

      # The tenant recovers: a later successful replay clears the signal (AC 2).
      Repo.query!(~s(CREATE SCHEMA "#{broken.schema_name}"))
      assert :ignore = MigrationReplayBoot.start_link(nil)

      refute Enum.any?(
               TenantProvisioning.list_replay_failures(),
               &(&1.tenant_id == broken.tenant_id)
             )

      registration = Repo.get_by!(Registration, tenant_id: broken.tenant_id)
      assert is_nil(registration.migration_replay_failed_at)
      assert is_nil(registration.migration_replay_failure_code)
    end

    test "GH #2727: a clean replay leaves the signal clean" do
      healthy = TenantFixture.provisioned_tenant!(slug_prefix: "gh2727-clean")

      assert :ignore = MigrationReplayBoot.start_link(nil)

      refute Enum.any?(
               TenantProvisioning.list_replay_failures(),
               &(&1.tenant_id == healthy.tenant_id)
             )
    end

    test "GH #2727: the failed-tenant boot log line is at error level" do
      broken = TenantFixture.provisioned_tenant!(slug_prefix: "gh2727-level")
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{broken.schema_name}" CASCADE))

      {_, entries} =
        LoggerCollector.capture(fn -> assert :ignore = MigrationReplayBoot.start_link(nil) end,
          attribute_to: self(),
          raw: true
        )

      assert Enum.any?(entries, fn %{level: level, text: text} ->
               level == :error and text =~ "tenant migration replay failed"
             end)
    end
  end
end
