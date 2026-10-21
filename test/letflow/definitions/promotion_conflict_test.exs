defmodule Letflow.Definitions.PromotionConflictTest do
  @moduledoc """
  Tests for `Letflow.Definitions.PromotionConflict.reject_if_conflicts/4` (REQ-036,
  PRM-02). See `test/specs/REQ-036.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Fixture strategy

  `reject_if_conflicts/4` reads `process_definitions` under a single (target)
  tenant's schema, so each test that needs real rows provisions ONE real tenant
  schema via `provisioned_tenant/0`, mirroring
  `test/letflow/definitions/snapshot_store_test.exs`'s own `provisioned_tenant/1`
  pattern (real `CREATE SCHEMA` + `TenantProvisioning.replay_migrations/1`, Sandbox
  `:auto` mode + manual `on_exit/1` cleanup, `async: false` for the whole module).
  This file defines its own private copy of the fixture helpers rather than sharing
  them with `promotion_plan_test.exs` -- matches this project's established
  per-test-file self-sufficiency convention (`snapshot_store_test.exs`,
  `migrations_test.exs` each define their own too).

  Every ACTIVE fixture row is inserted via `ProcessDefinition.create_changeset/2` +
  `Repo.insert!/2`, then activated via a guarded raw UPDATE (create_changeset/2 never
  casts `:status`, design INV-DEF-8) -- mirrors `migrations_test.exs`'s own
  `activate/2` helper.

  ## The list-length-mismatch guard tests deliberately do NOT provision a schema

  `reject_if_conflicts/4`'s first function clause matches on
  `length(process_key) != length(base_version)` alone (`_actor_id`, `_target_tenant_id`
  are both wildcarded) -- per design §4.2 step 1, this must short-circuit before ANY
  `TenantProvisioning`/`Repo` call. The mismatch tests below pass an UNPROVISIONED
  `target_tenant_id` (a bare `Ecto.UUID.generate/0`, no `CREATE SCHEMA` ever run for
  it) specifically so that a passing test proves the guard fired without touching
  Postgres at all -- if the implementation regressed to attempt a DB read first, that
  read would raise (querying a schema that was never created), not return the clean
  `{:error, :mismatched_process_key_list}` tuple asserted below.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionConflict
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req036-conflict",
      display_name: "REQ-036 PromotionConflict Test Tenant"
    )
  end

  defp unique_process_key(prefix \\ "req036-conf") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_definition!(schema_name, attrs) do
    base = %{
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  defp activate!(schema_name, id) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(id)]
             )
  end

  defp insert_active_definition!(schema_name, attrs) do
    definition = insert_definition!(schema_name, attrs)
    activate!(schema_name, definition.id)
    %{definition | status: :active}
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "reject_if_conflicts/4 with target_active_version >
  # base_version returns a rejection detail naming the conflicting definition; with
  # target_active_version <= base_version (including the target having zero rows)
  # returns no conflict"
  # ---------------------------------------------------------------------------------

  describe "reject_if_conflicts/4 -- acceptance criterion 4" do
    test "target_active_version > base_version -- a rejection detail naming the conflicting definition" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key = unique_process_key()

      definition =
        insert_active_definition!(target_schema, %{name: process_key, version: "5"})

      assert {:error, {:conflicts, [detail]}} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key],
                 ["3"]
               )

      assert detail.process_key == process_key
      assert detail.target_definition_id == definition.id
      assert detail.target_active_version == "5"
      assert detail.base_version == "3"
    end

    test "target_active_version == base_version -- no conflict" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key = unique_process_key()

      insert_active_definition!(target_schema, %{name: process_key, version: "4"})

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key],
                 ["4"]
               )
    end

    test "target_active_version < base_version -- no conflict" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key = unique_process_key()

      insert_active_definition!(target_schema, %{name: process_key, version: "2"})

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key],
                 ["9"]
               )
    end

    test "target has zero rows for process_key -- no conflict, even against base_version \"0\"" do
      %{tenant_id: target_tenant_id} = provisioned_tenant()
      never_created_process_key = unique_process_key()

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [never_created_process_key],
                 ["0"]
               )
    end

    test "multiple pairs: only the conflicting pair is named, non-conflicting pairs contribute nothing" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      conflicting_key = unique_process_key()
      quiet_key = unique_process_key()

      conflicting_def =
        insert_active_definition!(target_schema, %{name: conflicting_key, version: "10"})

      insert_active_definition!(target_schema, %{name: quiet_key, version: "1"})

      assert {:error, {:conflicts, [detail]}} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [conflicting_key, quiet_key],
                 ["1", "5"]
               )

      assert detail.process_key == conflicting_key
      assert detail.target_definition_id == conflicting_def.id
    end

    test "multiple pairs: ALL conflict -- one detail per pair, in input order" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      key_a = unique_process_key()
      key_c = unique_process_key()

      def_a = insert_active_definition!(target_schema, %{name: key_a, version: "10"})
      def_c = insert_active_definition!(target_schema, %{name: key_c, version: "20"})

      assert {:error, {:conflicts, [detail_a, detail_c]}} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [key_a, key_c],
                 ["1", "5"]
               )

      assert detail_a.process_key == key_a
      assert detail_a.target_definition_id == def_a.id
      assert detail_c.process_key == key_c
      assert detail_c.target_definition_id == def_c.id
    end

    test "multiple pairs: ZERO conflicts across all of them -- :ok" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      key_b = unique_process_key()
      key_d = unique_process_key()

      insert_active_definition!(target_schema, %{name: key_b, version: "1"})
      insert_active_definition!(target_schema, %{name: key_d, version: "2"})

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [key_b, key_d],
                 ["5", "9"]
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # List-length-mismatch guard (design §4.2 step 1) -- see moduledoc for why these
  # tests deliberately pass an unprovisioned target_tenant_id.
  # ---------------------------------------------------------------------------------

  describe "reject_if_conflicts/4 -- list-length-mismatch guard" do
    test "process_key longer than base_version -- {:error, :mismatched_process_key_list}, no DB read attempted" do
      unprovisioned_target_tenant_id = Ecto.UUID.generate()

      assert {:error, :mismatched_process_key_list} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 unprovisioned_target_tenant_id,
                 ["a", "b"],
                 ["1"]
               )
    end

    test "base_version longer than process_key -- {:error, :mismatched_process_key_list}, no DB read attempted" do
      unprovisioned_target_tenant_id = Ecto.UUID.generate()

      assert {:error, :mismatched_process_key_list} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 unprovisioned_target_tenant_id,
                 ["a"],
                 ["1", "2"]
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # invalid_tenant_id
  # ---------------------------------------------------------------------------------

  describe "reject_if_conflicts/4 -- invalid_tenant_id" do
    test "a malformed target_tenant_id (equal-length lists, guard does not fire) -- {:error, :invalid_tenant_id}" do
      assert {:error, :invalid_tenant_id} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 "not-a-uuid",
                 ["a"],
                 ["1"]
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # version_greater?/2's numeric-vs-lexicographic fallback (design §9.4) -- exercised
  # indirectly through reject_if_conflicts/4, since version_greater?/2 is private.
  # ---------------------------------------------------------------------------------

  describe "reject_if_conflicts/4 -- version_greater?/2 numeric-vs-lexicographic fallback (design §9.4)" do
    test "an all-numeric-version pair where numeric and lexicographic comparison DISAGREE -- numeric comparison wins" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key = unique_process_key()

      # "10" vs "9": lexicographically "10" < "9" (byte '1' < byte '9'), so a
      # (buggy) lexicographic-only comparison would find NO conflict here. Both
      # sides parse cleanly as integers (10 and 9), so version_greater?/2 must take
      # the numeric branch and correctly find 10 > 9 -- a genuine conflict.
      insert_active_definition!(target_schema, %{name: process_key, version: "10"})

      assert {:error, {:conflicts, [detail]}} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key],
                 ["9"]
               )

      assert detail.target_active_version == "10"
      assert detail.base_version == "9"
    end

    test "a non-numeric-version pair -- falls back to lexicographic byte-wise comparison" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key_conflict = unique_process_key()
      process_key_no_conflict = unique_process_key()

      # Neither "beta" nor "alpha" parses as an integer -- version_greater?/2 falls
      # back to Elixir's default lexicographic `>`. "beta" > "alpha" (b > a) is
      # true -- a conflict.
      insert_active_definition!(target_schema, %{name: process_key_conflict, version: "beta"})

      assert {:error, {:conflicts, [detail]}} =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key_conflict],
                 ["alpha"]
               )

      assert detail.target_active_version == "beta"
      assert detail.base_version == "alpha"

      # The reverse direction: "alpha" > "beta" is false -- no conflict. Proves the
      # fallback is direction-sensitive, not just "any non-numeric pair conflicts".
      insert_active_definition!(target_schema, %{
        name: process_key_no_conflict,
        version: "alpha"
      })

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key_no_conflict],
                 ["beta"]
               )
    end

    test "a numeric-prefix, non-numeric-remainder version does not partially parse -- falls back to lexicographic" do
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()
      process_key = unique_process_key()

      # Integer.parse("12abc") == {12, "abc"} -- the non-empty remainder means
      # version_greater?/2's `with {target_int, ""} <- ...` pattern does NOT match,
      # so this falls to the lexicographic else-branch rather than comparing 12 > 9
      # numerically. Lexicographically "12abc" > "9" is false (byte '1' < byte
      # '9'), so this must be :ok, not a conflict -- a regression that used
      # Integer.parse's partial result directly (numeric 12 > 9) would incorrectly
      # report a conflict here.
      insert_active_definition!(target_schema, %{name: process_key, version: "12abc"})

      assert :ok =
               PromotionConflict.reject_if_conflicts(
                 Ecto.UUID.generate(),
                 target_tenant_id,
                 [process_key],
                 ["9"]
               )
    end
  end
end
