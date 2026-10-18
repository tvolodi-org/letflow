defmodule Letflow.ScopeEnforcementOnTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 16 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.2; spec
  `test/specs/REQ-517-2b.md`, T-O1, T-O2, T-O4, T-O5, T-O6): the STORED value `on` of
  `tenants.scope_enforcement`.

    * T-O1 the widened CHECK and the `Tenant` enum: `off | shadow | on` are stored, any other
      spelling (`ON`, `x`, the empty string) violates `tenants_scope_enforcement_check`; the public
      migration `20261018200001` applies and rolls back on a SCRATCH schema holding a copy of
      `tenants` (never on the shared table), and its `down` RAISES while any tenant is `on` (it
      never silently de-escalates);
    * T-O2 nothing can SET `on`: `parse_mode/1`, `flip/4` and `PUT /tenant/scope-enforcement`
      all reject it, and the stored column is unchanged by a refused attempt;
    * T-O4 `GET /tenant/scope-enforcement` for an `on` tenant answers `"mode": "on"` while
      `available_modes` stays `["off", "shadow"]` (no 500: `get_mode/1` reads the stored set);
    * T-O5 the test helper lives under `test/support`, never `lib/`, and
      `Tenant.scope_enforcement_changeset/2` is called from `lib/` only by
      `lib/letflow/scope_enforcement.ex`; no other tenant changeset casts the field, `on`
      included;
    * T-O6 a tenant stored `on` can still be flipped `off` with a reason (and not without one),
      with its audit entry.

  `async: false`: committed writes, a scratch schema and `Ecto.Migrator`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @version 20_261_018_200_001
  @migration_module Letflow.Repo.Migrations.WidenTenantsScopeEnforcementCheck
  @migration_file "priv/repo/migrations/20261018200001_widen_tenants_scope_enforcement_check.exs"
  @constraint "tenants_scope_enforcement_check"
  @router Letflow.Routers.TenantScopeEnforcement

  defp store!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp write_raw(fx, value) do
    {:ok, id} = Ecto.UUID.dump(fx.tenant_id)
    Repo.query("UPDATE tenants SET scope_enforcement = $1 WHERE id = $2", [value, id])
  end

  defp attrs(reason), do: %{actor_id: nil, reason: reason, trace_id: nil}

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp migrate(scratch, direction) do
    Ecto.Migrator.run(Repo, [{@version, @migration_module}], direction,
      all: true,
      prefix: scratch,
      log: false
    )
  end

  defp definition(scratch) do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE c.conname = $1 AND n.nspname = $2 AND t.relname = 'tenants'",
        [@constraint, scratch]
      )

    definition
  end

  # ===========================================================================================
  describe "T-O1 the widened CHECK and the enum" do
    test "off, shadow and on are stored; ON, x and the empty string violate tenants_scope_enforcement_check" do
      fx = S.tenant!("r517-o1-check")

      for value <- ["off", "shadow", "on", "off"] do
        assert {:ok, %{num_rows: 1}} = write_raw(fx, value), value
        assert Atom.to_string(mode!(fx)) == value
      end

      for value <- ["ON", "On", "x", "", "enforce", "on "] do
        assert {:error, %Postgrex.Error{postgres: %{constraint: @constraint}}} =
                 write_raw(fx, value),
               inspect(value)

        assert mode!(fx) == :off
      end
    end

    test "the Tenant enum has the three values and reads an on row back as :on" do
      fx = S.tenant!("r517-o1-enum")

      assert Ecto.Enum.values(Tenant, :scope_enforcement) == [:off, :shadow, :on]
      assert ScopeEnforcement.stored_modes() == [:off, :shadow, :on]
      # the SETTABLE set is unchanged
      assert ScopeEnforcement.modes() == [:off, :shadow]

      store!(fx, :on)
      assert Repo.get!(Tenant, fx.tenant_id).scope_enforcement == :on
      assert mode!(fx) == :on
    end

    test "the live constraint definition lists the three values" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
            "WHERE conname = $1 AND conrelid = 'public.tenants'::regclass",
          [@constraint]
        )

      for value <- ["off", "shadow", "on"] do
        assert definition =~ "'#{value}'", definition
      end
    end
  end

  # ===========================================================================================
  describe "T-O1 the public migration on a scratch schema" do
    setup do
      # The migration is a public .exs (not in the tenant manifest), so it is not preloaded.
      unless Code.ensure_loaded?(@migration_module) do
        Code.require_file(Path.join(File.cwd!(), @migration_file))
      end

      # `provisioned_tenant!` puts the sandbox in :auto mode (real DDL) and gives a tenant row.
      fx = S.tenant!("r517-o1-mig")
      scratch = "req517_o1_scratch_#{System.unique_integer([:positive])}"

      Repo.query!(~s|CREATE SCHEMA "#{scratch}"|)
      Repo.query!(~s|CREATE TABLE "#{scratch}".tenants (LIKE public.tenants INCLUDING ALL)|)
      on_exit(fn -> Repo.query!(~s|DROP SCHEMA IF EXISTS "#{scratch}" CASCADE|) end)

      %{fx: fx, scratch: scratch}
    end

    test "up widens to three values; down restores two values when no tenant is on; up again restores three",
         %{scratch: scratch} do
      assert migrate(scratch, :up) == [@version]
      assert definition(scratch) =~ "'on'"

      assert migrate(scratch, :down) == [@version]
      definition = definition(scratch)
      assert definition =~ "'off'" and definition =~ "'shadow'"
      refute definition =~ "'on'"

      assert migrate(scratch, :up) == [@version]
      assert definition(scratch) =~ "'on'"
    end

    test "down RAISES while any tenant is stored on, naming the count and nothing else, and leaves the constraint widened",
         %{fx: fx, scratch: scratch} do
      assert migrate(scratch, :up) == [@version]
      store!(fx, :on)

      error = assert_raise RuntimeError, fn -> migrate(scratch, :down) end

      assert error.message =~
               ~r/rollback refused: \d+ tenant\(s\) are stored as on; flip them off first/

      refute error.message =~ fx.tenant_id
      refute error.message =~ fx.schema_name

      # nothing changed: still widened, version still recorded (a second down raises again)
      assert definition(scratch) =~ "'on'"
      assert_raise RuntimeError, fn -> migrate(scratch, :down) end

      # an operator flips the tenant off first; then the rollback goes through
      store!(fx, :off)
      assert migrate(scratch, :down) == [@version]
      refute definition(scratch) =~ "'on'"
    end
  end

  # ===========================================================================================
  describe "T-O2 nothing can set on" do
    test "parse_mode/1 rejects on in every spelling" do
      for value <- ["on", "ON", "On", " on", "enforce", "true", nil, :on, 1, %{}] do
        assert ScopeEnforcement.parse_mode(value) == {:error, :invalid_mode}, inspect(value)
      end

      assert ScopeEnforcement.parse_mode("off") == {:ok, :off}
      assert ScopeEnforcement.parse_mode("shadow") == {:ok, :shadow}
    end

    test "flip/4 to :on is {:error, :invalid_mode} from off and from shadow, and the column is unchanged (N6)" do
      fx = S.tenant!("r517-o2-flip")

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, attrs("try on")) ==
               {:error, :invalid_mode}

      assert mode!(fx) == :off

      assert {:ok, %{mode: :shadow}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(nil))

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, attrs("try on")) ==
               {:error, :invalid_mode}

      assert mode!(fx) == :shadow
      assert entries(fx, "scope.enforcement_enabled") |> length() == 1
    end

    test "PUT mode=on is 422 invalid_enforcement_mode for an off, a shadow and an on tenant, and changes nothing" do
      for stored <- [:off, :shadow, :on] do
        fx = S.tenant!("r517-o2-put-#{stored}")
        store!(fx, stored)

        for body <- [%{"mode" => "on"}, %{"mode" => "on", "reason" => "enable enforcement"}] do
          conn = S.as_admin(@router, :put, "/", fx, body)
          assert conn.status == 422, "#{stored}: #{conn.resp_body}"
          assert S.body(conn)["detail"] == "invalid_enforcement_mode"
        end

        assert mode!(fx) == stored
        assert entries(fx, "scope.enforcement_enabled") == []
        assert entries(fx, "scope.enforcement_disabled") == []
      end
    end
  end

  # ===========================================================================================
  describe "T-O4 the read side for an on tenant" do
    test "GET /tenant/scope-enforcement answers mode on with the unchanged available_modes" do
      fx = S.tenant!("r517-o4")
      store!(fx, :on)

      conn = S.as_admin(@router, :get, "/", fx, nil)

      assert conn.status == 200
      assert S.body(conn) == %{"mode" => "on", "available_modes" => ["off", "shadow"]}
    end

    test "get_mode/1 answers each stored value and an unknown tenant still errors" do
      fx = S.tenant!("r517-o4-get")

      for mode <- [:on, :shadow, :off] do
        store!(fx, mode)
        assert ScopeEnforcement.get_mode(fx.tenant_id) == {:ok, mode}
      end

      assert ScopeEnforcement.get_mode(Ecto.UUID.generate()) == {:error, :tenant_not_found}
    end
  end

  # ===========================================================================================
  describe "T-O5 the helper is test-only and only flip/4 casts the column" do
    @lib_files Path.wildcard("lib/**/*.ex")

    test "the fixture module lives under test/support and no lib/ file defines it" do
      assert Code.ensure_loaded?(ScopeEnforcementFixture)
      assert File.exists?("test/support/scope_enforcement_fixture.ex")

      offenders =
        for file <- @lib_files,
            File.read!(file) =~ "Letflow.Support.ScopeEnforcementFixture",
            do: file

      assert offenders == []
    end

    test "scope_enforcement_changeset( is called from lib/ only by scope_enforcement.ex (definition and docs in tenant.ex excluded)" do
      callers =
        for file <- @lib_files,
            Path.basename(file) != "tenant.ex",
            File.read!(file) =~ "scope_enforcement_changeset(",
            do: Path.relative_to_cwd(file) |> String.replace("\\", "/")

      assert callers == ["lib/letflow/scope_enforcement.ex"]
    end

    test "no other Tenant changeset casts scope_enforcement, on included" do
      tenant = %Tenant{scope_enforcement: :off}

      for value <- ["on", :on, "shadow"] do
        key_attrs = %{"scope_enforcement" => value}

        changesets = [
          Tenant.create_changeset(
            tenant,
            Map.merge(key_attrs, %{"slug" => "x", "display_name" => "x"}),
            :disabled
          ),
          Tenant.admin_patch_changeset(tenant, Map.merge(key_attrs, %{"display_name" => "y"})),
          Tenant.settings_changeset(tenant, Map.merge(key_attrs, %{"settings" => %{}})),
          Tenant.realm_bind_changeset(
            tenant,
            Map.merge(key_attrs, %{"idp_realm_id" => "realm-1"})
          ),
          Tenant.status_changeset(tenant, Map.merge(key_attrs, %{"status" => "active"}))
        ]

        for cs <- changesets do
          refute Map.has_key?(cs.changes, :scope_enforcement), inspect({value, cs.changes})
        end
      end
    end
  end

  # ===========================================================================================
  describe "T-O6 an on tenant can be flipped off" do
    test "flip(..., :off, reason) from a stored on succeeds with previous :on and writes the audit entry" do
      fx = S.tenant!("r517-o6")
      store!(fx, :on)

      assert {:ok, %{mode: :off, previous: :on, changed: true}} =
               ScopeEnforcement.flip(
                 fx.tenant_id,
                 fx.schema_name,
                 :off,
                 attrs("operator turned it off")
               )

      assert mode!(fx) == :off

      assert [entry] = entries(fx, "scope.enforcement_disabled")
      assert entry.before_state == %{"mode" => "on"}
      assert entry.after_state["mode"] == "off"
      assert entry.after_state["reason"] == "operator turned it off"
    end

    test "without a reason the flip off is refused and the tenant stays on" do
      fx = S.tenant!("r517-o6-noreason")
      store!(fx, :on)

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(nil)) ==
               {:error, :reason_required}

      assert mode!(fx) == :on
      assert entries(fx, "scope.enforcement_disabled") == []
    end

    test "PUT mode=off with a reason flips a stored on tenant back through the existing route" do
      fx = S.tenant!("r517-o6-put")
      store!(fx, :on)

      conn = S.as_admin(@router, :put, "/", fx, %{"mode" => "off", "reason" => "roll back"})

      assert conn.status == 200, conn.resp_body
      assert mode!(fx) == :off
      assert [_one] = entries(fx, "scope.enforcement_disabled")
    end
  end
end
