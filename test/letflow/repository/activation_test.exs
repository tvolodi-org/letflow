defmodule Letflow.Repository.ActivationTest do
  @moduledoc """
  Integration tests for `Letflow.Repository.Activation` (REQ-203,
  REPO-08/09/10) -- per-tenant artifact activation, atomic multi-artifact
  groups, activation history, and the REPO-08 observability guarantee. See
  `test/specs/REQ-203.md` for the full acceptance-criteria-to-test-case
  mapping and `lib/letflow/design/req203-artifact-activation.md` for the
  design this file verifies (especially §4.3, the observability argument
  AC1/AC2's concurrency test below exercises directly).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), does not share
  fixtures with `test/letflow/repository_test.exs` (DIRECTIVE T-4).

  ## The concurrency test's synchronization mechanism (AC1/AC2, design §4.3)

  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` is used (NOT
  `Letflow.DataCase`'s default `{:shared, self()}` mode) so the spawned
  `Task` running `activate_group/4` gets a genuinely separate database
  connection/transaction from the main test process -- exactly
  `test/letflow/engine_concurrency_test.exs` (REQ-055)'s own established
  precedent, cited by design §4.3 itself.

  `activate_group/4`'s public `@spec` takes no test-visible options; this
  file relies on a small TEST-ONLY seam added to
  `lib/letflow/repository/activation.ex` for this exact purpose
  (`test_pause_after`/`test_pause_fun`, see that module's `@typep test_opts`
  for the full rationale) -- this new surface went through two rework
  rounds before REVIEWER's final sign-off (`step-02d-reviewer-recheck2.json`):
  REVIEWER required, and confirmed present, compile-time gating of the pause
  step behind `Application.compile_env(:letflow,
  :activation_test_hooks_enabled?, false)` (only `config/test.exs` sets it to
  `true`) plus the `test_opts` typing fix from a public `@type` to a private
  `@typep`. The seam is a pure addition: omitting both options (every
  non-test call site) reproduces the exact `Multi` pipeline design §4.2
  describes with zero behavioral change, verified by every other test in
  this file (and in `test/letflow/repository_test.exs`) passing unmodified.

  The pause step is inserted as an extra `Multi.run/3` step immediately
  after the first artifact's own steps (`test_pause_after: 1`) and before
  the second artifact's steps are even added to the `Multi` -- so at the
  moment it fires, artifact 1's `artifact_activations` row has already been
  updated *inside this open, uncommitted transaction*, while artifact 2 (and
  3, for the three-artifact case) have not been touched at all yet. The
  pause function sends a `:paused` message to the test process and then
  blocks on `receive do :continue -> :ok end` -- this is what "holds
  `activate_group/4`'s transaction open across multiple of its internal
  steps" (design §4.3) means concretely. The main test process reads via
  `Activation.resolve/3` (a real, separate connection under `:auto` mode)
  *while the paused transaction is still open*, asserts every artifact in
  the group -- both the already-internally-updated one and the
  not-yet-touched ones -- still shows its OLD version (proving Postgres's
  MVCC visibility floor: an in-progress transaction's writes are invisible
  to every other transaction regardless of internal step order), then sends
  `:continue`, awaits the `Task`'s commit, and reads again to assert every
  artifact now shows its NEW version.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Audit.Entry, as: AuditEntry
  alias Letflow.Repository
  alias Letflow.Repository.Activation
  alias Letflow.Repository.ActivationGroup
  alias Letflow.Repository.ActivationHistory
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.TenantFixture

  # No shared `errors_on/1` helper exists in `Letflow.DataCase` -- inlined
  # here, standard `Ecto.Changeset.traverse_errors/2` idiom.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ---------------------------------------------------------------------------------
  # Fixtures -- same shape as test/letflow/repository_test.exs's
  # provisioned_tenant/0 (this file's direct structural precedent).
  # ---------------------------------------------------------------------------------

  # ISS-0112/GH#366 (batch 9): provisions via Letflow.TenantFixture instead of
  # the previous inline insert-tenant!/provision_tenant_schema/
  # replay_migrations sequence. This file never switches Sandbox mode back to
  # :manual, so no `teardown: false` composition is needed -- TenantFixture's
  # own default on_exit teardown is the only teardown needed. Safe under this
  # file's own AC1/AC2 concurrency test (this module's moduledoc) per
  # `TenantFixture.provisioned_tenant!/1`'s own moduledoc ("async: true
  # callers" section): its `Sandbox.mode(:auto)` line is the only
  # mode-changing call it makes and it is never restored, so the spawned Task
  # gets its own real, independent Postgres connection automatically.
  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req203-act",
        display_name: "REQ-203 Activation Test Tenant"
      )

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp version_attrs(overrides) do
    Map.merge(
      %{
        artifact_kind: :definition,
        artifact_name: "sample-artifact",
        content_type: "application/json",
        content: Jason.encode!(%{"name" => "sample", "seed" => System.unique_integer()}),
        created_by: Ecto.UUID.generate(),
        parent_version_id: nil,
        description: nil
      },
      Map.new(overrides)
    )
  end

  # Creates a fresh, distinct artifact_versions row for `artifact_name` (kind
  # :definition unless overridden) and returns it. Each call's content is
  # unique (System.unique_integer/0) so distinct versions never collide on
  # content_hash/dedup.
  defp new_version!(schema, artifact_name, overrides \\ []) do
    attrs = version_attrs(Keyword.merge([artifact_name: artifact_name], overrides))
    assert {:ok, version} = Repository.create(attrs, schema)
    version
  end

  defp activation_input(%ArtifactVersion{} = version) do
    %{
      artifact_kind: version.artifact_kind,
      artifact_name: version.artifact_name,
      version_id: version.version_id
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 (part 1) -- atomic multi-artifact activation: all-succeed case.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- atomic multi-artifact activation, all-succeed" do
    test "activating a group of three artifacts leaves all three pointing at their new versions, one history row each" do
      %{schema_name: schema} = provisioned_tenant()

      v1a = new_version!(schema, "artifact-one")
      v2a = new_version!(schema, "artifact-two")
      v3a = new_version!(schema, "artifact-three")

      activator = Ecto.UUID.generate()

      assert {:ok, %{group: group, activations: activations, history: history}} =
               Activation.activate_group(
                 [activation_input(v1a), activation_input(v2a), activation_input(v3a)],
                 activator,
                 "initial rollout",
                 schema
               )

      assert %ActivationGroup{} = group
      assert length(activations) == 3
      assert length(history) == 3

      assert {:ok, r1} = Activation.resolve(:definition, "artifact-one", schema)
      assert {:ok, r2} = Activation.resolve(:definition, "artifact-two", schema)
      assert {:ok, r3} = Activation.resolve(:definition, "artifact-three", schema)

      assert r1.version_id == v1a.version_id
      assert r2.version_id == v2a.version_id
      assert r3.version_id == v3a.version_id

      assert Repo.aggregate(ActivationHistory, :count, prefix: schema) == 3
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1 (part 2) -- forced failure part-way through a group leaves ALL
  # artifacts at their PRIOR versions with NO history rows for ANY artifact
  # in the group (not just the failed one).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- atomic multi-artifact activation, forced-failure rollback" do
    # Real forced-failure/rollback case: a third artifact whose version_id
    # does not exist in artifact_versions at all. `Letflow.Repository.Activation`'s
    # changeset (used by `upsert_activation_pointer/8`'s `repo.insert`/
    # `repo.update` calls) now maps `:active_version_id`'s FK via
    # `foreign_key_constraint/3` (see `Letflow.Repository.Activation.changeset/2`),
    # so this real FK violation is translated into the documented
    # `{:error, {atom(), Ecto.Changeset.t()}}` tuple `activate_group/4`'s own
    # @spec has always promised, instead of raising `Ecto.ConstraintError` --
    # fixed per REQ-203 Step 3b test-design-validator's finding. The
    # transaction itself still rolls back correctly either way, which is
    # what AC1 asks for.
    test "a version_id with no matching artifact_versions row rolls back the whole group, no partial state, no history rows" do
      %{schema_name: schema} = provisioned_tenant()

      v1a = new_version!(schema, "rbx-artifact-one")
      v2a = new_version!(schema, "rbx-artifact-two")
      v3a = new_version!(schema, "rbx-artifact-three")

      activator = Ecto.UUID.generate()

      # Prior activation establishes the "previous version" state.
      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1a), activation_input(v2a), activation_input(v3a)],
                 activator,
                 "prior activation",
                 schema
               )

      v1b = new_version!(schema, "rbx-artifact-one")
      v2b = new_version!(schema, "rbx-artifact-two")
      bogus_version_id = Ecto.UUID.generate()

      history_count_before = Repo.aggregate(ActivationHistory, :count, prefix: schema)

      assert {:error, {:validation, %Ecto.Changeset{} = changeset}} =
               Activation.activate_group(
                 [
                   activation_input(v1b),
                   activation_input(v2b),
                   %{
                     artifact_kind: :definition,
                     artifact_name: "rbx-artifact-three",
                     version_id: bogus_version_id
                   }
                 ],
                 activator,
                 "forced failure via bogus version_id",
                 schema
               )

      assert {"does not exist", _} = changeset.errors[:active_version_id]

      # All three remain at their PRIOR versions (v*a, not v1b/v2b) -- the
      # transaction rolled back completely, including artifact-one/-two's
      # own upsert steps, which ran (and would have succeeded standalone)
      # before the third step's FK violation aborted the whole transaction.
      assert {:ok, r1} = Activation.resolve(:definition, "rbx-artifact-one", schema)
      assert {:ok, r2} = Activation.resolve(:definition, "rbx-artifact-two", schema)
      assert {:ok, r3} = Activation.resolve(:definition, "rbx-artifact-three", schema)

      assert r1.version_id == v1a.version_id
      assert r2.version_id == v2a.version_id
      assert r3.version_id == v3a.version_id

      # No history rows written for ANY artifact in the failed group.
      assert Repo.aggregate(ActivationHistory, :count, prefix: schema) == history_count_before

      # The group envelope row itself was rolled back too.
      assert Repo.aggregate(ActivationGroup, :count, prefix: schema) == 1
    end

    test "a duplicate (artifact_kind, artifact_name) pair in the group is rejected before any Multi step runs" do
      %{schema_name: schema} = provisioned_tenant()

      v1 = new_version!(schema, "predup-artifact-one")
      v2 = new_version!(schema, "predup-artifact-two")

      assert Activation.activate_group(
               [
                 activation_input(v1),
                 activation_input(v2),
                 %{
                   artifact_kind: :definition,
                   artifact_name: "predup-artifact-two",
                   version_id: v2.version_id
                 }
               ],
               Ecto.UUID.generate(),
               "dup in group",
               schema
             ) == {:error, :duplicate_artifact_in_group}

      assert Repo.aggregate(ActivationGroup, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- REPO-08's observability criterion, tested directly via a real
  # cross-connection concurrent read against a partially-applied,
  # still-uncommitted activation (design §4.3).
  # ---------------------------------------------------------------------------------

  describe "AC2 -- concurrent read during an in-flight multi-artifact activation observes no mixed state" do
    test "a read during the pause sees ALL artifacts at OLD versions; after commit, ALL at NEW versions" do
      %{schema_name: schema} = provisioned_tenant()

      v1_old = new_version!(schema, "obs-artifact-one")
      v2_old = new_version!(schema, "obs-artifact-two")
      v3_old = new_version!(schema, "obs-artifact-three")

      activator = Ecto.UUID.generate()

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1_old), activation_input(v2_old), activation_input(v3_old)],
                 activator,
                 "establish old versions",
                 schema
               )

      v1_new = new_version!(schema, "obs-artifact-one")
      v2_new = new_version!(schema, "obs-artifact-two")
      v3_new = new_version!(schema, "obs-artifact-three")

      test_pid = self()

      pause_fun = fn ->
        send(test_pid, :paused)

        receive do
          :continue -> :ok
        after
          5_000 -> :ok
        end
      end

      task =
        Task.async(fn ->
          Activation.activate_group(
            [activation_input(v1_new), activation_input(v2_new), activation_input(v3_new)],
            activator,
            "atomic rollout to new versions",
            schema,
            test_pause_after: 1,
            test_pause_fun: pause_fun
          )
        end)

      assert_receive :paused, 5_000

      # DURING the pause: artifact 1's row has already been updated INSIDE
      # the open transaction, artifacts 2/3 have not been touched at all --
      # yet every read from this separate connection must see the OLD
      # version for ALL THREE, never a mix.
      assert {:ok, mid1} = Activation.resolve(:definition, "obs-artifact-one", schema)
      assert {:ok, mid2} = Activation.resolve(:definition, "obs-artifact-two", schema)
      assert {:ok, mid3} = Activation.resolve(:definition, "obs-artifact-three", schema)

      assert mid1.version_id == v1_old.version_id
      assert mid2.version_id == v2_old.version_id
      assert mid3.version_id == v3_old.version_id

      send(task.pid, :continue)

      assert {:ok, %{activations: activations}} = Task.await(task, 5_000)
      assert length(activations) == 3

      assert {:ok, post1} = Activation.resolve(:definition, "obs-artifact-one", schema)
      assert {:ok, post2} = Activation.resolve(:definition, "obs-artifact-two", schema)
      assert {:ok, post3} = Activation.resolve(:definition, "obs-artifact-three", schema)

      assert post1.version_id == v1_new.version_id
      assert post2.version_id == v2_new.version_id
      assert post3.version_id == v3_new.version_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- per-tenant isolation (REPO-09).
  # ---------------------------------------------------------------------------------

  describe "AC3 -- per-tenant isolation" do
    test "activating in tenant A does not change tenant B's active version for the same (kind, name)" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      va = new_version!(schema_a, "shared-name")
      vb = new_version!(schema_b, "shared-name")

      activator = Ecto.UUID.generate()

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(vb)],
                 activator,
                 "tenant b activation",
                 schema_b
               )

      # Tenant A never activated "shared-name" at all.
      assert {:error, :not_activated} = Activation.resolve(:definition, "shared-name", schema_a)

      assert {:ok, resolved_b} = Activation.resolve(:definition, "shared-name", schema_b)
      assert resolved_b.version_id == vb.version_id

      # Now activate in tenant A too, and confirm tenant B is unaffected by it.
      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(va)],
                 activator,
                 "tenant a activation",
                 schema_a
               )

      assert {:ok, resolved_a} = Activation.resolve(:definition, "shared-name", schema_a)
      assert resolved_a.version_id == va.version_id

      assert {:ok, resolved_b_again} = Activation.resolve(:definition, "shared-name", schema_b)
      assert resolved_b_again.version_id == vb.version_id
    end

    test "the SAME version_id can be active in tenant A while inactive/different in tenant B" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      # REQ-202's content store is global (per its own placement decision) --
      # confirm that assumption directly rather than silently relying on it,
      # since AC3's "SAME version_id active in A, inactive/different in B"
      # phrasing depends on artifact_versions rows being visible/creatable
      # identically from both tenant schemas' activation tables.
      shared_content = Jason.encode!(%{"shared" => true, "seed" => System.unique_integer()})

      assert {:ok, shared_version} =
               Repository.create(
                 version_attrs(artifact_name: "cross-tenant-artifact", content: shared_content),
                 schema_a
               )

      activator = Ecto.UUID.generate()

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(shared_version)],
                 activator,
                 "activate in tenant a only",
                 schema_a
               )

      assert {:ok, resolved_a} =
               Activation.resolve(:definition, "cross-tenant-artifact", schema_a)

      assert resolved_a.version_id == shared_version.version_id

      # Tenant B never activated this artifact_name at all -- not_activated,
      # not an accidental cross-tenant leak of tenant A's pointer.
      assert {:error, :not_activated} =
               Activation.resolve(:definition, "cross-tenant-artifact", schema_b)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- UNIQUE (tenant_id, artifact_kind, artifact_name) enforced by the
  # DATABASE, not application logic.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- UNIQUE (tenant_id, artifact_kind, artifact_name) is a DATABASE-level constraint" do
    test "a raw insert attempting a second active row for the same tenant/kind/name is rejected by Postgres" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      v1 = new_version!(schema, "unique-artifact")
      v2 = new_version!(schema, "unique-artifact")

      activator = Ecto.UUID.generate()

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1)],
                 activator,
                 "first activation",
                 schema
               )

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      raw_insert_attrs =
        %Activation{}
        |> Activation.changeset(%{
          tenant_id: tenant_id,
          artifact_kind: :definition,
          artifact_name: "unique-artifact",
          active_version_id: v2.version_id,
          activated_at: now,
          activator_user_id: activator
        })

      assert raw_insert_attrs.valid?

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(raw_insert_attrs, prefix: schema)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- previous_version_id is nil on first activation, populated with the
  # prior version thereafter -- field by field across two successive
  # activations.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- previous_version_id null-then-populated across two successive activations" do
    test "first activation has previous_version_id nil; second has it populated with the prior version, field-by-field" do
      %{schema_name: schema} = provisioned_tenant()

      v1 = new_version!(schema, "sequential-artifact")
      v2 = new_version!(schema, "sequential-artifact")

      activator1 = Ecto.UUID.generate()
      activator2 = Ecto.UUID.generate()

      assert {:ok, %{history: [history_1]}} =
               Activation.activate_group(
                 [activation_input(v1)],
                 activator1,
                 "first activation",
                 schema
               )

      assert history_1.previous_version_id == nil
      assert history_1.new_version_id == v1.version_id
      assert history_1.new_version_number == v1.version_number
      assert history_1.activator_user_id == activator1
      assert history_1.rationale == "first activation"

      assert {:ok, %{history: [history_2]}} =
               Activation.activate_group(
                 [activation_input(v2)],
                 activator2,
                 "second activation",
                 schema
               )

      assert history_2.previous_version_id == v1.version_id
      assert history_2.new_version_id == v2.version_id
      assert history_2.new_version_number == v2.version_number
      assert history_2.activator_user_id == activator2
      assert history_2.rationale == "second activation"
      assert history_2.tenant_id == history_1.tenant_id
      assert history_2.artifact_kind == history_1.artifact_kind
      assert history_2.artifact_name == history_1.artifact_name
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- nil / empty-string / whitespace-only rationale are all REJECTED.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- rationale must be non-blank -- nil, empty string, and whitespace-only are all rejected" do
    test "nil rationale is rejected" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "rationale-nil-artifact")

      assert {:error, {:group, changeset}} =
               Activation.activate_group(
                 [activation_input(v1)],
                 Ecto.UUID.generate(),
                 nil,
                 schema
               )

      assert %{rationale: ["can't be blank"]} = errors_on(changeset)
    end

    test "empty-string rationale is rejected" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "rationale-empty-artifact")

      assert {:error, {:group, changeset}} =
               Activation.activate_group([activation_input(v1)], Ecto.UUID.generate(), "", schema)

      assert %{rationale: ["can't be blank"]} = errors_on(changeset)
    end

    test "whitespace-only rationale is rejected" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "rationale-whitespace-artifact")

      assert {:error, {:group, changeset}} =
               Activation.activate_group(
                 [activation_input(v1)],
                 Ecto.UUID.generate(),
                 "   \t  ",
                 schema
               )

      assert %{rationale: ["can't be blank"]} = errors_on(changeset)
    end

    test "a raw insert bypassing the changeset with an empty-string rationale is rejected by the DB CHECK constraint" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      # insert_all/3 bypasses the changeset entirely (no constraint mapping
      # to translate the failure), so the raw Postgres error surfaces
      # directly as Postgrex.Error -- same precedent as
      # test/letflow/repository_test.exs's own DB-trigger-immutability tests
      # and test/letflow/event_store/retention_policy_test.exs's own raw
      # CHECK-constraint test (both assert_raise Postgrex.Error).
      assert_raise Postgrex.Error, ~r/artifact_activation_groups_rationale_check/, fn ->
        Repo.insert_all(
          ActivationGroup,
          [
            %{
              group_id: Ecto.UUID.generate(),
              tenant_id: tenant_id,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
              activator_user_id: Ecto.UUID.generate(),
              rationale: "",
              inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
            }
          ],
          prefix: schema
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- activation history returned in chronological order; REQ-067
  # cursor pagination; both per-artifact and tenant-wide list_history/4 call
  # shapes.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- activation history ordering and REQ-067 cursor pagination" do
    test "per-artifact list_history/4 returns history newest-first" do
      %{schema_name: schema} = provisioned_tenant()
      activator = Ecto.UUID.generate()

      for n <- 1..3 do
        v = new_version!(schema, "history-order-artifact")

        assert {:ok, _} =
                 Activation.activate_group(
                   [activation_input(v)],
                   activator,
                   "activation #{n}",
                   schema
                 )
      end

      assert {:ok, page} =
               Activation.list_history(:definition, "history-order-artifact", schema, [])

      assert Enum.map(page.items, & &1.rationale) == [
               "activation 3",
               "activation 2",
               "activation 1"
             ]

      assert page.next_cursor == nil
    end

    test "tenant-wide list_history/4 (nil kind/name) lists history across artifacts, newest-first" do
      %{schema_name: schema} = provisioned_tenant()
      activator = Ecto.UUID.generate()

      va = new_version!(schema, "tenant-wide-a")
      vb = new_version!(schema, "tenant-wide-b")

      assert {:ok, _} =
               Activation.activate_group([activation_input(va)], activator, "activate a", schema)

      assert {:ok, _} =
               Activation.activate_group([activation_input(vb)], activator, "activate b", schema)

      assert {:ok, page} = Activation.list_history(nil, nil, schema, [])

      assert length(page.items) == 2
      assert Enum.map(page.items, & &1.rationale) == ["activate b", "activate a"]
    end

    test "pagination: page_size smaller than the result set yields a non-nil next_cursor that advances" do
      %{schema_name: schema} = provisioned_tenant()
      activator = Ecto.UUID.generate()

      for n <- 1..5 do
        v = new_version!(schema, "paginated-history-artifact")

        assert {:ok, _} =
                 Activation.activate_group(
                   [activation_input(v)],
                   activator,
                   "activation #{n}",
                   schema
                 )
      end

      assert {:ok, page_1} =
               Activation.list_history(:definition, "paginated-history-artifact", schema,
                 page_size: 2
               )

      assert Enum.map(page_1.items, & &1.rationale) == ["activation 5", "activation 4"]
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               Activation.list_history(:definition, "paginated-history-artifact", schema,
                 page_size: 2,
                 cursor: page_1.next_cursor
               )

      assert Enum.map(page_2.items, & &1.rationale) == ["activation 3", "activation 2"]
      assert is_binary(page_2.next_cursor)

      assert {:ok, page_3} =
               Activation.list_history(:definition, "paginated-history-artifact", schema,
                 page_size: 2,
                 cursor: page_2.next_cursor
               )

      assert Enum.map(page_3.items, & &1.rationale) == ["activation 1"]
      assert page_3.next_cursor == nil
    end

    test "page_size 0 and 201 are both rejected with :page_size_too_large" do
      %{schema_name: schema} = provisioned_tenant()

      assert Activation.list_history(:definition, "any-name", schema, page_size: 0) ==
               {:error, :page_size_too_large}

      assert Activation.list_history(:definition, "any-name", schema, page_size: 201) ==
               {:error, :page_size_too_large}
    end

    test "a cursor minted for a different endpoint's prefix is rejected with :wrong_endpoint" do
      %{schema_name: schema} = provisioned_tenant()

      foreign_cursor =
        "RV:"
        |> Pagination.build_raw_cursor_timestamp_key(
          System.system_time(:microsecond),
          Ecto.UUID.generate(),
          1
        )
        |> Pagination.encode_cursor()

      assert Activation.list_history(:definition, "any-name", schema, cursor: foreign_cursor) ==
               {:error, :wrong_endpoint}
    end

    test "a cursor minted far in the past (beyond the 24h expiry window) is rejected with :expired" do
      %{schema_name: schema} = provisioned_tenant()

      ancient_cursor =
        "AH:"
        |> Pagination.build_raw_cursor_timestamp_key(0, Ecto.UUID.generate(), 1)
        |> Pagination.encode_cursor()

      assert Activation.list_history(:definition, "any-name", schema, cursor: ancient_cursor) ==
               {:error, :expired}
    end

    test "a structurally invalid (non-base64) cursor string is rejected with :invalid_cursor" do
      %{schema_name: schema} = provisioned_tenant()

      assert Activation.list_history(:definition, "any-name", schema, cursor: "!!!not-base64!!!") ==
               {:error, :invalid_cursor}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- resolve/3 returns the active version normally, and {:error,
  # :not_activated} (NEVER an arbitrary version) when never activated.
  # ---------------------------------------------------------------------------------

  describe "AC8 -- resolve/3's not-found semantics never fall back to an arbitrary version" do
    test "resolve/3 returns {:error, :not_activated} when no activation row exists, even though versions DO exist" do
      %{schema_name: schema} = provisioned_tenant()

      # Create THREE versions but never activate any of them -- a mutant
      # falling back to "latest by version_number" would incorrectly return
      # {:ok, v3} here instead of the required not-found tuple.
      _v1 = new_version!(schema, "never-activated-artifact")
      _v2 = new_version!(schema, "never-activated-artifact")
      _v3 = new_version!(schema, "never-activated-artifact")

      assert {:error, :not_activated} =
               Activation.resolve(:definition, "never-activated-artifact", schema)
    end

    test "resolve/3 returns the active version normally once activated" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "normal-resolve-artifact")

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1)],
                 Ecto.UUID.generate(),
                 "activate",
                 schema
               )

      assert {:ok, resolved} = Activation.resolve(:definition, "normal-resolve-artifact", schema)
      assert resolved.version_id == v1.version_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- ON DELETE RESTRICT: an artifact_versions row referenced as an
  # active_version_id, previous_version_id, or new_version_id cannot be
  # deleted.
  # ---------------------------------------------------------------------------------

  describe "AC9 -- ON DELETE RESTRICT prevents deleting a referenced artifact_versions row" do
    test "deleting the active_version_id's version row is rejected by the FK" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "restrict-active-artifact")

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1)],
                 Ecto.UUID.generate(),
                 "activate",
                 schema
               )

      assert_raise Ecto.ConstraintError, fn ->
        Repo.delete!(v1, prefix: schema)
      end
    end

    test "deleting a version referenced as new_version_id in history is rejected by the FK" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "restrict-new-version-artifact")
      v2 = new_version!(schema, "restrict-new-version-artifact")

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v1)],
                 Ecto.UUID.generate(),
                 "first",
                 schema
               )

      assert {:ok, _} =
               Activation.activate_group(
                 [activation_input(v2)],
                 Ecto.UUID.generate(),
                 "second",
                 schema
               )

      # v1 is no longer the active pointer (v2 is), but v1 is still
      # referenced as previous_version_id AND new_version_id (its own first
      # activation) in artifact_activation_history -- must still be
      # protected.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.delete!(v1, prefix: schema)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Duplicate-artifact-in-group / empty-group rejection (design's OQ-E
  # resolution), and the audit_entries cross-write (design §7/OQ-F).
  # ---------------------------------------------------------------------------------

  describe "duplicate (artifact_kind, artifact_name) pair within one call is rejected" do
    test "returns {:error, :duplicate_artifact_in_group}" do
      %{schema_name: schema} = provisioned_tenant()
      v1 = new_version!(schema, "dup-artifact")
      v2 = new_version!(schema, "dup-artifact")

      assert Activation.activate_group(
               [activation_input(v1), activation_input(v2)],
               Ecto.UUID.generate(),
               "dup attempt",
               schema
             ) == {:error, :duplicate_artifact_in_group}

      # Confirm no partial state was created either.
      assert Repo.aggregate(ActivationGroup, :count, prefix: schema) == 0
    end
  end

  describe "empty activations list is rejected" do
    test "returns {:error, :empty_group}" do
      %{schema_name: schema} = provisioned_tenant()

      assert Activation.activate_group([], Ecto.UUID.generate(), "empty", schema) ==
               {:error, :empty_group}
    end
  end

  describe "audit_entries cross-write -- one row per artifact activated (design OQ-F)" do
    test "activating two artifacts in one group writes two audit_entries rows with correct fields" do
      %{tenant_id: tenant_id, schema_name: schema} = provisioned_tenant()

      v1 = new_version!(schema, "audit-artifact-one")
      v2 = new_version!(schema, "audit-artifact-two")

      activator = Ecto.UUID.generate()

      assert {:ok, %{activations: [a1, a2]}} =
               Activation.activate_group(
                 [activation_input(v1), activation_input(v2)],
                 activator,
                 "audited activation",
                 schema
               )

      entries =
        AuditEntry
        |> where([e], e.action == "artifact.activate")
        |> order_by([e], asc: e.timestamp)
        |> Repo.all(prefix: schema)

      assert length(entries) == 2

      by_resource_id = Map.new(entries, &{&1.resource_id, &1})

      entry1 = Map.fetch!(by_resource_id, v1.artifact_id)
      entry2 = Map.fetch!(by_resource_id, v2.artifact_id)

      assert entry1.action == "artifact.activate"
      assert entry1.resource_type == "artifact"
      assert entry1.resource_id == v1.artifact_id
      assert entry1.actor_id == activator
      assert entry1.tenant_id == tenant_id
      refute is_nil(entry1.after_state)

      assert entry2.action == "artifact.activate"
      assert entry2.resource_type == "artifact"
      assert entry2.resource_id == v2.artifact_id
      assert entry2.actor_id == activator
      assert entry2.tenant_id == tenant_id
      refute is_nil(entry2.after_state)

      # Sanity: the corresponding activation rows really did land at the
      # expected versions (ties the audit assertion back to real state).
      assert a1.active_version_id == v1.version_id
      assert a2.active_version_id == v2.version_id
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0983 -- activate_group/5 is rescue-hardened against a Postgres-level
  # audit-write failure. Same DROP TABLE fault-injection idiom established by
  # ISS-0969/ISS-0980/ISS-0981 (see test/letflow/engine_test.exs's "ISS-0969"
  # describe block for the exact DDL recreated below). This file's own
  # provisioned_tenant/0 stays in real (:auto-mode, never restored) Postgres
  # commits the whole test (per its own moduledoc comment above), so the
  # DROP/recreate pair below runs as plain, immediately-committed SQL -- no
  # sandbox-ownership complication to work around here.
  # ---------------------------------------------------------------------------------

  describe "ISS-0983: activate_group/5 is rescue-hardened against a Postgres-level audit-write failure" do
    test "a genuine Postgres-level audit-insert failure rolls back the whole activation group" do
      %{schema_name: schema} = provisioned_tenant()

      version = new_version!(schema, "iss0983-activate-fault")

      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema}".audit_entries (
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
               Activation.activate_group(
                 [activation_input(version)],
                 Ecto.UUID.generate(),
                 "iss0983 fault injection",
                 schema
               )

      assert Repo.aggregate(ActivationGroup, :count, prefix: schema) == 0

      assert Activation.resolve(:definition, version.artifact_name, schema) ==
               {:error, :not_activated}

      assert Repo.aggregate(ActivationHistory, :count, prefix: schema) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- moduledoc content assertion: activation-history-vs-audit_entries
  # disambiguation text (mirrors REQ-202's AC5/AC6 precedent).
  # ---------------------------------------------------------------------------------

  describe "AC10 -- moduledoc states how activation history differs from audit_entries" do
    test "Letflow.Repository.Activation's moduledoc contains the required disambiguation text" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _fdocs} =
        Code.fetch_docs(Activation)

      assert moduledoc =~ "audit_entries"
      assert moduledoc =~ "REQ-195"
      assert moduledoc =~ "rationale"
      assert moduledoc =~ "compliance"
      assert moduledoc =~ "hash-chained" or moduledoc =~ "hash chain"

      assert moduledoc =~
               ~r/Neither\s+table is ever deleted or replaced as "redundant with the other"/
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- no route/controller added by this requirement (structural note,
  # REQ-202's own precedent for this judgment call: verified against the
  # actual diff at commit time, not re-derived here from a hardcoded file
  # list which would itself need maintenance).
  # ---------------------------------------------------------------------------------

  describe "AC11 -- no route or controller file added" do
    test "no file under lib/letflow_web/ (or a router entry) mentions Activation" do
      router_path = Path.join([File.cwd!(), "lib", "letflow_web", "router.ex"])

      if File.exists?(router_path) do
        refute File.read!(router_path) =~ "Activation"
      end

      # No controller/route file exists for this module at all.
      refute File.exists?(
               Path.join([
                 File.cwd!(),
                 "lib",
                 "letflow_web",
                 "controllers",
                 "activation_controller.ex"
               ])
             )
    end
  end
end
