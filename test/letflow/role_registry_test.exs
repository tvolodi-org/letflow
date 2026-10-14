defmodule Letflow.Identity.RoleRegistryTest do
  @moduledoc """
  Tests for `Letflow.Identity.RoleRegistry` (REQ-020): `list_roles/1`,
  `upsert_role/3`, `resolve_role_in_tx/1`. See `test/specs/REQ-020.md` for the full
  test-case rationale, including why AC5 (the `@moduledoc` content requirement) has no
  runtime test here and why AC4's "never raises" clause is covered the way it is.

  Separate file from `test/letflow/identity_test.exs` deliberately, mirroring
  `lib/letflow/design/req020-role-registry.md` §1's own module-boundary decision:
  `Letflow.Identity.RoleRegistry` is a standalone module, not a function added to
  `Letflow.Identity`, specifically so the "no OIDC-pipeline coupling" invariant is
  structural rather than a convention inside a file that already imports OIDC-adjacent
  aliases for sibling functions. The test file mirrors that same boundary — this file
  never aliases `Letflow.Identity` or any `Letflow.Oidc.*` module, matching the
  production module it tests.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## REQ-063 fixture change (read before touching a test here)

  REQ-063 (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `groups`/`tenant_role` out of `public` into each tenant's own provisioned Postgres
  schema. `Letflow.Identity.RoleRegistry` itself was deliberately NOT modified by
  REQ-063 (out of that design's scope — see
  `lib/letflow/design/req020-role-registry.md`'s "Why zero arguments" section,
  which explicitly documents that `list_roles/0`/`upsert_role/2`/
  `resolve_role_in_tx/1` all take no tenant/prefix parameter today, relying on a
  future per-request `SET search_path` mechanism Letflow has "not built yet" as of
  REQ-020's own writing). REQ-063 made that future mechanism's absence concrete: with
  `groups`/`tenant_role` no longer in `public` at all, `RoleRegistry`'s unprefixed
  queries now need a real `search_path` pointed at a tenant schema to find anything.

  This file therefore now provisions a real tenant schema per test (`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`
  + `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/2`) and
  issues `SET search_path TO "<schema>", public` on that connection before each
  test body runs — see `test/letflow/identity/user_test.exs`'s own moduledoc,
  "Sandbox mode: what ACTUALLY protects against cross-test leakage" section, for
  the full reasoning. In short: switching to `:auto` mode above checks in
  (discards) whatever sandboxed transaction `Letflow.DataCase`'s own setup had
  already checked out, so `SET search_path` is NOT automatically reverted by any
  rollback at that point — an earlier version of this moduledoc wrongly claimed
  it was. What actually protects against leakage is that this file's `setup`
  below explicitly restores a real sandboxed transaction
  (`Sandbox.mode(Repo, :manual)` + fresh `Sandbox.checkout/1`) immediately after
  the migration-replay work finishes and BEFORE issuing `SET search_path`, so
  the `SET search_path` call and everything the test body does afterward run
  inside a transaction that gets rolled back at teardown. Deliberately NOT
  `{:shared, self()}` mode: this file's tests are single-process (no
  `Task.async` spawns needing to share the connection).

  This deliberately does NOT register an `on_exit/1`-based `Sandbox.checkin/1`
  either. An earlier version of this fix did, believing the checkin closed the
  loop; it did not — `Ecto.Adapters.SQL.Sandbox.checkin/1` (and
  `DBConnection.Ownership`'s `ownership_checkin`/`proxy_checkin` underneath it,
  see `deps/db_connection/lib/db_connection/ownership/manager.ex`) keys the
  checkin by the CALLING process's own pid, but `ExUnit.OnExitHandler` runs
  every `on_exit/1` callback via `spawn_monitor` in a dedicated runner process,
  never the original test process that performed the checkout — so a checkin
  issued from `on_exit/1` checks in on behalf of the wrong process and silently
  no-ops (`:not_found`). What actually reclaims the checked-out connection and
  rolls back its transaction is `DBConnection.Ownership.Manager`'s own
  unconditional `:DOWN`-monitor handler (`handle_info({:DOWN, ref, _, _, _},
  state)`), which fires automatically once this test's own process exits — the
  exact mechanism `Letflow.DataCase`'s own `{:shared, self()}` checkout already
  relies on (it never calls `checkin/1` either). No explicit checkin step is
  attempted here.
  `Ecto.Migrator` cannot run under the sandbox's single shared connection
  (`lib/letflow/design/req022-tenant-schema-provisioning.md` §6's testing-
  environment caveat), so this file is now `async: false` for its entire module
  (ExUnit's `async` setting is module-wide) — unlike its pre-REQ-063 version, which
  ran `async: true` against bare `public` tables. Every test still builds its own
  unique `Group`/`TenantRole` fixture names (no shared hardcoded values), and since
  each test also gets its OWN freshly-provisioned tenant schema (not merely a
  rolled-back transaction against a shared one), `tenant_role.name`'s table-wide
  unique index cannot collide across tests even though they now run sequentially
  rather than concurrently.

  ## ISS-0112 batch 10 — reclassified A∩C to A-only on fresh read

  `lib/letflow/design/iss0112-tenant-fixture-migration-plan.md`'s batch table
  grep-classified this file as category A∩C (`SandboxAutoMode`-shaped teardown
  AND genuine `Task.async`/`Task.start`). A full read found no real `Task.`
  spawn anywhere in this file — the only two occurrences of the substring
  `Task.async` are inside this moduledoc's own prose (above), explaining why
  this file's tests are deliberately single-process. This mirrors the exact
  reclassification `test/letflow/identity/group_test.exs`,
  `tenant_role_test.exs`, and `user_test.exs` underwent in batch 9 (grep hit
  on a comment mentioning `Task.async`, not a real spawn). Migrated as
  category A-only: `setup`'s and `provision_second_tenant!/0`'s provisioning
  halves now call `Letflow.TenantFixture.provisioned_tenant!(teardown: false,
  ...)`; both pre-existing `on_exit/1` teardown chains are kept unchanged.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # Every test builds its own unique name/tenant — no shared hardcoded values, per
  # test_developer_guide.md's "no test pollution" principle and this project's
  # established System.unique_integer/1 convention (identity_test.exs's unique_realm/1,
  # unique_slug/1).
  defp unique_name(prefix \\ "role") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_slug, do: Letflow.TenantSlugFixture.unique_slug("req063-rolereg")

  setup do
    # Provisions via Letflow.TenantFixture (ISS-0112 / GH#366), teardown: false
    # because this file's own on_exit/1 below force-restores :auto mode before
    # its DROP SCHEMA/delete_all cleanup (a composition TenantFixture's default
    # teardown does not perform) -- matching category A's established pattern
    # (test/letflow/audit_capture_test.exs). The provisioning half (insert
    # tenant, provision schema, replay, assert-complete) is what the fixture
    # call replaces; the teardown half below is kept byte-for-byte, only
    # `tenant.id`/`tenant` references swapped for the fixture's own returned
    # `tenant_id`/`tenant` keys.
    %{tenant_id: tenant_id, tenant: tenant, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req063-rolereg",
        display_name: "REQ-063 RoleRegistry Test",
        teardown: false
      )

    on_exit(fn ->
      # This callback runs AFTER the test process (and thus the {:shared, self()}
      # ownership set up below) is gone -- so it must not assume that mode is still
      # in effect. Force :auto mode first so the DROP SCHEMA / DELETE cleanup below
      # always gets a real, checked-in connection regardless of what mode the test
      # body left the pool in (mirrors identity_test.exs's own on_exit/1 handling
      # of this exact hazard, confirmed empirically there).
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    # REQ-063 rework (iteration 2): restore a REAL sandboxed transaction before
    # issuing SET search_path -- :auto mode above checked in (discarded) whatever
    # transaction Letflow.DataCase's setup had checked out, so without this
    # restore, SET search_path (a session-level GUC, not SET LOCAL) would commit
    # against a bare pooled connection and leak into whichever later test reuses
    # that connection. Mirrors identity_test.exs's "provision_oidc_user/4 --
    # concurrent-insert race" test (same underlying constraint, same fix). See
    # this file's moduledoc and user_test.exs's moduledoc.
    #
    # Uses plain :manual mode + a bare checkout (NOT {:shared, self()}) -- this
    # file's tests are single-process (no Task.async spawns needing to share the
    # connection), so there is no need for shared ownership.
    #
    # Deliberately does NOT register an on_exit/1 checkin -- see moduledoc's
    # "Sandbox mode: what ACTUALLY protects against cross-test leakage" section.
    # A checkin from on_exit/1 runs in ExUnit's separate OnExitHandler process,
    # not this test process, so DBConnection.Ownership.Manager's proxy_checkin
    # (keyed by the CALLING process's pid) finds no matching ownership entry and
    # silently no-ops. This checkout is instead reclaimed by
    # DBConnection.Ownership.Manager's unconditional :DOWN-monitor handler when
    # this test process itself exits -- the same mechanism Letflow.DataCase's
    # own {:shared, self()} checkout already relies on.
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

    Repo.query!(~s(SET search_path TO "#{schema_name}", public))

    %{tenant: tenant, schema_name: schema_name}
  end

  defp insert_group!(_ctx) do
    %Group{}
    |> Ecto.Changeset.change(%{
      name: "group-#{System.unique_integer([:positive, :monotonic])}"
    })
    |> Repo.insert!()
  end

  # ISS-0768 cross-tenant-isolation fixture: inserts a Group directly under an
  # EXPLICIT `prefix:` rather than relying on the ambient `search_path` the way
  # `insert_group!/1` above does. Needed because the cross-tenant test below runs
  # its whole body in Sandbox `:auto` mode (see `provision_second_tenant!/0`'s
  # comment for why) rather than inside `setup`'s manual-mode/`SET search_path`
  # transaction, so there is no single ambient schema to rely on once a SECOND
  # tenant schema is alive in the same test.
  defp insert_group!(_ctx, prefix) do
    %Group{}
    |> Ecto.Changeset.change(%{
      name: "group-#{System.unique_integer([:positive, :monotonic])}"
    })
    |> Repo.insert!(prefix: prefix)
  end

  # ISS-0768 regression fixture: provisions a SECOND, fully independent tenant
  # schema so the cross-tenant-isolation test below can hold two real Postgres
  # schemas alive at once. Mirrors `test/letflow/identity/user_test.exs`'s
  # `provision_tenant_schema!/0` two-tenant pattern (same underlying constraint):
  # `Ecto.Migrator` needs Sandbox `:auto` mode to run its migration replay, and
  # switching to `:auto` mode checks in (and rolls back) whatever `:manual`-mode
  # sandboxed transaction this file's own `setup` block above already holds for
  # tenant A. That means the caller must have already committed anything it
  # needs from tenant A for real (i.e. also run under `:auto` mode) BEFORE
  # calling this — see the test below, which switches the whole Repo to `:auto`
  # mode as its very first step, before inserting tenant A's own role, for
  # exactly this reason.
  #
  # Real, committed Postgres state (a `CREATE SCHEMA` inside a transaction that
  # later rolls back would not persist), so cleanup is explicit via `on_exit/1`,
  # not sandbox rollback — same shape as `setup`'s own on_exit cleanup for
  # tenant A.
  defp provision_second_tenant! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    %{tenant_id: tenant_id, tenant: tenant, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req063-rolereg",
        display_name: "ISS-0768 RoleRegistry Test (tenant B)",
        teardown: false
      )

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    %{tenant: tenant, schema_name: schema_name}
  end

  describe "list_roles/1 (acceptance criterion 1)" do
    test "returns [] (not an error) against an empty tenant_role table", ctx do
      assert RoleRegistry.list_roles(prefix: ctx.schema_name) == []
    end

    test "returns all rows sorted by name ascending, proving the ORDER BY is real", ctx do
      group = insert_group!(ctx)

      # Names deliberately chosen so alphabetical order differs from insertion order —
      # if list_roles/1 silently relied on insertion/primary-key order instead of a
      # real ORDER BY name, this would fail: inserting "zeta" then "alpha" then "mid"
      # would come back in that same insertion order, not alphabetically.
      name_zeta = "zeta-#{System.unique_integer([:positive, :monotonic])}"
      name_alpha = "alpha-#{System.unique_integer([:positive, :monotonic])}"
      name_mid = "mid-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _} =
               RoleRegistry.upsert_role(name_zeta, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      assert {:ok, _} =
               RoleRegistry.upsert_role(name_alpha, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      assert {:ok, _} =
               RoleRegistry.upsert_role(name_mid, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      names =
        RoleRegistry.list_roles(prefix: ctx.schema_name)
        |> Enum.map(& &1.name)
        |> Enum.filter(&(&1 in [name_zeta, name_alpha, name_mid]))

      assert names == [name_alpha, name_mid, name_zeta]
    end
  end

  describe "upsert_role/3 — group_id not found (acceptance criterion 2)" do
    test "a syntactically-valid but nonexistent group_id returns {:error, :group_not_found} and inserts no row",
         ctx do
      name = unique_name()
      nonexistent_group_id = Ecto.UUID.generate()

      assert {:error, :group_not_found} =
               RoleRegistry.upsert_role(name, :process_routing_role, nonexistent_group_id,
                 prefix: ctx.schema_name
               )

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end

  # GH 2524 replaced REQ-020 AC3's silent update: a different group is refused, the same
  # group is a no-op. Moving a binding is RoleRegistry.rebind_role/4.
  describe "upsert_role/4 on an existing binding (GH 2524)" do
    test "a different group_id is refused with :role_already_bound and the binding is unchanged, no duplicate row",
         ctx do
      name = unique_name()
      group_a = insert_group!(ctx)
      group_b = insert_group!(ctx)

      assert {:ok, %TenantRole{group_id: first_group_id}} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_a.id,
                 prefix: ctx.schema_name
               )

      assert first_group_id == group_a.id

      assert {:error, :role_already_bound} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_b.id,
                 prefix: ctx.schema_name
               )

      # Re-select from Postgres directly rather than trusting the in-memory reply.
      rows = TenantRole |> where(name: ^name) |> Repo.all()

      assert length(rows) == 1
      assert hd(rows).group_id == group_a.id
    end

    test "the same group_id twice is idempotent: same row id, nothing changes", ctx do
      name = unique_name()
      group_a = insert_group!(ctx)

      assert {:ok, %TenantRole{id: id}} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_a.id,
                 prefix: ctx.schema_name
               )

      [before] = TenantRole |> where(name: ^name) |> Repo.all()

      assert {:ok, %TenantRole{id: ^id, group_id: group_id}} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_a.id,
                 prefix: ctx.schema_name
               )

      assert group_id == group_a.id
      assert TenantRole |> where(name: ^name) |> Repo.all() == [before]
    end

    test "the same group_id written in upper case is the same group (canonical compare)", ctx do
      name = unique_name()
      group_a = insert_group!(ctx)

      assert {:ok, %TenantRole{id: id}} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_a.id,
                 prefix: ctx.schema_name
               )

      assert {:ok, %TenantRole{id: ^id}} =
               RoleRegistry.upsert_role(
                 name,
                 :process_routing_role,
                 String.upcase(group_a.id),
                 prefix: ctx.schema_name
               )
    end
  end

  describe "resolve_role_in_tx/1 (acceptance criterion 4)" do
    test "returns the bound group_id for a name that exists", ctx do
      name = unique_name()
      group = insert_group!(ctx)

      assert {:ok, _} =
               RoleRegistry.upsert_role(name, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      assert RoleRegistry.resolve_role_in_tx(name) == group.id
    end

    test "returns nil for an unbound/unknown name", _ctx do
      assert RoleRegistry.resolve_role_in_tx(unique_name("nonexistent")) == nil
    end

    test "called from inside an existing Repo.transaction/1 callback (its documented usage), still resolves correctly",
         ctx do
      name = unique_name()
      group = insert_group!(ctx)

      assert {:ok, _} =
               RoleRegistry.upsert_role(name, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      result =
        Repo.transaction(fn ->
          RoleRegistry.resolve_role_in_tx(name)
        end)

      assert {:ok, resolved_group_id} = result
      assert resolved_group_id == group.id
    end

    # "Never raises" coverage — see test/specs/REQ-020.md's discussion of why this is
    # the practical limit of this claim's testability at this level. The unbound-name
    # case above already exercises the ordinary nil-producing path (Repo.get_by/2's own
    # no-match behavior, which never raises to begin with — no rescue needed there).
    # This test targets the OTHER branch: a query that reaches Ecto/Postgrex but fails
    # in a way that would normally raise (here, an invalid parameter type causing
    # Ecto.Query.CastError), proving the function's explicit `rescue` genuinely
    # intercepts a real raised exception rather than merely never encountering one in
    # the two obvious cases.
    test "a query-level error that would otherwise raise resolves to nil, not an unhandled exception",
         _ctx do
      # Repo.get_by(TenantRole, name: name) expects `name` to be a string (the schema's
      # field type). Passing a value Ecto cannot cast for that field forces
      # Ecto.Query.CastError inside the query built by resolve_role_in_tx/1's own
      # implementation, exercising the function's `rescue` clause for real rather than
      # by construction/inspection alone.
      invalid_name = {:not, :a, :string}

      assert RoleRegistry.resolve_role_in_tx(invalid_name) == nil
    end
  end

  describe "upsert_role/3 — name validation rejection modes (beyond the bare acceptance criteria)" do
    test "rejects an empty name", ctx do
      group = insert_group!(ctx)

      assert {:error, :invalid_role_name} =
               RoleRegistry.upsert_role("", :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end

    test "rejects a name longer than 128 codepoints", ctx do
      group = insert_group!(ctx)
      too_long = String.duplicate("a", 129)

      assert {:error, :invalid_role_name} =
               RoleRegistry.upsert_role(too_long, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end

    test "accepts a name of exactly 128 codepoints (the boundary itself is valid)", ctx do
      group = insert_group!(ctx)
      exactly_128 = String.duplicate("a", 128)

      assert {:ok, %TenantRole{name: ^exactly_128}} =
               RoleRegistry.upsert_role(exactly_128, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end

    test "rejects a name containing a control character", ctx do
      group = insert_group!(ctx)
      with_control_char = "role-#{<<0x01>>}-name"

      assert {:error, :invalid_role_name} =
               RoleRegistry.upsert_role(with_control_char, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end
  end

  describe "REQ-076 AC6 — role name outside the five auth.Role enum values is accepted (format-only constraint)" do
    # See lib/letflow/design/req076-identity-tokens-roles-onboarding.md §5.1: R-Co's
    # role_registry.zig upsertRole/3 validates ONLY name format (non-empty, <=128
    # codepoints, no control characters) -- never enum membership against
    # auth.Role's five-value RBAC set. Letflow.Identity.RoleRegistry.upsert_role/3
    # (REQ-020, prefix threaded by ISS-0768) already matches that behavior exactly.
    # This test is the load-bearing new case AC6 asks for: a name that is NOT one of
    # PLATFORM_ADMIN/PROCESS_DESIGNER/PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER,
    # accepted anyway. The pre-existing "name validation rejection modes" describe
    # block above (empty, too-long, control-char) already supplies AC6's required
    # rejected-name case -- reused, not duplicated.
    test "a role name outside the five auth.Role enum values (e.g. CUSTOM_APPROVER) is accepted",
         ctx do
      group = insert_group!(ctx)

      assert {:ok, %TenantRole{name: "CUSTOM_APPROVER"}} =
               RoleRegistry.upsert_role("CUSTOM_APPROVER", :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      # Not one of the five recognized Letflow.Api.Authorization.roles/0 values --
      # confirms this genuinely exercises the "outside the enum" case, not an
      # accident of overlap.
      refute "CUSTOM_APPROVER" in Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
    end
  end

  describe "upsert_role/3 — group_id invalid-UUID-format rejection (beyond the bare acceptance criteria)" do
    test "rejects a group_id that is not a syntactically valid UUID, distinct from the not-found case",
         ctx do
      name = unique_name()

      assert {:error, :invalid_group_id} =
               RoleRegistry.upsert_role(name, :process_routing_role, "not-a-uuid",
                 prefix: ctx.schema_name
               )

      rows = TenantRole |> where(name: ^name) |> Repo.all()
      assert rows == []
    end
  end

  describe "ISS-0774 T1 — upsert_role/4 kind-conditional name validation (design §2.3/§3)" do
    # docs/issues/ISS-0774.yaml root cause: tenant_role conflated a CLOSED
    # platform-permission-role namespace (Letflow.Api.Authorization.roles/0's six
    # literals) with an OPEN-ended process-routing-role namespace (arbitrary
    # process-definition-chosen HUMAN_TASK role names, e.g. "role-ops-manager" from
    # test/fixtures/simulation/swiftroute/process_route_approval.yaml). Pre-fix,
    # upsert_role/3 took no `kind` at all and validated only format, so a typo'd
    # platform-role grant (e.g. "PLATFORM_ADMN") would silently create a tenant_role
    # row nothing downstream (Authorization.role_from_string/1's closed set) would
    # ever resolve -- a dead binding an operator would have no signal about. This
    # describe block proves upsert_role/4's asymmetric validation: kind: :platform_role
    # rejects loudly (§2.3), kind: :process_routing_role accepts anything
    # format-valid (open-ended domain, unchanged from the old behavior).
    test "kind: :platform_role with a name IN Authorization.roles/0's six literals succeeds",
         ctx do
      group = insert_group!(ctx)

      assert {:ok, %TenantRole{name: "TASK_WORKER", kind: :platform_role}} =
               RoleRegistry.upsert_role("TASK_WORKER", :platform_role, group.id,
                 prefix: ctx.schema_name
               )
    end

    test "kind: :platform_role with a name NOT in the closed set fails loudly with {:error, :name_not_a_recognized_platform_role} -- not a silent dead binding",
         ctx do
      group = insert_group!(ctx)
      mistyped = "PLATFORM_ADMN"

      refute mistyped in Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)

      assert {:error, :name_not_a_recognized_platform_role} =
               RoleRegistry.upsert_role(mistyped, :platform_role, group.id,
                 prefix: ctx.schema_name
               )

      # The loud rejection is not merely a return value -- no row was written either,
      # proving this isn't "reject after insert" but "reject before any Repo call"
      # (§2.3's own documented ordering: validate_platform_role_name/2 runs before
      # do_upsert_role/4).
      rows = TenantRole |> where(name: ^mistyped) |> Repo.all()
      assert rows == []
    end

    test "REQ-447 PR 2: kind: :platform_role with the name PLATFORM_ADMIN is refused outside the platform tenant, and writes no row",
         ctx do
      group = insert_group!(ctx)

      assert {:error, :platform_admin_outside_platform_tenant} =
               RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id,
                 prefix: ctx.schema_name
               )

      assert Repo.all(from(r in TenantRole, where: r.name == "PLATFORM_ADMIN"),
               prefix: ctx.schema_name
             ) == []
    end

    test "kind: :process_routing_role accepts a name outside the closed platform-role set (open-ended domain, no literal-set check)",
         ctx do
      group = insert_group!(ctx)
      routing_name = "role-ops-manager"

      refute routing_name in Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)

      assert {:ok, %TenantRole{name: ^routing_name, kind: :process_routing_role}} =
               RoleRegistry.upsert_role(routing_name, :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end

    test "kind: :process_routing_role also accepts one of the six platform-role literal strings -- no cross-domain rejection either way",
         ctx do
      group = insert_group!(ctx)

      assert {:ok, %TenantRole{name: "TASK_WORKER", kind: :process_routing_role}} =
               RoleRegistry.upsert_role("TASK_WORKER", :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )
    end
  end

  describe "ISS-0774 T3 — check_platform_role_coverage/2 (design §2.5/§3, AC2 'provable by a test')" do
    # T2 (list_effective_role_names/2 kind-filtering) lives in
    # test/letflow/identity_test.exs -- deliberately not duplicated here, matching
    # this file's own moduledoc boundary (RoleRegistry's test file stays independent
    # of Letflow.Identity's).
    defp add_member!(ctx, group_id, user_id) do
      %Letflow.Identity.GroupMember{}
      |> Ecto.Changeset.change(%{group_id: group_id, user_id: user_id})
      |> Repo.insert!(prefix: ctx.schema_name)
    end

    defp insert_user_row!(ctx) do
      %Letflow.Identity.User{}
      |> Ecto.Changeset.change(%{
        username: "user-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "ISS-0774 T3 User",
        email: "iss0774-t3-#{System.unique_integer([:positive, :monotonic])}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)
    end

    test "a user holding only process-routing roles gets {:error, {:missing_platform_role, gap}} naming the exact gap",
         ctx do
      user = insert_user_row!(ctx)
      group = insert_group!(ctx)
      add_member!(ctx, group.id, user.id)

      assert {:ok, _} =
               RoleRegistry.upsert_role("role-ops-manager", :process_routing_role, group.id,
                 prefix: ctx.schema_name
               )

      assert {:error, {:missing_platform_role, gap}} =
               RoleRegistry.check_platform_role_coverage(user.id, prefix: ctx.schema_name)

      assert gap == %{held_process_routing_roles: ["role-ops-manager"], held_platform_roles: []}
    end

    test "the SAME user, after also being granted a companion platform role, gets :ok",
         ctx do
      user = insert_user_row!(ctx)
      routing_group = insert_group!(ctx)
      platform_group = insert_group!(ctx)

      add_member!(ctx, routing_group.id, user.id)

      assert {:ok, _} =
               RoleRegistry.upsert_role(
                 "role-ops-manager",
                 :process_routing_role,
                 routing_group.id,
                 prefix: ctx.schema_name
               )

      # Still only process-routing roles held -- coverage check must still flag the gap.
      assert {:error, {:missing_platform_role, _gap}} =
               RoleRegistry.check_platform_role_coverage(user.id, prefix: ctx.schema_name)

      add_member!(ctx, platform_group.id, user.id)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TASK_WORKER", :platform_role, platform_group.id,
                 prefix: ctx.schema_name
               )

      assert RoleRegistry.check_platform_role_coverage(user.id, prefix: ctx.schema_name) == :ok
    end

    test "a user holding at least one platform role (and no process-routing roles at all) gets :ok",
         ctx do
      user = insert_user_row!(ctx)
      group = insert_group!(ctx)
      add_member!(ctx, group.id, user.id)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TASK_WORKER", :platform_role, group.id,
                 prefix: ctx.schema_name
               )

      assert RoleRegistry.check_platform_role_coverage(user.id, prefix: ctx.schema_name) == :ok
    end

    test "a user with no tenant_role membership at all gets :ok (not this function's scenario)",
         ctx do
      user = insert_user_row!(ctx)

      assert RoleRegistry.check_platform_role_coverage(user.id, prefix: ctx.schema_name) == :ok
    end
  end

  describe "ISS-0778 T1 — seed_default_platform_role_groups/1 (design §3.1/§2.4)" do
    # docs/issues/ISS-0778.yaml root cause (design §0): no code path anywhere in this
    # codebase ever created a tenant_role row binding a platform-role literal to a
    # group, for any tenant -- so a freshly-provisioned tenant had no route to a
    # working PLATFORM_ADMIN (or any other platform-role) grant, even with a
    # correctly-configured IdP. This describe block is the unit-level proof that the
    # new seeding function itself does what the design claims: seeds all six
    # Letflow.Api.Authorization.roles/0 literals as group+tenant_role bindings, and is
    # idempotent under re-invocation (design §2.4 -- required for both the normal
    # onboarding-creation path and TenantOnboarding.recover_provisioning/1 to be safe
    # to call more than once against the same tenant).
    test "seeds the non-platform-tenant role literals (all but PLATFORM_ADMIN) in roles/0 order; a second call converges (no duplicates)",
         ctx do
      # REQ-447: this fixture tenant is not the pinned platform tenant, so PLATFORM_ADMIN is
      # not seeded; TENANT_ADMIN and TENANT_AUDITOR are (REQ-448). Rows = roles/0 minus PLATFORM_ADMIN.
      expected_names =
        Letflow.Api.Authorization.roles()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.reject(&(&1 == "PLATFORM_ADMIN"))

      assert "TENANT_ADMIN" in expected_names

      assert {:ok, roles} =
               RoleRegistry.seed_default_platform_role_groups(prefix: ctx.schema_name)

      assert length(roles) == length(expected_names)
      assert Enum.map(roles, & &1.name) == expected_names
      assert Enum.all?(roles, &(&1.kind == :platform_role))

      # Exactly one Group row and one TenantRole row per seeded name exist -- not merely that the
      # function's return value looked right, matching this project's established
      # "re-select from Postgres directly" persistence-test convention.
      assert Repo.aggregate(Group, :count, prefix: ctx.schema_name) == length(expected_names)
      assert Repo.aggregate(TenantRole, :count, prefix: ctx.schema_name) == length(expected_names)

      group_ids_first = roles |> Enum.map(& &1.group_id) |> Enum.sort()

      # Idempotency (design §2.4): calling it a SECOND time against the same,
      # already-seeded tenant schema must converge on the IDENTICAL six group_ids
      # (get-or-create-by-name found the existing groups, upsert_role/4's own
      # on-conflict upsert overwrote each binding with the same values) -- no
      # duplicate groups row, no duplicate tenant_role row, no error.
      assert {:ok, roles2} =
               RoleRegistry.seed_default_platform_role_groups(prefix: ctx.schema_name)

      assert Enum.map(roles2, & &1.name) == expected_names
      assert Enum.all?(roles2, &(&1.kind == :platform_role))

      group_ids_second = roles2 |> Enum.map(& &1.group_id) |> Enum.sort()
      assert group_ids_second == group_ids_first

      assert Repo.aggregate(Group, :count, prefix: ctx.schema_name) == length(expected_names)
      assert Repo.aggregate(TenantRole, :count, prefix: ctx.schema_name) == length(expected_names)
    end

    test "against a tenant schema that already has unrelated process-routing-role bindings, only the platform-role names are affected",
         ctx do
      # A process-routing-role binding pre-exists (a HUMAN_TASK routing group, exactly
      # the ISS-0774 domain distinction this codebase already draws) -- proves seeding
      # is scoped to the platform-role literal set, not "every row in tenant_role".
      routing_group = insert_group!(ctx)

      assert {:ok, %TenantRole{name: "role-ops-manager", kind: :process_routing_role}} =
               RoleRegistry.upsert_role(
                 "role-ops-manager",
                 :process_routing_role,
                 routing_group.id,
                 prefix: ctx.schema_name
               )

      assert {:ok, roles} =
               RoleRegistry.seed_default_platform_role_groups(prefix: ctx.schema_name)

      seeded_count = length(RoleRegistry.seedable_role_names(ctx.schema_name))
      assert length(roles) == seeded_count
      refute "role-ops-manager" in Enum.map(roles, & &1.name)

      # Total tenant_role count is the seeded count + 1 (pre-existing routing row) -- the
      # routing row survived untouched, not overwritten or deleted.
      assert Repo.aggregate(TenantRole, :count, prefix: ctx.schema_name) == seeded_count + 1

      assert %TenantRole{kind: :process_routing_role, group_id: unchanged_group_id} =
               Repo.get_by(TenantRole, [name: "role-ops-manager"], prefix: ctx.schema_name)

      assert unchanged_group_id == routing_group.id
    end
  end

  describe "ISS-0768 regression — prefix genuinely scopes RoleRegistry to one tenant's own schema" do
    # docs/issues/ISS-0768.yaml's own acceptance criteria: "a real test creates a
    # role for one tenant and confirms it is queryable only in that tenant's own
    # schema (not visible via a different tenant's prefix, not written to
    # public)". Every OTHER test in this file provisions exactly one tenant
    # schema and only ever asserts within it (see file moduledoc) -- none of them
    # can distinguish "correctly scoped to tenant A" from "RoleRegistry ignores
    # the prefix option and always hits whatever schema search_path happens to
    # point at", because they never stand up a second, genuinely different
    # schema to probe. This test does.
    test "role created under tenant A's prefix: visible via A's own prefix, absent via tenant B's prefix, absent from public",
         %{schema_name: schema_a} = ctx do
      # Switch the whole Repo to :auto mode FIRST, before inserting anything --
      # provision_second_tenant!/0 below also needs :auto mode (for
      # Ecto.Migrator), and switching modes checks in (rolls back) whatever
      # :manual-mode sandboxed transaction `setup` above left this process in.
      # Doing the tenant-A insert before that switch would silently roll it back
      # the moment tenant B gets provisioned, and this test would then be
      # asserting on a row that was never really there. See
      # test/letflow/identity/user_test.exs's "same username, two different
      # tenant schemas" test for the identical constraint and fix shape.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      group_a = insert_group!(ctx, schema_a)
      name = unique_name("iso")

      assert {:ok, %TenantRole{name: ^name}} =
               RoleRegistry.upsert_role(name, :process_routing_role, group_a.id, prefix: schema_a)

      %{schema_name: schema_b} = provision_second_tenant!()
      refute schema_b == schema_a

      # Positive case: the role IS visible under its own tenant's prefix.
      names_a = RoleRegistry.list_roles(prefix: schema_a) |> Enum.map(& &1.name)
      assert name in names_a

      # Negative case 1: NOT visible via a genuinely different tenant's own
      # prefix -- a real second Postgres schema (schema_b, just provisioned
      # above), not merely a different filter over the same underlying table.
      names_b = RoleRegistry.list_roles(prefix: schema_b) |> Enum.map(& &1.name)
      refute name in names_b

      # Negative case 2: NOT written to `public` at all. SECURITY-REVIEWER's
      # step-04 addendum (this test's own trigger, see ISS-0768.yaml's
      # acceptance criteria) treats "not visible via a different tenant's
      # prefix" and "not written to public" as two SEPARATE, both-required
      # assertions, not one implied by the other -- negative case 1 above only
      # proves `list_roles/1` itself resolves prefixes correctly on the READ
      # side; it says nothing about where `upsert_role/3` actually WROTE the
      # row. This queries `public` directly with `Repo.all/2`, entirely outside
      # `RoleRegistry`'s own prefix handling, so it independently confirms the
      # write itself targeted schema_a and nowhere else.
      #
      # REQ-063 (lib/letflow/design/req063-identity-tables-schema-per-tenant.md)
      # moved `tenant_role` out of `public` entirely -- confirmed empirically
      # below, `public.tenant_role` is not merely empty, it does not exist as a
      # relation at all, which Postgres reports as `Postgrex.Error` /
      # `undefined_table` (SQLSTATE 42P01) rather than an empty result set. That
      # is actually the STRONGER form of "not written to public" the acceptance
      # criterion asks for: there is structurally no table in `public` for the
      # row to have landed in, not merely a query that happens to find zero
      # matching rows in one that exists.
      assert_raise Postgrex.Error, ~r/relation "public\.tenant_role" does not exist/, fn ->
        TenantRole
        |> where(name: ^name)
        |> Repo.all(prefix: "public")
      end
    end
  end
end
