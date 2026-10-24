defmodule Letflow.AuditDispositionsTest do
  @moduledoc """
  Gap-fill tests for REQ-195, added at the TEST-DESIGN step (step 03) after
  independently re-deriving coverage against all 12 ACs and the handoff's
  additional actor_id-disposition item. Does NOT duplicate
  `test/letflow/audit_test.exs` (AC1/AC4/AC5/AC6/AC9, direct `Letflow.Audit`
  tests) or `test/letflow/audit_capture_test.exs` (AC2's three named
  operations, AC3). This file covers two genuine gaps found on cross-check:

  1. AC7's "independent-computation cross-check" clause: a test asserting a
     *hand-computed* `chain_hash` (this file's own from-scratch netstring +
     SHA-256 implementation, written without calling any private function of
     `Letflow.Audit`) matches the value `Letflow.Audit.insert_entry/3`
     actually persisted -- proving two independent implementations of design
     §5 agree, not merely that the same code round-trips through itself.

  2. The handoff's explicit "additionally cover" item: every call site this
     requirement gave an explicit, stated `actor_id: nil` disposition
     (`Letflow.Definitions.create/2`/`deprecate/2`/`archive/2`,
     `Letflow.Identity`'s six functions, `Letflow.Tasks.assign_task/3`,
     `Letflow.Engine.TaskActivation`'s `task.create` capture site) writes a
     real (non-placeholder) `before_state`/`after_state` alongside a
     genuinely `nil` `actor_id` -- not silently defaulting to some other
     placeholder, and not merely asserting `{:ok, _}`.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1. Self-contained: does
  not share fixtures with `audit_test.exs`/`audit_capture_test.exs`
  (DIRECTIVE T-4) -- the provisioning/graph/instance helpers below are the
  same deliberately-narrowed local copy those two files already establish.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers (local copy, DIRECTIVE T-4) -- provisions via
  # Letflow.TenantFixture (ISS-0112 / GH#366), teardown: false because this file
  # wraps provisioning in SandboxAutoMode.provision!/2 and needs its own on_exit
  # to force :auto mode back on before the drop/delete cleanup and restore
  # :manual afterward (the ISS-0580 leak fix) -- TenantFixture's own default
  # teardown does not do that composition, so it stays disabled and this file's
  # pre-existing on_exit is kept untouched, matching category A's documented
  # pattern.
  # ---------------------------------------------------------------------------------

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req195-disp",
          display_name: "REQ-195 Audit Dispositions Test Tenant",
          teardown: false
        )

      on_exit(fn ->
        # ISS-0580 rework: this callback runs AFTER the test process (and thus
        # SandboxAutoMode.provision!/2's own restore-to-:manual-plus-checkout,
        # scoped to that now-gone process) is gone -- so it must not assume
        # :manual mode still has a connection checked out for THIS (OnExitHandler)
        # process. Force :auto mode first so the DROP SCHEMA/delete_all cleanup
        # below always gets a real, checked-in connection regardless of what mode
        # the test process left the pool in. Mirrors role_registry_test.exs's own
        # on_exit/1 handling of this exact hazard.
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> drop_schema!(schema_name)
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))

        # REVIEWER fix (ISS-0580): restore :manual after cleanup -- leaving the
        # force-:auto above unrestored would reopen this exact leak, once per
        # test in this file instead of once ever. No checkout needed (same
        # reasoning as SandboxAutoMode.exit_auto_mode!/1's own doc: this
        # OnExitHandler process is not going to issue another Repo call).
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp base_entry_attrs(overrides) do
    Map.merge(
      %{
        actor_id: nil,
        action: "definition.create",
        resource_type: "definition",
        resource_id: Ecto.UUID.generate(),
        before_state: nil,
        after_state: %{"name" => "sample"},
        trace_id: nil
      },
      Map.new(overrides)
    )
  end

  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("req195-disp-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp draft_definition!(schema_name, graph \\ graph_human_task_end()) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    definition
  end

  defp audit_rows_for(schema_name, action) do
    Entry
    |> where([e], e.action == ^action)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- independent-computation cross-check on the canonical hashed form.
  # A from-scratch reimplementation (never calling Letflow.Audit's private
  # canonical_string/1, compute_hash/1, etc.) must agree with the persisted
  # chain_hash, over a persisted entry's own field values.
  # ---------------------------------------------------------------------------------

  describe "AC7 -- hand-computed chain_hash matches the implementation's output" do
    test "an independently-implemented netstring+SHA-256 encoding reproduces the stored chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{} = entry} =
               Audit.insert_entry(
                 Repo,
                 base_entry_attrs(
                   actor_id: Ecto.UUID.generate(),
                   action: "definition.create",
                   resource_type: "definition",
                   resource_id: "res-hand-computed",
                   before_state: nil,
                   after_state: %{"b" => 2, "a" => 1, "nested" => %{"z" => 1, "y" => 2}},
                   trace_id: "trace-hand-computed"
                 ),
                 schema_name
               )

      assert entry.prev_chain_hash == nil

      assert hand_computed_hash(entry) == entry.chain_hash

      # Second entry, chained off the first -- also cross-checked, so this
      # isn't only exercising the null-prev_chain_hash special case.
      assert {:ok, %Entry{} = entry_2} =
               Audit.insert_entry(
                 Repo,
                 base_entry_attrs(resource_id: "res-hand-computed-2"),
                 schema_name
               )

      assert entry_2.prev_chain_hash == entry.chain_hash
      assert hand_computed_hash(entry_2) == entry_2.chain_hash
    end

    # From-scratch reimplementation of design §5 -- deliberately independent
    # of lib/letflow/audit.ex's own private functions (no call into
    # Letflow.Audit beyond public insert_entry/3, used only to produce a
    # persisted row to check against).
    defp hand_computed_hash(%Entry{} = entry) do
      fields = [
        netstring(entry.id),
        netstring(entry.tenant_id),
        netstring(entry.actor_id),
        netstring(entry.action),
        netstring(entry.resource_type),
        netstring(entry.resource_id),
        netstring(Integer.to_string(DateTime.to_unix(entry.timestamp, :microsecond))),
        netstring(hand_canonical_json(entry.before_state)),
        netstring(hand_canonical_json(entry.after_state)),
        netstring(entry.trace_id),
        netstring(entry.prev_chain_hash)
      ]

      canonical_string = IO.iodata_to_binary(fields)

      :sha256
      |> :crypto.hash(canonical_string)
      |> Base.encode16(case: :lower)
    end

    defp netstring(nil), do: "-1:"
    defp netstring(value) when is_binary(value), do: "#{byte_size(value)}:#{value}"

    defp hand_canonical_json(nil), do: nil

    defp hand_canonical_json(map) when is_map(map) do
      Jason.encode!(hand_sort_keys(map))
    end

    defp hand_sort_keys(map) when is_map(map) do
      map
      |> Enum.map(fn {k, v} -> {to_string(k), hand_sort_keys(v)} end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Jason.OrderedObject.new()
    end

    defp hand_sort_keys(list) when is_list(list), do: Enum.map(list, &hand_sort_keys/1)
    defp hand_sort_keys(other), do: other
  end

  # ---------------------------------------------------------------------------------
  # AC6 rework (TEST-DESIGN-VALIDATOR step-03 rework iteration 1) -- the one
  # scenario that actually distinguishes do_verify_chain/2's documented
  # "recompute before linkage" check order from a linkage-before-recompute
  # order: a persisted entry whose OWN prev_chain_hash column is tampered
  # directly via raw SQL, while that same entry's own chain_hash column is
  # left untouched.
  #
  # Because prev_chain_hash is itself one of the 11 hashed fields (design
  # §5.1 field 11 / lib/letflow/audit.ex moduledoc), this single-column
  # tamper makes BOTH of do_verify_chain/2's cond clauses true for the same
  # entry at once:
  #   - recompute check: fields_from_entry/1 reads the *tampered*
  #     prev_chain_hash, so the freshly recomputed hash no longer matches the
  #     entry's untouched, originally-stored chain_hash -> hash_mismatch.
  #   - linkage check: the tampered prev_chain_hash no longer equals the
  #     previous entry's own (unchanged) recomputed hash -> chain_broken.
  # Since a `cond` returns its FIRST true branch, which error comes back is
  # entirely a function of check order -- this is genuinely order-sensitive,
  # not vacuous. The real (documented) implementation checks recompute first,
  # so this must report hash_mismatch; a reversed-order mutation reports
  # chain_broken for the identical tamper (verified manually against the
  # shipped code by TEST-DESIGNER during this rework -- see this run's
  # handoff for the two real `mix test` outputs quoted).
  # ---------------------------------------------------------------------------------

  describe "AC6 -- check order: a prev_chain_hash-only tamper is hash_mismatch, not chain_broken" do
    test "tampering a persisted entry's prev_chain_hash while leaving its own chain_hash untouched is reported as hash_mismatch" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{chain_hash: chain_hash_1}} =
               Audit.insert_entry(Repo, base_entry_attrs(resource_id: "res-order-1"), schema_name)

      assert {:ok, %Entry{id: id_2, prev_chain_hash: original_prev_hash_2}} =
               Audit.insert_entry(Repo, base_entry_attrs(resource_id: "res-order-2"), schema_name)

      # Sanity: entry 2 really does link to entry 1's real chain_hash before
      # any tamper.
      assert original_prev_hash_2 == chain_hash_1

      # A "valid-looking" but wrong hash -- same shape as a real chain_hash
      # (64 lowercase hex chars), just not the one entry 1 actually produced.
      fake_prev_hash =
        :sha256 |> :crypto.hash("not-the-real-prev-hash") |> Base.encode16(case: :lower)

      refute fake_prev_hash == chain_hash_1

      # Adversarially bypass the immutability trigger (§2/AC1), the same way
      # audit_test.exs's existing AC6 tests do -- overwrite ONLY entry 2's
      # prev_chain_hash column. Its own chain_hash column is deliberately
      # left untouched (not recomputed to match), so entry 2 is left
      # internally INCONSISTENT with its own (tampered) prev_chain_hash --
      # unlike the two scenarios audit_test.exs already covers (a
      # content-only tamper that leaves prev_chain_hash/chain_hash mutually
      # consistent, and a deleted row that leaves every surviving row's own
      # columns mutually consistent).
      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries DISABLE TRIGGER ALL))

      Repo.query!(
        ~s(UPDATE "#{schema_name}".audit_entries SET prev_chain_hash = $1 WHERE id = $2),
        [fake_prev_hash, Ecto.UUID.dump!(id_2)]
      )

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries ENABLE TRIGGER ALL))

      # Confirm the tamper actually landed and chain_hash is genuinely
      # untouched (sanity check on the test itself).
      tampered = Repo.get!(Entry, id_2, prefix: schema_name)
      assert tampered.prev_chain_hash == fake_prev_hash

      # Recompute-before-linkage (the documented, shipped order): the
      # recomputed hash for entry 2 -- built from its now-tampered
      # prev_chain_hash field -- no longer matches its untouched, originally
      # stored chain_hash, so this is caught as hash_mismatch on id_2. A
      # linkage-before-recompute order would instead report
      # {:error, {:chain_broken, id_2}} for this exact same tamper, since the
      # tampered prev_chain_hash also fails the linkage comparison against
      # entry 1's own recomputed hash -- both cond clauses are true here, so
      # only check ORDER decides which error verify_chain/2 returns.
      assert {:error, {:hash_mismatch, ^id_2}} = Audit.verify_chain(schema_name)
      refute match?({:error, {:chain_broken, ^id_2}}, Audit.verify_chain(schema_name))
    end
  end

  # ---------------------------------------------------------------------------------
  # actor_id: nil dispositions -- Definitions.create/2, deprecate/2, archive/2.
  # (activate/2 is already covered, with content assertions, in
  # audit_capture_test.exs.)
  # ---------------------------------------------------------------------------------

  describe "actor_id: nil disposition -- Letflow.Definitions.create/2" do
    test "writes a definition.create audit row with nil actor_id, nil before_state, real after_state" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert [entry] = audit_rows_for(schema_name, "definition.create")
      assert entry.actor_id == nil
      assert entry.resource_type == "definition"
      assert entry.resource_id == definition.id
      assert entry.before_state == nil
      assert entry.after_state["status"] == "draft"
      assert entry.after_state["id"] == definition.id
      assert entry.after_state["name"] == definition.name
    end
  end

  describe "actor_id: nil disposition -- Letflow.Definitions.deprecate/2 and archive/2" do
    test "deprecate/2 writes a real before/after pair with nil actor_id" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: _active}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, %ProcessDefinition{} = deprecated} =
               Definitions.deprecate(definition.id, prefix: schema_name)

      assert [entry] = audit_rows_for(schema_name, "definition.deprecate")
      assert entry.actor_id == nil
      assert entry.resource_id == definition.id
      assert entry.before_state["status"] == "active"
      assert entry.after_state["status"] == "deprecated"
      assert deprecated.status == :deprecated
    end

    test "archive/2 writes a real before/after pair (including archived_at) with nil actor_id" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: _active}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, %ProcessDefinition{}} =
               Definitions.deprecate(definition.id, prefix: schema_name)

      assert {:ok, %ProcessDefinition{} = archived} =
               Definitions.archive(definition.id, prefix: schema_name)

      assert [entry] = audit_rows_for(schema_name, "definition.archive")
      assert entry.actor_id == nil
      assert entry.resource_id == definition.id
      assert entry.before_state["status"] == "deprecated"
      assert entry.after_state["status"] == "archived"
      assert entry.after_state["archived_at"] != nil
      assert archived.status == :archived
    end
  end

  # ---------------------------------------------------------------------------------
  # actor_id: nil dispositions -- Letflow.Identity's six functions (design
  # §3.1b).
  # ---------------------------------------------------------------------------------

  describe "actor_id: nil disposition -- Letflow.Identity" do
    test "create_user/2 writes a user.create audit row with nil actor_id, nil before_state, real after_state (password_hash excluded)" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("req195-user"),
                   "display_name" => "Disposition Test User",
                   "email" => "#{unique_name("req195-user")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert [entry] = audit_rows_for(schema_name, "user.create")
      assert entry.actor_id == nil
      assert entry.resource_type == "user"
      assert entry.resource_id == user.id
      assert entry.before_state == nil
      assert entry.after_state["id"] == user.id
      assert entry.after_state["username"] == user.username
      refute Map.has_key?(entry.after_state, "password_hash")
    end

    test "update_user_profile/3 and update_user_status/3 write real before/after pairs with nil actor_id" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("req195-user-upd"),
                   "display_name" => "Original Name",
                   "email" => "#{unique_name("req195-user-upd")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert {:ok, updated} =
               Identity.update_user_profile(user.id, %{"display_name" => "New Name"},
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert [profile_entry] = audit_rows_for(schema_name, "user.update_profile")
      assert profile_entry.actor_id == nil
      assert profile_entry.before_state["display_name"] == "Original Name"
      assert profile_entry.after_state["display_name"] == "New Name"
      assert updated.display_name == "New Name"

      assert {:ok, deactivated} =
               Identity.update_user_status(user.id, :inactive,
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert [status_entry] = audit_rows_for(schema_name, "user.update_status")
      assert status_entry.actor_id == nil
      assert status_entry.before_state["status"] == "active"
      assert status_entry.after_state["status"] == "inactive"
      assert deactivated.status == :inactive
    end

    test "create_group/2 writes a group.create audit row with nil actor_id, nil before_state, real after_state" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, group} =
               Identity.create_group(%{"name" => unique_name("req195-group")},
                 prefix: schema_name
               )

      assert [entry] = audit_rows_for(schema_name, "group.create")
      assert entry.actor_id == nil
      assert entry.before_state == nil
      assert entry.after_state["id"] == group.id
      assert entry.after_state["name"] == group.name
    end

    test "create_token/3 and revoke_token/2 write real before/after pairs with nil actor_id (token_hash excluded)" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("req195-user-tok"),
                   "display_name" => "Token Owner",
                   "email" => "#{unique_name("req195-user-tok")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert {:ok, %{token: token}} =
               Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
                 prefix: schema_name
               )

      assert [create_entry] = audit_rows_for(schema_name, "token.create")
      assert create_entry.actor_id == nil
      assert create_entry.resource_type == "api_token"
      assert create_entry.resource_id == token.id
      assert create_entry.before_state == nil
      assert create_entry.after_state["id"] == token.id
      refute Map.has_key?(create_entry.after_state, "token_hash")

      assert {:ok, revoked} = Identity.revoke_token(token.id, prefix: schema_name)

      assert [revoke_entry] = audit_rows_for(schema_name, "token.revoke")
      assert revoke_entry.actor_id == nil
      assert revoke_entry.before_state["revoked_at"] == nil
      assert revoke_entry.after_state["revoked_at"] != nil
      refute Map.has_key?(revoke_entry.before_state, "token_hash")
      refute Map.has_key?(revoke_entry.after_state, "token_hash")
      assert revoked.revoked_at != nil
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0983 -- rescue-hardening for the six Letflow.Identity write paths that fold
  # Audit.append_multi/4 into their own Ecto.Multi/Repo.transaction/1. Same
  # DROP TABLE fault-injection idiom established by ISS-0969/ISS-0980/ISS-0981
  # (see test/letflow/engine_test.exs's "ISS-0969" describe block for the exact
  # DDL this file's own on_exit/1 callbacks below recreate).
  # ---------------------------------------------------------------------------------

  describe "ISS-0983: Letflow.Identity write paths are rescue-hardened against a Postgres-level audit-write failure" do
    defp drop_audit_entries!(schema_name) do
      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      # No on_exit recreate here (unlike engine_test.exs's "ISS-0969" describe
      # block): this file's own provisioned_tenant/0 wraps provisioning in
      # `SandboxAutoMode.provision!/2`, which leaves the test running in
      # dedicated (non-shared) :manual mode with a fresh per-test checkout --
      # the DROP TABLE above runs inside that checkout's own sandbox
      # transaction. When the test process exits, Ecto's sandbox ownership
      # monitor automatically rolls that transaction back (reverting the
      # DROP) before any on_exit callback runs -- confirmed empirically: a
      # recreate attempt registered here hits `(Postgrex.Error) ERROR 42P07
      # (duplicate_table)` because the table is already back by the time it
      # runs. `engine_test.exs`'s own provisioned_tenant/0 does not use
      # SandboxAutoMode and stays in DataCase's default `{:shared, self()}`
      # mode instead, where the owning test process's death does not trigger
      # the same automatic rollback-before-on_exit timing, so its recreate
      # on_exit is both necessary and safe there -- not an applicable pattern
      # to copy unmodified into this file's different sandbox-mode shape.
    end

    test "create_user/2 rolls back the user insert when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()
      username = unique_name("iss0983-create-user")

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.create_user(
                 %{
                   "username" => username,
                   "display_name" => "ISS-0983 Fault Injection",
                   "email" => "#{username}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert Repo.aggregate(from(u in User, where: u.username == ^username), :count,
               prefix: schema_name
             ) == 0
    end

    test "update_user_profile/3 rolls back the profile update when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("iss0983-update-profile"),
                   "display_name" => "Original Name",
                   "email" => "#{unique_name("iss0983-update-profile")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.update_user_profile(user.id, %{"display_name" => "New Name"},
                 prefix: schema_name,
                 login_directory: :skip
               )

      reloaded = Repo.get!(User, user.id, prefix: schema_name)
      assert reloaded.display_name == "Original Name"
    end

    test "update_user_status/3 rolls back the status update when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("iss0983-update-status"),
                   "display_name" => "ISS-0983 Status Fixture",
                   "email" => "#{unique_name("iss0983-update-status")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert user.status == :active

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.update_user_status(user.id, :inactive,
                 prefix: schema_name,
                 login_directory: :skip
               )

      reloaded = Repo.get!(User, user.id, prefix: schema_name)
      assert reloaded.status == :active
    end

    test "create_group/2 rolls back the group insert when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()
      group_name = unique_name("iss0983-create-group")

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.create_group(%{"name" => group_name}, prefix: schema_name)

      assert Repo.aggregate(from(g in Group, where: g.name == ^group_name), :count,
               prefix: schema_name
             ) == 0
    end

    test "create_token/3 (via insert_token/3) rolls back the token insert when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("iss0983-create-token"),
                   "display_name" => "ISS-0983 Token Owner",
                   "email" => "#{unique_name("iss0983-create-token")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
                 prefix: schema_name
               )

      assert Repo.aggregate(from(t in ApiToken, where: t.user_id == ^user.id), :count,
               prefix: schema_name
             ) == 0
    end

    test "revoke_token/2 rolls back the revocation when the audit write fails" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, user} =
               Identity.create_user(
                 %{
                   "username" => unique_name("iss0983-revoke-token"),
                   "display_name" => "ISS-0983 Revoke Fixture",
                   "email" => "#{unique_name("iss0983-revoke-token")}@example.test"
                 },
                 prefix: schema_name,
                 login_directory: :skip
               )

      assert {:ok, %{token: token}} =
               Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
                 prefix: schema_name
               )

      drop_audit_entries!(schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.revoke_token(token.id, prefix: schema_name)

      reloaded = Repo.get!(ApiToken, token.id, prefix: schema_name)
      assert reloaded.revoked_at == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # actor_id: nil disposition -- Letflow.Tasks.assign_task/3.
  # ---------------------------------------------------------------------------------

  describe "actor_id: nil disposition -- Letflow.Tasks.assign_task/3" do
    test "writes a task.assign audit row with nil actor_id and a real before/after pair" do
      %{schema_name: schema_name} = provisioned_tenant()

      # A HUMAN_TASK node's "role" attribute is mandatory (graph validation
      # CHK-09, lib/letflow/definitions/graph.ex check_human_task_role/1), so
      # every engine-created task starts with a non-nil assignee_ref (the
      # role name) -- Tasks.assign_task/3's first-assignment branch
      # (%Task{assignee_ref: nil}) is unreachable straight off engine
      # dispatch. Force the row to the unassigned state assign_task/3's own
      # precondition requires, the same way audit_test.exs's AC6 tests
      # bypass the immutability trigger via raw SQL to exercise a state the
      # normal write path cannot produce -- assign_task/3's own code path
      # (including its :audit Multi step) still runs for real below.
      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: activated}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, _result} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_name("req195-disp-start")
                 },
                 prefix: schema_name
               )

      [task] = Repo.all(EngineTask, prefix: schema_name)
      assert task.assignee_ref == "approver"

      {1, _} =
        EngineTask
        |> where([t], t.id == ^task.id)
        |> Repo.update_all([set: [assignee_type: nil, assignee_ref: nil]], prefix: schema_name)

      assignee_user_id = Ecto.UUID.generate()

      assert {:ok, assigned_task} =
               Letflow.Tasks.assign_task(task.id, %{user_id: assignee_user_id},
                 prefix: schema_name
               )

      assert [entry] = audit_rows_for(schema_name, "task.assign")
      assert entry.actor_id == nil
      assert entry.resource_type == "task"
      assert entry.resource_id == task.id
      assert entry.before_state["assignee_ref"] == nil
      assert entry.after_state["assignee_ref"] == assignee_user_id
      assert entry.after_state["assignee_type"] == "USER"
      assert assigned_task.assignee_ref == assignee_user_id
    end
  end

  # ---------------------------------------------------------------------------------
  # actor_id: nil disposition -- Letflow.Engine.TaskActivation's task.create
  # capture site (OQ-1's `do_insert/4`).
  # ---------------------------------------------------------------------------------

  describe "actor_id: nil disposition -- task.create (engine dispatch)" do
    test "starting an instance that activates a HUMAN_TASK node writes a task.create audit row with nil actor_id and no before_state" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = draft_definition!(schema_name)

      assert {:ok, %{definition: activated}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, _result} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_name("req195-disp-taskcreate")
                 },
                 prefix: schema_name
               )

      [task] = Repo.all(EngineTask, prefix: schema_name)

      assert [entry] = audit_rows_for(schema_name, "task.create")
      assert entry.actor_id == nil
      assert entry.resource_type == "task"
      assert entry.resource_id == task.id
      assert entry.before_state == nil
      assert entry.after_state["id"] == task.id
      assert entry.after_state["status"] == "pending"
    end
  end
end
