defmodule Letflow.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Identity.provision_oidc_user/4` (REQ-018, arity bumped to /4 by
  REQ-063 — see below) and `Letflow.Identity.resolve_tenant_by_realm/1`,
  `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`, plus
  `Letflow.Identity.Tenant.create_changeset/3`/`admin_patch_changeset/2` (REQ-019). See
  `test/specs/REQ-018.md` and `test/specs/REQ-019.md` for the full test-case
  rationale, including which criteria are covered by inspection rather than a runtime
  assertion (REQ-018 AC4's moduledoc citation, and the `:external_identity_collision`
  defensive branch). See `test/specs/REQ-063.md` for why this file's fixtures changed.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## REQ-063 fixture change (read before touching a `provision_oidc_user/4` test here)

  REQ-063 (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `users`/`groups`/`tenant_role` out of the `public` schema into each tenant's own
  provisioned Postgres schema, and `Identity.provision_oidc_user/3` became `/4` with a
  required `opts :: [prefix: String.t()]` fourth argument (design §5b). Every test that
  exercises `provision_oidc_user/4` now needs a **real, provisioned tenant schema**
  (`Letflow.TenantProvisioning.provision_tenant_schema/1` +
  `replay_migrations/2`) to pass as that `prefix:`, not a bare `Ecto.UUID.generate()`
  tenant_id with an implicit `public`-schema `users` table — that table no longer
  exists post-cutover (this branch already ran the drop migration; see
  `mix ecto.migrate` output referenced in `test/specs/REQ-063.md`).

  `Ecto.Migrator` (which `replay_migrations/2` calls) "cannot run dynamically during
  test under `Ecto.Adapters.SQL.Sandbox`, as the sandbox has to share a single
  connection across processes" (`deps/ecto_sql/lib/ecto/migrator.ex`'s own moduledoc,
  flagged for TEST-DESIGNER at `lib/letflow/design/req022-tenant-schema-provisioning.md`
  §6's testing-environment caveat). This file follows the same
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1` cleanup
  pattern `test/letflow/tenant_provisioning_test.exs` and `test/letflow/event_store_test.exs`
  already establish for exactly this reason — `provisioned_tenant!/0` below mirrors
  those files' `provisioned_tenant/1` helper. Every `describe` block in this file that
  provisions a tenant therefore runs under real (non-rolled-back) Postgres state,
  cleaned up explicitly in `on_exit/1`.

  **This file is now `async: false` for its entire module** (ExUnit's `async` setting
  is module-wide, not per-test) — unlike its pre-REQ-063 version, which had
  `provision_oidc_user/3` tests running `async: true` against `public`. Every
  `provision_oidc_user/4` test now needs `:auto` mode, which is only safe when no other
  `async: true` module's connection could be disturbed; `async: false` combined with
  ExUnit's documented full-drain-before-sync-modules scheduling (see
  `tenant_provisioning_test.exs`'s moduledoc for the source-level citation this file
  relies on rather than re-deriving) makes that safe. The REQ-019 `Tenant`-only tests
  (which never touch `users`/`groups`/`tenant_role` — `Tenant` stays in `public`
  permanently per Decision 0006 D3) do not themselves need `:auto` mode, but must share
  this module's `async: false` setting regardless since it is module-wide; they still
  run inside DataCase's normal rolled-back sandbox connection (no `:auto` switch of
  their own), so nothing about their isolation changes.

  The concurrent-race test (acceptance criterion 3) needs `provisioned_tenant!/0`'s
  migration replay first (which needs `:auto` mode, same as every other test in this
  file), but then switches BACK to `:manual` mode + a fresh checkout for the race
  itself — restoring the original `Sandbox.allow/3`-based two-process-same-connection
  mechanism design §9 specifies, once the schema/migration prerequisite is already real
  committed Postgres state that survives the mode switch. See that test's own inline
  comment for the full reasoning and why a genuine `:auto`-mode two-independent-
  connections race was tried first and rejected (it surfaces a real, separate,
  pre-existing gap in `Identity.insert_or_fetch/4`'s conflict handling — filed as
  ISS-0047, not silently fixed or masked here — rather than reproducing this specific
  acceptance criterion's intended proof).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [where: 2, where: 3]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig

  # Every test builds its own unique identity triple — no shared hardcoded
  # tenant_id/realm/external_id, per test_developer_guide.md's "no test pollution"
  # principle and this project's established Ecto.UUID.generate()-per-test convention.
  defp unique_realm(prefix \\ "realm") do
    Letflow.TenantSlugFixture.unique_realm(prefix)
  end

  # REQ-019 fixture helpers.

  defp unique_slug(prefix \\ "tenant") do
    Letflow.TenantSlugFixture.unique_slug(prefix)
  end

  defp insert_tenant!(attrs, oidc_mode \\ :enabled) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, oidc_mode)
    |> Repo.insert!()
  end

  # REQ-370 (priv/repo/migrations/20260918173137_seed_default_tenant.exs) closed
  # REQ-019's own previously-flagged OQ-3 ("no priv/repo/seeds.exs and no real
  # default-tenant row exists anywhere") by adding a real, idempotent, permanent seed
  # migration that binds exactly one tenant to idp_realm_id "bpm-default" (partial
  # unique index enforces at most one). This helper's own doc comment used to say
  # "'seeded' means TEST-DESIGNER-constructed, not a real priv/repo/seeds.exs row" --
  # that is no longer true, and inserting a SECOND row under the same idp_realm_id
  # now violates tenants_idp_realm_id_partial_index unconditionally (the row from the
  # migration is real, committed Postgres state, visible even inside this test's own
  # sandboxed transaction under normal READ COMMITTED semantics). So this helper now
  # reuses the real migration-seeded row instead of inserting a duplicate -- both
  # call sites below (resolve_tenant_by_realm/1, resolve_realm_by_tenant/1) only need
  # SOME tenant genuinely bound to "bpm-default", not one this test exclusively owns.
  defp insert_default_tenant! do
    # Reads under the same mutex Letflow.Support.BpmDefaultRealmDisplacement's other
    # callers (auth_pipeline_test.exs/api_pipeline_integration_test.exs/
    # req077_promotion_pipeline_test.exs) hold while they temporarily displace this
    # binding for their own exclusive use -- without it, this read can land in the
    # window between one of those tests' Repo.delete!/1 and its on_exit-deferred
    # restore and raise Ecto.NoResultsError (reproduced live while fixing this; see
    # that module's own moduledoc "Mutual exclusion" section for the full story).
    Letflow.Support.BpmDefaultRealmDisplacement.with_lock(fn ->
      Repo.get_by!(Tenant, idp_realm_id: "bpm-default")
    end)
  end

  defp identity_context(overrides \\ %{}) do
    struct(
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: unique_realm(),
        roles: [],
        email: "someone@example.com",
        preferred_username: "someone-#{System.unique_integer([:positive])}",
        display_name: "Someone Example"
      },
      overrides
    )
  end

  defp jit_config(overrides \\ %{}) do
    struct(
      %JitProvisioningConfig{
        realm: "unused-by-provision_oidc_user",
        enabled: true,
        default_status: :active,
        default_roles: []
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------------
  # REQ-063 tenant-schema provisioning helper — adopts the shared `Letflow.TenantFixture`
  # (ISS-0109/GH#358, ISS-0115/GH#369) in place of this file's own hand-rolled
  # insert_tenant! + :auto-mode + on_exit/1 DROP SCHEMA copy. Behaviour-preserving by
  # construction (same Tenant.create_changeset/3 call, same provision_tenant_schema/1 +
  # replay_migrations/1 sequence, same :auto sandbox mode, same teardown), but adds a
  # completeness assertion post-replay and emits a greppable `LETFLOW_TENANT_FIXTURE`
  # marker automatically on teardown/capture failure. This module is the one ISS-0115
  # caught a single, unreproduced 42P01 undefined_table failure in
  # (identity_test.exs:205) — adopting the fixture here is that issue's own prescribed
  # step, so the *next* occurrence carries a full `capture_schema_state/1` report
  # instead of a bare Postgrex error. Still takes the same `oidc_mode` positional arg
  # every call site here already passes; still returns `%{tenant: ..., schema_name:
  # ...}` so no call site below needs to change.
  # ---------------------------------------------------------------------------------
  defp provisioned_tenant!(oidc_mode \\ :disabled) do
    %{tenant: tenant, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req063-identity",
        display_name: "REQ-063 Test Tenant",
        oidc_mode: oidc_mode
      )

    %{tenant: tenant, schema_name: schema_name}
  end

  describe "provision_oidc_user/4 — idempotency (acceptance criterion 1)" do
    test "calling provision_oidc_user/4 twice with the same identity returns the same user.id, created: true then false" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert id1 == id2
    end

    test "three consecutive calls all resolve to the same user.id" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id3}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert id1 == id2
      assert id2 == id3
    end

    test "different (tenant_id, realm, external_id) triples in different tenant schemas create distinct rows" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()
      config = jit_config()

      ctx_a = identity_context()
      ctx_b = identity_context()

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a.id, config, prefix: schema_a)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, tenant_b.id, config, prefix: schema_b)

      assert id_a != id_b
    end
  end

  describe "provision_oidc_user/4 — fixed literals (acceptance criterion 2)" do
    test "the inserted row has the fixed OIDC-only password_hash and auth_source: :oidc" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()

      assert {:ok, %{user: %User{id: id}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      # Re-select from Postgres directly, rather than trusting the in-memory reply —
      # matches process_instance_test.exs's "every successful transition is persisted
      # to Postgres" persistence-test convention. Must pass prefix: here too, per
      # REQ-063 — Repo.get/3 with no prefix would look in public, which no longer has
      # this row.
      persisted = Repo.get(User, id, prefix: schema_name)

      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end

    test "password_hash and auth_source are not caller-overridable" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      # IdentityContext has no password_hash/auth_source field at all, so this
      # exercises that the changeset always sets fixed values regardless of what's
      # in the context — there is no input surface here that COULD supply an
      # override, which is itself the property being pinned.
      ctx = identity_context(%{email: "override-attempt@example.com"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end
  end

  describe "provision_oidc_user/4 — concurrent-insert race (acceptance criterion 3)" do
    test "a genuine concurrent race between two tasks resolves to exactly one created row, both callers succeed" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      # REQ-063 update: provisioned_tenant!/0 above needed Sandbox :auto mode for its
      # migration replay (Ecto.Migrator's own documented single-shared-connection
      # incompatibility, see this file's moduledoc) -- but the ORIGINAL pre-REQ-063
      # version of this test relied specifically on :manual mode + Sandbox.allow/3,
      # which routes both spawned Tasks through the SAME underlying sandboxed
      # connection/transaction (nested savepoints), matching design §9's exact
      # guidance ("Ecto.Adapters.SQL.Sandbox `:manual` mode with `Sandbox.allow/3`").
      # Switching back to :manual mode and taking a fresh checkout here, AFTER the
      # schema/migration work above has already completed under :auto, restores that
      # exact intended mechanism for the race itself -- the tenant schema created
      # above survives the mode switch (it's real, committed Postgres state, not
      # sandboxed), so this checkout's rolled-back transaction only ever touches the
      # User row this test itself inserts.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, {:shared, self()})

      parent = self()

      run_task = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        # Barrier: make both tasks announce readiness, then wait for the parent's
        # go-ahead, so both reach Identity.provision_oidc_user/4's own select-first
        # step at effectively the same time and genuinely race into the INSERT ...
        # ON CONFLICT path together, rather than being accidentally serialized by
        # Task.async/1's own scheduling.
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)
      end

      task1 = Task.async(run_task)
      task2 = Task.async(run_task)

      # Wait for both tasks to reach the barrier before releasing either — this is
      # what forces both to attempt the insert at effectively the same time instead
      # of being serialized by whichever task's scheduler slice runs first.
      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 in [task1.pid, task2.pid]
      assert pid2 in [task1.pid, task2.pid]
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %{user: %User{id: id1}, created: created1}} = result1
      assert {:ok, %{user: %User{id: id2}, created: created2}} = result2

      # Both tasks resolve to the same row.
      assert id1 == id2

      # Exactly one of the two calls actually performed the insert.
      assert [created1, created2] |> Enum.count(& &1) == 1

      # No unhandled exception escaped either task (Task.await/2 above would itself
      # have raised if either task's process crashed) — asserting this explicitly as
      # a documented expectation, not just relying on Task.await/2's own behavior.
      assert is_boolean(created1)
      assert is_boolean(created2)

      # Exactly one row exists in the database for this identity afterward.
      rows =
        User
        |> where(
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all(prefix: schema_name)

      assert length(rows) == 1

      # Switch back to :auto mode BEFORE this test ends -- provisioned_tenant!/0's
      # on_exit/1 cleanup (DROP SCHEMA / DELETE FROM tenants) needs a real, checked-in
      # connection to run against; leaving this test's manual-mode checkout open past
      # the test body would orphan it once this test process exits, and on_exit/1's
      # own Repo calls would then fail trying to check out a connection whose owner
      # process is already gone (confirmed empirically while drafting this test).
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    end
  end

  describe "provision_oidc_user/4 — ISS-0047 regression: username-index race resolves cleanly" do
    test "two genuinely independent connections racing an identical (realm, external_id, username) identity always resolve to {:ok, same id}, looped" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      config = jit_config()

      # :auto mode (already set by provisioned_tenant!/0 above) gives each spawned
      # Task its own genuinely independent, automatically-checked-out connection --
      # unlike the acceptance-criterion-3 race test above, which deliberately
      # switches to :manual mode + Sandbox.allow/3 so both Tasks share ONE
      # connection/transaction (see that test's own inline comment). A single
      # shared connection serializes the two INSERTs and never lets Postgres's
      # own conflict-check ordering across the two DIFFERENT unique indexes
      # (`(external_realm, external_id)` and `username`) vary -- which is exactly
      # the gap ISS-0047 depends on. Two real, independent connections are
      # required to exercise it at all -- see
      # lib/letflow/design/iss-0047-username-race-conflict-target.md §5.
      #
      # ISSUE-FIXER's own repro only reproduced the pre-fix bug 4/6 runs
      # (nondeterministic, depends on which unique index Postgres's constraint
      # checker happens to evaluate first for the losing insert) -- looping 10
      # independent race attempts, each with a fresh identity so no attempt's
      # result can be masked by a prior attempt's already-committed row, gives
      # strong confidence this is a reliable proof rather than a flaky one-shot.
      for attempt <- 1..10 do
        ctx = identity_context()
        parent = self()

        run_task = fn ->
          # Barrier: both tasks announce readiness, then wait for the parent's
          # go-ahead, so both reach provision_oidc_user/4's own select-first step
          # at effectively the same time and genuinely race into the INSERT
          # together, rather than being serialized by Task.async/1's own
          # scheduling. Same pattern as the acceptance-criterion-3 race test
          # above (lines 284-301), reused per design §5's guidance.
          send(parent, {:ready, attempt, self()})

          receive do
            :go -> :ok
          after
            5000 -> flunk("attempt #{attempt}: barrier release never arrived")
          end

          Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)
        end

        task1 = Task.async(run_task)
        task2 = Task.async(run_task)

        assert_receive {:ready, ^attempt, pid1}, 5000
        assert_receive {:ready, ^attempt, pid2}, 5000
        assert pid1 != pid2

        send(pid1, :go)
        send(pid2, :go)

        result1 = Task.await(task1, 5000)
        result2 = Task.await(task2, 5000)

        # The ISS-0047 bug surfaced as {:error, %Ecto.Changeset{}} for the losing
        # racer here (a username-uniqueness violation treated as permanent
        # instead of being recognized as this call's own race opponent) --
        # asserting {:ok, ...} for BOTH results is this regression test's core
        # proof.
        assert {:ok, %{user: %User{id: id1}, created: created1}} = result1
        assert {:ok, %{user: %User{id: id2}, created: created2}} = result2

        assert id1 == id2,
               "attempt #{attempt}: both racers must resolve to the same user id, got #{inspect(result1)} / #{inspect(result2)}"

        assert [created1, created2] |> Enum.count(& &1) == 1,
               "attempt #{attempt}: exactly one of the two calls should have inserted"

        rows =
          User
          |> where(external_realm: ^ctx.realm, external_id: ^ctx.external_user_id)
          |> Repo.all(prefix: schema_name)

        assert length(rows) == 1, "attempt #{attempt}: exactly one row should exist afterward"
      end
    end
  end

  describe "provision_oidc_user/4 — jit_config.enabled == false (design-flagged, not a numbered AC)" do
    test "jit_config.enabled == false returns {:error, :jit_disabled} without writing to the database" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config(%{enabled: false})

      assert {:error, :jit_disabled} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      rows =
        User
        |> where(
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all(prefix: schema_name)

      assert rows == []
    end
  end

  describe "provision_oidc_user/4 — username collision, same vs different tenant schemas (REQ-063)" do
    test "same username in the SAME tenant schema: second JIT provisioning call fails uniqueness" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant.id, config, prefix: schema_name)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.provision_oidc_user(ctx_b, tenant.id, config, prefix: schema_name)

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "same username in TWO DIFFERENT tenant schemas both succeed (per-tenant-unique — Decision 0006 §3.1)" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a.id, config, prefix: schema_a)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, tenant_b.id, config, prefix: schema_b)

      assert id_a != id_b

      # Both rows genuinely persisted, one per tenant schema, same username value.
      assert %User{username: ^shared_username} = Repo.get(User, id_a, prefix: schema_a)
      assert %User{username: ^shared_username} = Repo.get(User, id_b, prefix: schema_b)
    end
  end

  describe "provision_oidc_user/4 — display_name fallback (design §4.3, design-flagged)" do
    test "display_name nil in the identity context falls back to preferred_username on the persisted row" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context(%{display_name: nil, preferred_username: "fallback-username"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.display_name == "fallback-username"
    end

    test "display_name present in the identity context is stored verbatim" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      ctx =
        identity_context(%{
          display_name: "Explicit Display Name",
          preferred_username: "some-other-username"
        })

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.display_name == "Explicit Display Name"
    end
  end

  describe "resolve_tenant_by_realm/1 and resolve_realm_by_tenant/1 (REQ-019 acceptance criterion 1)" do
    test "resolve_tenant_by_realm/1 resolves the seeded default tenant (bpm-default) by its idp_realm_id" do
      tenant = insert_default_tenant!()

      assert {:ok, %Tenant{id: id}} = Identity.resolve_tenant_by_realm("bpm-default")
      assert id == tenant.id
    end

    test "resolve_realm_by_tenant/1 resolves the seeded default tenant's (bpm-default) idp_realm_id by its tenant id" do
      tenant = insert_default_tenant!()

      assert {:ok, "bpm-default"} = Identity.resolve_realm_by_tenant(tenant.id)
    end

    test "resolve_tenant_by_realm/1 returns {:error, :not_found} for an unknown realm string" do
      assert {:error, :not_found} = Identity.resolve_tenant_by_realm(unique_realm("nonexistent"))
    end

    test "resolve_realm_by_tenant/1 returns {:error, :not_found} for an unknown tenant_id" do
      assert {:error, :not_found} = Identity.resolve_realm_by_tenant(Ecto.UUID.generate())
    end

    test "resolve_realm_by_tenant/1 returns {:ok, nil} for a tenant that exists but has no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Yet", idp_realm_id: nil},
          :disabled
        )

      assert {:ok, nil} = Identity.resolve_realm_by_tenant(tenant.id)
    end
  end

  describe "Tenant.create_changeset/3 — one-to-one collision rejection (REQ-019 acceptance criterion 2)" do
    test "creating a second tenant with an already-bound idp_realm_id is rejected, not silently overwritten" do
      shared_realm = unique_realm("collide")

      insert_tenant!(%{slug: unique_slug(), display_name: "Tenant A", idp_realm_id: shared_realm})

      result =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "Tenant B", idp_realm_id: shared_realm},
          :enabled
        )
        |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{idp_realm_id: ["has already been taken"]} = errors_on(changeset)

      rows = Tenant |> where(idp_realm_id: ^shared_realm) |> Repo.all()
      assert length(rows) == 1
    end

    test "two tenants with distinct idp_realm_id values both persist successfully" do
      tenant_a =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant A",
          idp_realm_id: unique_realm()
        })

      tenant_b =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant B",
          idp_realm_id: unique_realm()
        })

      assert tenant_a.id != tenant_b.id
      assert tenant_a.idp_realm_id != tenant_b.idp_realm_id
    end
  end

  describe "Tenant.admin_patch_changeset/2 — idp_realm_id immutability (REQ-019 acceptance criterion 3)" do
    test "admin_patch_changeset/2 does not cast idp_realm_id even when present in attrs" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: unique_realm("original")
        })

      changeset =
        Tenant.admin_patch_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert Ecto.Changeset.get_change(changeset, :idp_realm_id) == nil
      assert Ecto.Changeset.get_change(changeset, :display_name) == "New Name"
      assert changeset.valid?
    end

    test "persisting admin_patch_changeset/2 with an attempted idp_realm_id change leaves the original idp_realm_id unchanged in the database" do
      original_realm = unique_realm("original")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: original_realm
        })

      changeset =
        Tenant.admin_patch_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert {:ok, _updated} = Repo.update(changeset)

      persisted = Repo.get(Tenant, tenant.id)
      assert persisted.idp_realm_id == original_realm
      assert persisted.display_name == "New Name"
    end
  end

  describe "verify_realm_ownership/2 — realm-ownership guard, every branch (REQ-019 acceptance criterion 4)" do
    test "verify_realm_ownership/2 returns :ok when external_realm matches the tenant's bound idp_realm_id" do
      realm = unique_realm()

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Matching Tenant",
          idp_realm_id: realm
        })

      assert :ok = Identity.verify_realm_ownership(tenant.id, realm)
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch} when external_realm does not match the tenant's bound realm" do
      bound_realm = unique_realm("bound")
      other_realm = unique_realm("other")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Bound Tenant",
          idp_realm_id: bound_realm
        })

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, other_realm)
    end

    test "verify_realm_ownership/2 returns {:error, :not_found} for a tenant_id that matches no row" do
      assert {:error, :not_found} =
               Identity.verify_realm_ownership(Ecto.UUID.generate(), unique_realm())
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch}, not :ok and not a crash, for a tenant with no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Bound", idp_realm_id: nil},
          :disabled
        )

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, unique_realm("some-external-realm"))
    end
  end

  describe "Tenant.create_changeset/3 — default-tenant pinning (design §3.2/§4)" do
    test "create_changeset/3 rejects slug bpm-default paired with a different idp_realm_id" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: unique_realm()},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 accepts slug bpm-default paired with idp_realm_id bpm-default" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: "bpm-default"},
          :enabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 rejects slug bpm-default with idp_realm_id omitted entirely" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "Tenant.create_changeset/3 — oidc_mode-conditional idp_realm_id requirement (design §3.2)" do
    test "create_changeset/3 requires idp_realm_id for a non-default tenant when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 allows a non-default tenant with no idp_realm_id when oidc_mode is :disabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :disabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 accepts a non-default tenant with idp_realm_id present when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{
            slug: unique_slug(),
            display_name: "Non-default Tenant",
            idp_realm_id: unique_realm()
          },
          :enabled
        )

      assert changeset.valid?
    end
  end

  # ── REQ-124: Identity.safe_get_tenant_by_slug/2 exception-swallowing ──────
  #
  # Shared by the two unauthenticated tenant-config bootstrap routes
  # (Letflow.Routers.TenantConfig, Letflow.Routers.MobileTenantConfig) -- see
  # lib/letflow/identity.ex's own @doc for safe_get_tenant_by_slug/2. This
  # describe block is REQ-124's own contribution (its handoff's acceptance
  # criterion 5), independent of REQ-018/REQ-019 above.

  describe "safe_get_tenant_by_slug/2 — exception-swallowing (REQ-124 acceptance criterion 5)" do
    test "a genuine hit resolves exactly like get_tenant_by_slug/1" do
      tenant =
        insert_tenant!(
          %{
            slug: unique_slug("req124-safe-hit"),
            display_name: "REQ-124 Safe Hit",
            idp_realm_id: unique_realm("req124-safe-hit")
          },
          :disabled
        )

      assert {:ok, ^tenant} = Identity.safe_get_tenant_by_slug(tenant.slug, "req124-test")
      assert {:ok, ^tenant} = Identity.get_tenant_by_slug(tenant.slug)
    end

    test "a genuine miss returns {:error, :not_found}, same as get_tenant_by_slug/1" do
      missing_slug = unique_slug("req124-missing")

      assert {:error, :not_found} = Identity.safe_get_tenant_by_slug(missing_slug, "req124-test")
      assert {:error, :not_found} = Identity.get_tenant_by_slug(missing_slug)
    end

    test "a raise inside get_tenant_by_slug/1 is swallowed into {:error, :lookup_failed}, never propagates" do
      # Passing a non-binary `slug` makes Ecto's own query planner raise
      # Ecto.Query.CastError at query-execution time -- confirmed against this
      # project's vendored Ecto dependency (deps/ecto/lib/ecto/query/planner.ex,
      # `"value \`#{inspect(v)}\` cannot be dumped to type #{...}"` -> `raise
      # Ecto.Query.CastError`). This is a REAL exception raised from inside
      # get_tenant_by_slug/1's own Repo.get_by/2 call, not a simulated or
      # mocked one. If safe_get_tenant_by_slug/2's `rescue` clause were ever
      # removed, this test would fail with an unhandled Ecto.Query.CastError
      # instead of matching {:error, :lookup_failed} -- see the companion
      # "unwrapped" test below, which pins that this input genuinely raises
      # when NOT going through the wrapper.
      assert {:error, :lookup_failed} =
               Identity.safe_get_tenant_by_slug(12_345, "req124-raise-test")
    end

    test "get_tenant_by_slug/1 itself (unwrapped) DOES raise for the same bad input -- proves the rescue in safe_get_tenant_by_slug/2 is load-bearing, not a no-op" do
      assert_raise Ecto.Query.CastError, fn ->
        Identity.get_tenant_by_slug(12_345)
      end
    end

    test "the warning log names the context_label and the slug, and never the exception itself (INV-4)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :lookup_failed} =
                   Identity.safe_get_tenant_by_slug(98_765, "req124-log-test")
        end)

      assert log =~ "req124-log-test"
      assert log =~ "98765"
      # INV-4: never logs the exception itself -- its message would mention
      # "QueryError" / "cannot be dumped" / the underlying query/connection
      # details, none of which this warning line may carry.
      refute log =~ "QueryError"
      refute log =~ "cannot be dumped"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-076 — API tokens (Identity.create_token/3, list_tokens/1,
  # revoke_token/2, verify_api_token/2) and onboarding
  # (Identity.create_onboarding/1, get_onboarding/1,
  # get_onboarding_by_hostname/1). See test/specs/REQ-076.md for the full
  # AC-to-test mapping this section implements.
  # ══════════════════════════════════════════════════════════════════════

  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.OnboardingRecord

  defp req076_tenant!(slug_prefix) do
    Letflow.TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix, oidc_mode: :disabled)
  end

  defp insert_identity_user!(schema_name, username_prefix \\ "token-user") do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "#{username_prefix}-#{System.unique_integer([:positive, :monotonic])}",
      display_name: "Token Test User",
      email: "#{username_prefix}-#{System.unique_integer([:positive])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Ecto.UUID.generate/0-derived, NOT System.unique_integer/1 -- the latter is
  # only unique within a single BEAM VM run, and this module leaves real,
  # non-rolled-back committed rows behind (Sandbox :auto mode, per
  # TenantFixture.provisioned_tenant!/1's own moduledoc) that a later `mix test`
  # invocation's freshly-restarted counter could collide with, exactly the
  # ISS-0059 failure mode test/support/tenant_slug.ex's own moduledoc documents.
  defp unique_hostname(prefix \\ "onboard") do
    "#{prefix}-#{Ecto.UUID.generate()}.example.com"
  end

  # onboarding_registry.tenant_id has a real FK to tenants -- req076_tenant!/1's
  # own on_exit/1 (registered inside TenantFixture.provisioned_tenant!/1) deletes
  # the tenants row at teardown, which fails with a foreign_key_violation unless
  # any onboarding_registry row this test itself created is deleted first.
  # Registered AFTER req076_tenant!/1's own on_exit/1, so LIFO ordering runs this
  # one FIRST, before that teardown's own DELETE FROM tenants.
  defp cleanup_onboarding_record!(tenant_id) do
    on_exit(fn ->
      import Ecto.Query, only: [from: 2]
      Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    end)
  end

  describe "create_token/3 (REQ-076 AC1/AC2/AC3)" do
    test "issues a token whose plaintext matches the lf_tok_ shape, roles snapshotted onto the row" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-create")
      user = insert_identity_user!(schema_name)

      assert {:ok, %{token: %ApiToken{} = token, plaintext: plaintext}} =
               Identity.create_token(
                 user.id,
                 %{roles: ["TENANT_ADMIN", "TASK_WORKER"], expires_at: nil},
                 prefix: schema_name
               )

      assert plaintext =~ ~r/^lf_tok_[0-9a-f]{64}$/
      assert token.user_id == user.id
      assert token.roles == ["TENANT_ADMIN", "TASK_WORKER"]
      assert token.name == "token-" <> String.slice(token.token_hash, 0, 8)
      assert token.revoked_at == nil
      assert token.last_used_at == nil
    end

    test "REQ-447 PR 2: a PLATFORM_ADMIN token is refused ({:error, :invalid_role_set}) in an ordinary tenant" do
      %{schema_name: schema_name} = req076_tenant!("req447-token-padmin")
      user = insert_identity_user!(schema_name)

      assert {:error, :invalid_role_set} =
               Identity.create_token(
                 user.id,
                 %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
                 prefix: schema_name
               )

      assert {:ok, []} = Identity.list_tokens(prefix: schema_name)
    end

    test "returns {:error, :user_not_found} for a user_id that does not exist in this schema" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-nouser")

      assert {:error, :user_not_found} =
               Identity.create_token(
                 Ecto.UUID.generate(),
                 %{roles: ["TENANT_ADMIN"], expires_at: nil},
                 prefix: schema_name
               )
    end

    test "returns {:error, :invalid_role_set} for an empty roles list" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-emptyroles")
      user = insert_identity_user!(schema_name)

      assert {:error, :invalid_role_set} =
               Identity.create_token(user.id, %{roles: [], expires_at: nil}, prefix: schema_name)
    end

    test "returns {:error, :invalid_role_set} for a role string outside the five recognized roles -- not silently dropped like roles_from_strings/1 would" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-badrole")
      user = insert_identity_user!(schema_name)

      assert {:error, :invalid_role_set} =
               Identity.create_token(
                 user.id,
                 %{roles: ["NOT_A_REAL_ROLE"], expires_at: nil},
                 prefix: schema_name
               )
    end

    test "returns {:error, :expires_at_in_past} for an expires_at strictly before now" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-pastexpiry")
      user = insert_identity_user!(schema_name)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:error, :expires_at_in_past} =
               Identity.create_token(
                 user.id,
                 %{roles: ["TENANT_ADMIN"], expires_at: past},
                 prefix: schema_name
               )
    end

    test "the persisted row's own columns never equal the plaintext, checked across every field (AC2)" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-ac2")
      user = insert_identity_user!(schema_name)

      assert {:ok, %{token: %ApiToken{id: id}, plaintext: plaintext}} =
               Identity.create_token(
                 user.id,
                 %{roles: ["TENANT_ADMIN"], expires_at: nil},
                 prefix: schema_name
               )

      # Re-select from Postgres directly, never trust the in-memory reply -- matches
      # this project's established persistence-test convention
      # (identity_test.exs's provision_oidc_user/4 tests, role_registry_test.exs).
      persisted = Repo.get!(ApiToken, id, prefix: schema_name)

      persisted
      |> Map.from_struct()
      |> Enum.each(fn {field, value} ->
        refute value == plaintext,
               "field #{inspect(field)} on the persisted row equals the plaintext -- AC2 violation"
      end)

      assert persisted.token_hash != plaintext

      assert persisted.token_hash ==
               :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
    end
  end

  describe "list_tokens/1 and revoke_token/2 (REQ-076)" do
    test "list_tokens/1 returns {:ok, []} for an empty tenant schema" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-listempty")

      assert {:ok, []} = Identity.list_tokens(prefix: schema_name)
    end

    test "list_tokens/1 lists every issued token in the schema, none dropped" do
      # Deliberately not asserting exact inserted_at-descending order here: two
      # inserts issued back-to-back can land in the same `:utc_datetime` second
      # (Ecto's timestamps() default granularity), which would make an
      # order-tie-dependent assertion flaky rather than a real proof of
      # anything -- test_developer_guide.md's "no wall-clock time dependency"
      # rule extends to not depending on sub-second insert timing either. The
      # ORDER BY itself is a one-line, low-risk clause (Identity.list_tokens/1's
      # own @doc); set-membership is what AC-level behavior actually depends on.
      %{schema_name: schema_name} = req076_tenant!("req076-token-listorder")
      user = insert_identity_user!(schema_name)

      {:ok, %{token: first}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: schema_name
        )

      {:ok, %{token: second}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: schema_name
        )

      # GH 2552: each item is %{token: token, owner_active: boolean}.
      assert {:ok, items} = Identity.list_tokens(prefix: schema_name)
      assert Enum.map(items, & &1.token.id) |> Enum.sort() == Enum.sort([first.id, second.id])
      assert Enum.all?(items, &(&1.owner_active == true))
    end

    test "revoke_token/2 sets revoked_at and is idempotent -- re-revoking returns the same revoked_at, not a later one" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-revoke")
      user = insert_identity_user!(schema_name)

      {:ok, %{token: token}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: schema_name
        )

      assert {:ok, %ApiToken{revoked_at: first_revoked_at}} =
               Identity.revoke_token(token.id, prefix: schema_name)

      refute is_nil(first_revoked_at)

      assert {:ok, %ApiToken{revoked_at: second_revoked_at}} =
               Identity.revoke_token(token.id, prefix: schema_name)

      assert second_revoked_at == first_revoked_at
    end

    test "revoke_token/2 returns {:error, :not_found} for a nonexistent token id" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-revokemissing")

      assert {:error, :not_found} =
               Identity.revoke_token(Ecto.UUID.generate(), prefix: schema_name)
    end
  end

  describe "verify_api_token/2 (REQ-076 AC4/AC5)" do
    test "AC4 primitive: a revoked token is rejected on the very next verification call, no sleep" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-ac4primitive")
      user = insert_identity_user!(schema_name)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: schema_name
        )

      assert {:ok, %{user_id: user_id, roles: ["TASK_WORKER"]}} =
               Identity.verify_api_token(plaintext, prefix: schema_name)

      assert user_id == user.id

      {:ok, _revoked} = Identity.revoke_token(token.id, prefix: schema_name)

      assert {:error, :revoked} = Identity.verify_api_token(plaintext, prefix: schema_name)
    end

    test "returns {:error, :invalid} for a plaintext that never matches any hash" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-invalidverify")

      assert {:error, :invalid} =
               Identity.verify_api_token("lf_tok_" <> String.duplicate("0", 64),
                 prefix: schema_name
               )
    end

    test "returns {:error, :expired} for a token whose expires_at has already passed" do
      %{schema_name: schema_name} = req076_tenant!("req076-token-expired")
      user = insert_identity_user!(schema_name)
      future = DateTime.add(DateTime.utc_now(), 1, :second) |> DateTime.truncate(:second)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: future},
          prefix: schema_name
        )

      # Force the already-persisted row's expires_at into the past directly --
      # avoids a real sleep/wall-clock dependency (test_developer_guide.md's
      # "no wall-clock time" rule) while still exercising the genuine expiry
      # comparison inside verify_api_token/2 against a real persisted row.
      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

      token
      |> Ecto.Changeset.change(%{expires_at: past})
      |> Repo.update!(prefix: schema_name)

      assert {:error, :expired} = Identity.verify_api_token(plaintext, prefix: schema_name)
    end

    test "AC5/INV-1: a token minted under tenant A's schema cannot verify against tenant B's schema" do
      %{schema_name: schema_a} = req076_tenant!("req076-token-iso-a")
      %{schema_name: schema_b} = req076_tenant!("req076-token-iso-b")
      user_a = insert_identity_user!(schema_a)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user_a.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: schema_a
        )

      assert {:ok, _verified} = Identity.verify_api_token(plaintext, prefix: schema_a)

      # The row genuinely does not exist under tenant B's schema (per-schema table
      # isolation) -- {:error, :invalid}, not a status-based rejection.
      assert {:error, :invalid} = Identity.verify_api_token(plaintext, prefix: schema_b)
    end
  end

  # GH-2557 — design lib/letflow/design/gh2557-inactive-user-api-token.md §2/§3,
  # spec test/specs/GH-2557.md.

  defp gh2557_deactivate!(schema_name, user) do
    user
    |> Ecto.Changeset.change(%{status: :inactive})
    |> Repo.update!(prefix: schema_name)
  end

  # Runs `fun` and returns `{result, queries}` where `queries` are the SQL
  # strings of every `[:letflow, :repo, :query]` event emitted by THIS test
  # process only (pid captured at attach), so unrelated concurrent queries
  # never inflate the count.
  defp gh2557_capture_queries(fun) do
    test_pid = self()
    handler_id = {__MODULE__, :gh2557_queries, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:gh2557_query, handler_id, metadata.query})
        end,
        nil
      )

    try do
      result = fun.()
      {result, gh2557_drain(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp gh2557_drain(handler_id, acc) do
    receive do
      {:gh2557_query, ^handler_id, sql} -> gh2557_drain(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "verify_api_token/2 — inactive owner (GH-2557 AC2)" do
    test "inactive owner returns {:error, :revoked} and leaves last_used_at unchanged" do
      %{schema_name: schema_name} = req076_tenant!("gh2557-verify-inactive")
      user = insert_identity_user!(schema_name)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: schema_name
        )

      gh2557_deactivate!(schema_name, user)

      assert {:error, :revoked} = Identity.verify_api_token(plaintext, prefix: schema_name)
      assert Repo.get!(ApiToken, token.id, prefix: schema_name).last_used_at == nil
    end

    test "inactive owner with an expired token returns {:error, :revoked}" do
      %{schema_name: schema_name} = req076_tenant!("gh2557-verify-inactive-exp")
      user = insert_identity_user!(schema_name)
      future = DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:second)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: future},
          prefix: schema_name
        )

      past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)

      token
      |> Ecto.Changeset.change(%{expires_at: past})
      |> Repo.update!(prefix: schema_name)

      # Premise: with the owner still active, this token is :expired.
      assert {:error, :expired} = Identity.verify_api_token(plaintext, prefix: schema_name)

      gh2557_deactivate!(schema_name, user)

      assert {:error, :revoked} = Identity.verify_api_token(plaintext, prefix: schema_name)
    end

    test "inactive owner and revoked token each issue exactly 1 query and no UPDATE on api_tokens" do
      %{schema_name: schema_name} = req076_tenant!("gh2557-verify-querycount")
      inactive_owner = insert_identity_user!(schema_name)
      revoked_owner = insert_identity_user!(schema_name)

      {:ok, %{plaintext: inactive_plaintext}} =
        Identity.create_token(inactive_owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: schema_name
        )

      {:ok, %{token: revoked_token, plaintext: revoked_plaintext}} =
        Identity.create_token(revoked_owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: schema_name
        )

      gh2557_deactivate!(schema_name, inactive_owner)
      {:ok, _} = Identity.revoke_token(revoked_token.id, prefix: schema_name)

      {inactive_result, inactive_queries} =
        gh2557_capture_queries(fn ->
          Identity.verify_api_token(inactive_plaintext, prefix: schema_name)
        end)

      {revoked_result, revoked_queries} =
        gh2557_capture_queries(fn ->
          Identity.verify_api_token(revoked_plaintext, prefix: schema_name)
        end)

      assert inactive_result == {:error, :revoked}
      assert revoked_result == {:error, :revoked}
      assert length(inactive_queries) == 1, inspect(inactive_queries)
      assert length(revoked_queries) == 1, inspect(revoked_queries)

      for sql <- inactive_queries ++ revoked_queries do
        refute sql =~ ~r/^\s*UPDATE\b.*api_tokens/is, sql
      end
    end
  end

  describe "active_user?/1 and active_user_condition/1 (GH-2557 AC5 contract)" do
    test "active_user?/1 truth table" do
      assert Identity.active_user?(%User{status: :active})
      refute Identity.active_user?(%User{status: :inactive})
      refute Identity.active_user?(%User{status: nil})

      assert_raise FunctionClauseError, fn -> Identity.active_user?(%{status: :active}) end
      assert_raise FunctionClauseError, fn -> Identity.active_user?(nil) end
    end

    test "active_user_condition/1 filters an inactive member out of a GroupMember-User join" do
      import Ecto.Query, only: [from: 2]

      alias Letflow.Identity.GroupMember

      %{schema_name: schema_name} = req076_tenant!("gh2557-active-condition")
      active_member = insert_identity_user!(schema_name, "gh2557-active")
      inactive_member = insert_identity_user!(schema_name, "gh2557-inactive")

      {:ok, group} =
        Identity.create_group(%{"name" => "gh2557-group-#{Ecto.UUID.generate()}"},
          prefix: schema_name
        )

      {:ok, _} = Identity.add_group_member(group.id, active_member.id, prefix: schema_name)
      {:ok, _} = Identity.add_group_member(group.id, inactive_member.id, prefix: schema_name)
      gh2557_deactivate!(schema_name, inactive_member)

      base =
        from(gm in GroupMember,
          join: u in User,
          as: :member,
          on: u.id == gm.user_id,
          where: gm.group_id == ^group.id,
          select: u.id
        )

      # Premise: without the condition, both members are joined.
      assert Enum.sort(Repo.all(base, prefix: schema_name)) ==
               Enum.sort([active_member.id, inactive_member.id])

      filtered = Ecto.Query.where(base, ^Identity.active_user_condition(:member))
      assert Repo.all(filtered, prefix: schema_name) == [active_member.id]
    end
  end

  describe "Onboarding: create_onboarding/1, get_onboarding/1, get_onboarding_by_hostname/1 (REQ-076)" do
    test "create_onboarding/1 inserts a row and get_onboarding/1 finds it by id" do
      %{tenant_id: tenant_id, tenant: tenant} = req076_tenant!("req076-onboard-create")
      cleanup_onboarding_record!(tenant_id)
      hostname = unique_hostname()

      assert {:ok, %OnboardingRecord{} = record} =
               Identity.create_onboarding(%{
                 tenant_id: tenant_id,
                 slug: tenant.slug,
                 hostname: hostname
               })

      assert record.tenant_id == tenant_id
      assert record.hostname == hostname

      assert {:ok, ^record} = Identity.get_onboarding(record.id)
    end

    test "create_onboarding/1 returns {:error, :duplicate_hostname} on a hostname collision" do
      %{tenant_id: tenant_id_a, tenant: tenant_a} = req076_tenant!("req076-onboard-dup-a")
      %{tenant_id: tenant_id_b, tenant: tenant_b} = req076_tenant!("req076-onboard-dup-b")
      cleanup_onboarding_record!(tenant_id_a)
      hostname = unique_hostname("dup")

      assert {:ok, _first} =
               Identity.create_onboarding(%{
                 tenant_id: tenant_id_a,
                 slug: tenant_a.slug,
                 hostname: hostname
               })

      assert {:error, :duplicate_hostname} =
               Identity.create_onboarding(%{
                 tenant_id: tenant_id_b,
                 slug: tenant_b.slug,
                 hostname: hostname
               })
    end

    test "get_onboarding/1 returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Identity.get_onboarding(Ecto.UUID.generate())
    end

    test "get_onboarding_by_hostname/1 finds a bound hostname and misses an unbound one" do
      %{tenant_id: tenant_id, tenant: tenant} = req076_tenant!("req076-onboard-byhost")
      cleanup_onboarding_record!(tenant_id)
      hostname = unique_hostname("byhost")

      {:ok, record} =
        Identity.create_onboarding(%{tenant_id: tenant_id, slug: tenant.slug, hostname: hostname})

      assert {:ok, ^record} = Identity.get_onboarding_by_hostname(hostname)
      assert {:error, :not_found} = Identity.get_onboarding_by_hostname(unique_hostname("miss"))
    end
  end

  # ISS-0773 regression coverage: sync_role_claims_from_token/3 must not
  # permanently stamp role_claims_synced_at when resolve_group_ids_for_role_names/2
  # resolves to zero group_ids for a non-empty claimed-role list -- doing so closes
  # off this function's own designed retry-on-nil-marker self-healing (see
  # lib/letflow/design/iss-0773-role-claims-sync-lockout-fix.md). See
  # test/letflow/plugs/iss0736_oidc_live_revocation_test.exs:247-301 for the
  # existing, unmodified, still-passing non-empty-grant success-path coverage this
  # fix must not regress.
  describe "sync_role_claims_from_token/3 (ISS-0773)" do
    # Binds a real tenant_role row (matching role_name) to a fresh group, WITHOUT
    # seeding any group_members row -- mirrors iss0736_oidc_live_revocation_test.exs's
    # bind_role_to_new_group!/2.
    #
    # ISS-0775: widened from /2 to /3 -- takes an explicit `kind` param instead of
    # always inserting :platform_role, so this same helper can exercise both kinds
    # of tenant_role row against the write path's new kind predicate (design
    # lib/letflow/design/iss-0775-oidc-role-sync-kind-scoping.md §3) without a
    # second near-duplicate helper. Deliberately call-site-breaking -- every
    # existing call site below is updated to pass :platform_role explicitly.
    defp bind_role_to_group!(role_name, kind, schema_name) do
      {:ok, group} =
        Identity.create_group(
          %{"name" => "iss0772-sync-#{role_name || "none"}-#{Ecto.UUID.generate()}"},
          prefix: schema_name
        )

      {:ok, _role} =
        %Letflow.Identity.TenantRole{}
        |> Letflow.Identity.TenantRole.changeset(%{
          name: role_name,
          kind: kind,
          group_id: group.id
        })
        |> Repo.insert(prefix: schema_name)

      group
    end

    defp group_member_rows(user_id, schema_name) do
      Repo.all(
        where(Letflow.Identity.GroupMember, [gm], gm.user_id == ^user_id),
        prefix: schema_name
      )
    end

    test "zero-grant sync (claimed role does not resolve) does not stamp the marker, and a second call re-syncs once a grant becomes available" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      claimed_ctx = identity_context(%{roles: ["ROLE_WITH_NO_MATCHING_TENANT_ROLE"]})

      # (1) First call: nothing in tenant_role matches the claimed role name --
      # resolve_group_ids_for_role_names/2 resolves to []. Pre-fix, this would
      # unconditionally stamp role_claims_synced_at, permanently disabling retry.
      synced_once = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)

      assert synced_once.role_claims_synced_at == nil
      assert group_member_rows(user.id, schema_name) == []

      # (2) Second call (simulating the user's next login before any tenant_role
      # row exists for their claimed role): must not raise, and must still leave
      # the marker nil -- proves the retry-on-nil-marker path genuinely re-executes
      # rather than short-circuiting on stale state.
      synced_twice = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)
      assert synced_twice.role_claims_synced_at == nil
      assert group_member_rows(user.id, schema_name) == []

      # (3) Now bind the claimed role name to a real group -- a THIRD call (the
      # next login after an operator fixes the seed-data/claim-mapping gap) must
      # succeed: this is the actual self-healing retry this fix restores.
      group =
        bind_role_to_group!("ROLE_WITH_NO_MATCHING_TENANT_ROLE", :platform_role, schema_name)

      synced_third = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)
      assert %DateTime{} = synced_third.role_claims_synced_at

      assert [%Letflow.Identity.GroupMember{group_id: gid}] =
               group_member_rows(user.id, schema_name)

      assert gid == group.id
    end

    test "logs a warning on zero-resolution with tenant/user_id/claimed-roles, and stays silent for a genuinely empty claimed-role list" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      config = jit_config()

      # ── (a) claims roles that don't resolve -- must log ──────────────────────
      ctx_a = identity_context()

      {:ok, %{user: user_a, created: true}} =
        Identity.provision_oidc_user(ctx_a, tenant.id, config, prefix: schema_name)

      claimed_ctx = identity_context(%{roles: ["UNMAPPED_ROLE_A", "UNMAPPED_ROLE_B"]})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Identity.sync_role_claims_from_token(user_a, claimed_ctx, prefix: schema_name)
        end)

      assert log =~ "sync_role_claims_from_token/3"
      assert log =~ "zero group_ids resolved"
      assert log =~ schema_name
      assert log =~ user_a.id
      assert log =~ "UNMAPPED_ROLE_A"
      assert log =~ "UNMAPPED_ROLE_B"

      # ── (b) claims zero roles at all -- must NOT log (distinct from (a): a
      # genuinely empty claim list is not a mapping failure) ────────────────────
      ctx_b = identity_context()

      {:ok, %{user: user_b, created: true}} =
        Identity.provision_oidc_user(ctx_b, tenant.id, config, prefix: schema_name)

      empty_ctx = identity_context(%{roles: []})

      silent_log =
        ExUnit.CaptureLog.capture_log(fn ->
          Identity.sync_role_claims_from_token(user_b, empty_ctx, prefix: schema_name)
        end)

      refute silent_log =~ "sync_role_claims_from_token/3"

      # And the marker still isn't stamped for the empty-claim case either --
      # same non-stamping mechanism as the non-empty-but-unresolved case, just
      # without the warning (§2.1/§2.2 of the design).
      user_b_after = Repo.get!(User, user_b.id, prefix: schema_name)
      assert user_b_after.role_claims_synced_at == nil
    end
  end

  # ISS-0775 regression coverage: resolve_group_ids_for_role_names/2's write path
  # must only ever resolve a claimed role name against a :platform_role-kind
  # tenant_role row, never a :process_routing_role-kind one -- see
  # lib/letflow/design/iss-0775-oidc-role-sync-kind-scoping.md §3 (T1-T3 below map
  # 1:1 to that design's own T1-T3). Reuses this file's ISS-0773
  # bind_role_to_group!/3 and group_member_rows/2 helpers (widened to take an
  # explicit `kind` param for this purpose).
  describe "sync_role_claims_from_token/3 — kind-scoped write path (ISS-0775)" do
    test "T1: a claimed name matching a :platform_role-kind row still writes group_members (no REQ-378 regression)" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      group = bind_role_to_group!("TASK_WORKER", :platform_role, schema_name)

      claimed_ctx = identity_context(%{roles: ["TASK_WORKER"]})
      synced = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)

      assert %DateTime{} = synced.role_claims_synced_at

      assert [%Letflow.Identity.GroupMember{group_id: gid}] =
               group_member_rows(user.id, schema_name)

      assert gid == group.id

      # Closes the loop end-to-end with the read path ISS-0774 already
      # established (design §3, final paragraph) -- the write just performed is
      # actually visible via list_effective_role_names/2 too, not just as a raw
      # group_members row.
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
               "TASK_WORKER"
             ]
    end

    test "T2: a claimed name matching a :process_routing_role-kind row writes nothing, and the zero-resolution warning fires" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      bind_role_to_group!("role-ops-manager", :process_routing_role, schema_name)

      claimed_ctx = identity_context(%{roles: ["role-ops-manager"]})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          synced = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)
          assert synced.role_claims_synced_at == nil
        end)

      assert group_member_rows(user.id, schema_name) == []

      # The claim was seen and deliberately not granted -- not silently dropped
      # before reaching this function at all (mirrors the existing ISS-0773
      # zero-resolution warning test, re-asserted here for this specific,
      # kind-mismatch input shape rather than assumed).
      assert log =~ "sync_role_claims_from_token/3"
      assert log =~ "zero group_ids resolved"
      assert log =~ "role-ops-manager"

      user_after = Repo.get!(User, user.id, prefix: schema_name)
      assert user_after.role_claims_synced_at == nil

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []
    end

    test "T3: one token claiming both a :platform_role-kind and a :process_routing_role-kind name (that collide across kinds) writes only the platform-kind membership" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      platform_group = bind_role_to_group!("TASK_WORKER", :platform_role, schema_name)
      _routing_group = bind_role_to_group!("role-ops-manager", :process_routing_role, schema_name)

      # Both names claimed in the SAME token -- this is the one shape that can't
      # pass by accident of a single-tenant_role fixture or test ordering (design
      # §3, T3's own rationale).
      claimed_ctx = identity_context(%{roles: ["TASK_WORKER", "role-ops-manager"]})
      synced = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)

      assert %DateTime{} = synced.role_claims_synced_at

      assert [%Letflow.Identity.GroupMember{group_id: gid}] =
               group_member_rows(user.id, schema_name)

      assert gid == platform_group.id

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
               "TASK_WORKER"
             ]
    end
  end

  describe "list_effective_role_names/2 (ISS-0774 T2 — design §2.4/§3)" do
    # docs/issues/ISS-0774.yaml: pre-fix, this query read tenant_role.name
    # unfiltered by naming domain, so a user whose ONLY tenant_role membership was
    # a process-definition HUMAN_TASK routing name (e.g. "role-ops-manager" from
    # test/fixtures/simulation/swiftroute/process_route_approval.yaml) had that
    # name feed straight into Authorization.roles_from_strings/1, which then
    # silently dropped it (role_from_string/1's closed set), reducing their
    # platform-role set to [] with no distinguishing signal from "genuinely no
    # roles at all". This is the direct proof that the fix's kind: :platform_role
    # filter (lib/letflow/identity.ex:702) is the actual mechanism closing that
    # gap -- isolated from any router/plug machinery, unlike T4 in
    # test/letflow/routers/tasks_test.exs which only confirms the request-time
    # behavior structurally.
    defp bind_role_and_membership!(schema_name, user_id, name, kind) do
      {:ok, group} =
        Identity.create_group(
          %{"name" => "iss0774-t2-#{kind}-#{Ecto.UUID.generate()}"},
          prefix: schema_name
        )

      {:ok, _role} =
        %Letflow.Identity.TenantRole{}
        |> Letflow.Identity.TenantRole.changeset(%{name: name, kind: kind, group_id: group.id})
        |> Repo.insert(prefix: schema_name)

      {:ok, _member} = Identity.add_group_member(group.id, user_id, prefix: schema_name)

      group
    end

    test "a user holding both a :platform_role-kind and a :process_routing_role-kind tenant_role only has the platform_role-kind name appear" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      # Same shape as the SwiftRoute/T-0140 fixture: a process-routing role name
      # ("role-ops-manager") that is NOT one of
      # Letflow.Api.Authorization.roles/0's six platform-role literals.
      bind_role_and_membership!(schema_name, user.id, "role-ops-manager", :process_routing_role)

      # Process-routing-only: effective platform role names is [], not a list
      # containing the routing name -- this is the exact bug ISS-0774 fixed.
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []

      bind_role_and_membership!(schema_name, user.id, "TASK_WORKER", :platform_role)

      # Adding the companion platform role surfaces ONLY it -- the process-routing
      # name never appears, regardless of how many of it the user holds.
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
               "TASK_WORKER"
             ]
    end
  end

  # ISS-0778 T2 (design §5): docs/issues/ISS-0778.yaml's root cause was that no code
  # path anywhere in this codebase ever created a tenant_role row binding a
  # platform-role literal (e.g. "PLATFORM_ADMIN") to a group -- so
  # sync_role_claims_from_token/3 and list_effective_role_names/2 themselves were
  # already correct (design §0), but had nothing to resolve against for ANY
  # freshly-provisioned tenant. This describe block is the direct, unit-level proof
  # that RoleRegistry.seed_default_platform_role_groups/1 (T1, tested in
  # test/letflow/role_registry_test.exs) is what closes that gap for the real,
  # unmodified sync mechanism -- not a coincidental pass. Deliberately shows the
  # BEFORE state too (claim resolves to nothing, matching UAT-RUNNER's own discovery
  # per the issue) alongside the AFTER state, on the SAME user and SAME claim, so the
  # only variable between the two assertions is whether seeding has run.
  # NOTE(ISS-0030): describe/test names kept short -- ExUnit's combined
  # "test " <> describe <> " " <> test_name atom is capped at 255 chars (BEAM
  # SystemLimitError). Full rationale in this describe block's own comment above.
  describe "ISS-0778 T2: sync_role_claims_from_token/3 after seeding" do
    test "before seeding: a TENANT_ADMIN claim resolves to zero grants; after seeding, the SAME claim/user resolves and syncs" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      # REQ-447: an ordinary tenant is seeded TENANT_ADMIN, not PLATFORM_ADMIN, so the claim
      # that proves the mechanism here is TENANT_ADMIN.
      claimed_ctx = identity_context(%{roles: ["TENANT_ADMIN"]})

      # ── BEFORE seeding ────────────────────────────────────────────────────────
      # No tenant_role row exists yet binding "TENANT_ADMIN" to any group on this
      # freshly-provisioned tenant -- resolve_group_ids_for_role_names/2 resolves to
      # [], so the sync writes nothing and (ISS-0773's self-healing marker
      # behavior) leaves role_claims_synced_at nil so a later retry can still
      # succeed once the gap is closed.
      before_seed = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)
      assert before_seed.role_claims_synced_at == nil
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []

      # ── ISS-0778's fix: seed the platform-role group/tenant_role bindings ───────
      assert {:ok, _roles} =
               Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(
                 prefix: schema_name
               )

      # ── AFTER seeding ────────────────────────────────────────────────────────
      # The IDENTICAL claimed_ctx, the SAME user, the SAME unmodified
      # sync_role_claims_from_token/3 -- now resolves and syncs, proving the seeded
      # row is genuinely usable by the existing JIT sync mechanism, not just that a
      # row exists somewhere unrelated.
      after_seed = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)
      assert %DateTime{} = after_seed.role_claims_synced_at

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
               "TENANT_ADMIN"
             ]
    end

    test "REQ-447: after seeding an ORDINARY tenant a PLATFORM_ADMIN claim still resolves to nothing; in the pinned platform tenant it resolves" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      config = jit_config()

      assert {:ok, _roles} =
               Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(
                 prefix: schema_name
               )

      {:ok, %{user: user, created: true}} =
        Identity.provision_oidc_user(identity_context(), tenant.id, config, prefix: schema_name)

      synced =
        Identity.sync_role_claims_from_token(
          user,
          identity_context(%{roles: ["PLATFORM_ADMIN"]}),
          prefix: schema_name
        )

      assert synced.role_claims_synced_at == nil
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []

      # The same tenant pinned as THE platform tenant: seeding (run again, idempotently)
      # now also binds PLATFORM_ADMIN, and the claim resolves.
      Letflow.Support.PlatformTenantFixture.pin!(tenant.id)

      assert {:ok, _roles} =
               Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(
                 prefix: schema_name
               )

      synced2 =
        Identity.sync_role_claims_from_token(
          user,
          identity_context(%{roles: ["PLATFORM_ADMIN"]}),
          prefix: schema_name
        )

      assert %DateTime{} = synced2.role_claims_synced_at

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
               "PLATFORM_ADMIN"
             ]
    end

    test "seeding closes the gap for the seedable platform-role literals of an ordinary tenant (design §2.1)" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      config = jit_config()

      assert {:ok, _roles} =
               Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(
                 prefix: schema_name
               )

      seedable = Letflow.Identity.RoleRegistry.seedable_role_names(schema_name)
      assert length(seedable) == length(Letflow.Api.Authorization.roles()) - 1
      refute "PLATFORM_ADMIN" in seedable

      for role_name <- seedable do
        ctx = identity_context()

        {:ok, %{user: user, created: true}} =
          Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

        claimed_ctx = identity_context(%{roles: [role_name]})

        synced = Identity.sync_role_claims_from_token(user, claimed_ctx, prefix: schema_name)

        assert %DateTime{} = synced.role_claims_synced_at

        assert Identity.list_effective_role_names(user.id, prefix: schema_name) == [
                 role_name
               ]
      end
    end
  end

  # Minimal local helper mirroring Ecto's own test-helper convention (avoids pulling
  # in a full Phoenix-style ConnCase/errors_on just for this one assertion).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
