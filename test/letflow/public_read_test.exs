defmodule Letflow.PublicReadTest do
  @moduledoc """
  Tests for `Letflow.PublicRead` (REQ-352, `test/specs/REQ-352.md`) --
  `issue_handle/4` (the writer) and `resolve/2` (the reader), at the
  context-module level (no HTTP). Router/plug-chain-level tests (the mount,
  the ten-case refusal sweep, response headers, rate limiting) live in
  `test/letflow/routers/public_read_test.exs` and
  `test/letflow/plugs/public_read_rate_limit_test.exs`.

  `async: false` -- required because `PublicReadFixtureSupport.provision_tenant!/0`
  calls `Letflow.TenantFixture.provisioned_tenant!/1`, which switches
  `Letflow.Repo` to Sandbox `:auto` mode for real schema creation; this is
  the same requirement `test/letflow/tenant_provisioning/backfill_test.exs`
  and `test/support/tenant_fixture_dispatch_test.exs` state for every
  `template: :replay` call site (confirmed empirically here too: this file
  raised `{:error, {:migration_failed, %Postgrex.Error{... :invalid_schema_name}}}`
  under `async: true` before this was fixed).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.PublicRead
  alias Letflow.PublicRead.Handle
  alias Letflow.PublicReadFixtureSupport

  # Named (not anonymous) telemetry handler, matching the established
  # `test/letflow/router_test.exs` / `test/letflow/plugs/tenant_status_test.exs`
  # ISS-0031 (GH#90) precedent -- [:letflow, :repo, :query] is a single
  # node-global event name, so the handler filters to only this test's own
  # process (self() == test_pid) rather than trusting an unfiltered send/2,
  # or a concurrently running async test's real query would flake the count.
  def handle_query_telemetry(_event, _measurements, metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, {:query_fired, Map.get(metadata, :query)})
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    handler_id = {:public_read_test, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.handle_query_telemetry/4,
      test_pid
    )

    result = fun.()

    # Drain every :query_fired message sent to this process during fun.().
    count =
      Stream.repeatedly(fn ->
        receive do
          {:query_fired, _query} -> :fired
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 == :fired))
      |> length()

    :telemetry.detach(handler_id)
    {result, count}
  end

  describe "AC-2: issue_handle/4 stores a hash, never the plaintext" do
    test "the stored handle_hash column never equals the issued plaintext handle" do
      %{tenant_id: tenant_id} = PublicReadFixtureSupport.provision_tenant!()
      resource_id = Ecto.UUID.generate()

      assert {:ok, %{handle: plaintext, record: record}} =
               PublicRead.issue_handle(tenant_id, PublicReadFixtureSupport.kind(), resource_id)

      refute record.handle_hash == plaintext
      assert record.handle_hash == :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0983 -- issue_handle/4 is rescue-hardened against a Postgres-level
  # audit-write failure. Same DROP TABLE fault-injection idiom established by
  # ISS-0969/ISS-0980/ISS-0981 (see test/letflow/engine_test.exs's "ISS-0969"
  # describe block for the exact DDL recreated below). Uses a real,
  # syntactically-valid tenant_id from provision_tenant!/0 so this exercises
  # the {:ok, prefix} -> prefix branch of issue_handle/4's own case, never the
  # deliberate ArgumentError raise branch for an invalid tenant_id (out of
  # scope for this fix, must keep raising uncaught).
  # ---------------------------------------------------------------------------------

  describe "ISS-0983: issue_handle/4 is rescue-hardened against a Postgres-level audit-write failure" do
    test "a genuine Postgres-level audit-insert failure rolls back the handle insert" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        PublicReadFixtureSupport.provision_tenant!()

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          actor_kind text,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               PublicRead.issue_handle(
                 tenant_id,
                 PublicReadFixtureSupport.kind(),
                 Ecto.UUID.generate()
               )

      assert Repo.aggregate(from(h in Handle, where: h.tenant_id == ^tenant_id), :count) == 0
    end
  end

  describe "AC-6/AC-7: round-trip counting via [:letflow, :repo, :query] telemetry" do
    test "a malformed handle performs exactly one round-trip and does not short-circuit (AC-7)" do
      {result, count} =
        count_queries(fn ->
          PublicRead.resolve(PublicReadFixtureSupport.kind(), "not-a-valid-handle!!")
        end)

      assert result == :not_found

      assert count == 1,
             "expected exactly one Repo query for a malformed handle (case 1), got #{count}"
    end

    test "an unknown, well-formed handle performs exactly one round-trip before refusal (AC-6)" do
      {result, count} =
        count_queries(fn ->
          PublicRead.resolve(
            PublicReadFixtureSupport.kind(),
            PublicReadFixtureSupport.unknown_handle()
          )
        end)

      assert result == :not_found
      assert count == 1, "expected exactly one Repo query for an unknown handle, got #{count}"
    end

    test "a resolved handle performs exactly two round-trips on success (AC-6)" do
      %{tenant_id: tenant_id, schema_name: schema} = PublicReadFixtureSupport.provision_tenant!()
      resource = PublicReadFixtureSupport.insert_resource!(schema, %{publishable: true})
      plaintext = PublicReadFixtureSupport.issue_handle!(tenant_id, resource.id)

      {result, count} =
        count_queries(fn ->
          PublicRead.resolve(PublicReadFixtureSupport.kind(), plaintext)
        end)

      assert {:ok, %{"kind" => _, "issued_at" => _, "data" => %{"label" => "fixture"}}} = result

      assert count == 2,
             "expected exactly two Repo queries on success (round-trip 1 + round-trip 2), " <>
               "got #{count}. This design's own §9 states resolve/2 issues no explicit " <>
               "Ecto.Multi/Repo.transaction/1 of its own, so no BEGIN/COMMIT fires on this " <>
               "path at all -- both round-trips are plain Repo.one/1 and Repo.get/3 calls, " <>
               "so this count is a count of SELECT events only, with no transaction-control " <>
               "noise to subtract."
    end
  end
end
