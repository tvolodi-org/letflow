defmodule Letflow.ScopeEnforcementTest do
  @moduledoc """
  REQ-497 PR 1b / GH #2533, AC7 and AC16 at the function level: `Letflow.ScopeEnforcement`
  (`parse_mode/1`, `get_mode/1`, `preconditions/1`, `flip/4`, `integrity/1`) and the
  `Letflow.Identity.Tenant` changeset pin (design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` sections 3 and 8, section 18 rulings;
  spec `test/specs/REQ-497-1b.md`, T-F1 (parse), T-F4..T-F6c, T-F7, T-F9, T-F10, T-I1 (function)).

  Binding rulings pinned here: the flag accepts only `off | shadow` (`on` is unrepresentable,
  both in `parse_mode/1` and in the DB CHECK); turning it OFF needs a reason; the integrity
  finding `zero_tenant_wide_admins` is INFORMATIONAL and does not block off -> shadow.

  Every flip test uses a DEDICATED `TenantFixture.provisioned_tenant!/1` tenant: the pool
  snapshots `public.tenants`, so a flipped pooled tenant would be re-cloned. Bindings and holders
  come from `TokenMintFixture` (binding + tenant-wide group row, no T9 gap) unless a gap is the
  point (`RoleScopeGrantsFixture.raw_binding!/4`).

  `async: false`: committed writes, DDL (audit fault trigger), VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.Tenant
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @trace "6f1c2b9e-0497-4a11-8c20-0000000001b1"

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  # A dedicated tenant with one tenant-wide TENANT_ADMIN (binding + row via TokenMintFixture).
  defp admin_tenant!(slug_prefix) do
    fx = tenant!(slug_prefix)
    admin = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])
    Map.put(fx, :admin, admin)
  end

  # A dedicated tenant whose TENANT_ADMIN binding (with its tenant-wide row) has NO member and
  # no TA token: T9 clean, zero counted tenant-wide admins.
  defp zero_admin_tenant!(slug_prefix) do
    fx = tenant!(slug_prefix)
    former = RSG.user!(fx.schema_name)
    _ = TokenMintFixture.grant_roles!(fx.schema_name, former.id, ["TENANT_ADMIN"])

    {1, _} =
      Repo.delete_all(from(m in GroupMember, where: m.user_id == ^former.id),
        prefix: fx.schema_name
      )

    assert Letflow.Identity.count_tenant_wide_admins(fx.schema_name) == 0
    Map.put(fx, :former_admin, former)
  end

  defp attrs(fx, reason), do: %{actor_id: fx.admin.id, reason: reason, trace_id: @trace}

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp flip_entries(fx),
    do: entries(fx, "scope.enforcement_enabled") ++ entries(fx, "scope.enforcement_disabled")

  defp seconds_from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp raw_token!(schema, owner_id, roles, issuer_id) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      %ApiToken{
        user_id: owner_id,
        name: "req497-se-#{n}",
        token_hash: Base.encode16(:crypto.hash(:sha256, "req497-se-#{n}"), case: :lower),
        roles: roles,
        issuer_user_id: issuer_id,
        expires_at: nil
      },
      prefix: schema
    )
  end

  # An orphan scope node (parent segment has no row), seeded raw as the REQ-496 consistency
  # tests do: the tree is then `:inconsistent`.
  defp seed_orphan_node!(schema) do
    now = NaiveDateTime.utc_now()

    {2, _} =
      Repo.insert_all(
        "scope_node_paths",
        [
          %{node_id: "r", path: "/r/", depth: 1, inserted_at: now, updated_at: now},
          %{node_id: "o", path: "/ghost/o/", depth: 2, inserted_at: now, updated_at: now}
        ],
        prefix: schema
      )

    :ok
  end

  # A Postgres trigger on the tenant's audit_entries that raises for one action.
  defp with_audit_fault(fx, action, fun) do
    schema = fx.schema_name
    name = "req497_se_audit_fault"

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected audit fault (REQ-497 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    try do
      fun.()
    after
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end
  end

  # --- parse_mode/1, modes/0 (T-F1, function level) --------------------------------------------

  describe "T-F1 parse_mode/1" do
    test "accepts exactly \"off\" and \"shadow\"" do
      assert ScopeEnforcement.modes() == [:off, :shadow]
      assert ScopeEnforcement.parse_mode("off") == {:ok, :off}
      assert ScopeEnforcement.parse_mode("shadow") == {:ok, :shadow}
    end

    test "refuses on, ON, enforce, Off, padded values, nil, atoms and non-strings" do
      for value <- ["on", "ON", "enforce", "Off", " off", "shadow ", "", nil, :off, :on, 1, %{}] do
        assert ScopeEnforcement.parse_mode(value) == {:error, :invalid_mode}, inspect(value)
      end
    end

    test "flip/4 refuses a non-mode target before touching the database" do
      fx = admin_tenant!("req497-f1-fn")

      for target <- [:on, :enforce, "shadow", nil] do
        assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, target, attrs(fx, "r")) ==
                 {:error, :invalid_mode}
      end

      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end
  end

  # --- T-F7 --------------------------------------------------------------------------------------

  test "T-F7 every non-flag Tenant changeset drops scope_enforcement; only scope_enforcement_changeset/2 casts it" do
    tenant = %Tenant{scope_enforcement: :off}
    key_attrs = %{"scope_enforcement" => "shadow"}

    changesets = [
      Tenant.create_changeset(
        tenant,
        Map.merge(key_attrs, %{"slug" => "x", "display_name" => "x"}),
        :disabled
      ),
      Tenant.admin_patch_changeset(tenant, Map.merge(key_attrs, %{"display_name" => "y"})),
      Tenant.settings_changeset(tenant, Map.merge(key_attrs, %{"settings" => %{}})),
      Tenant.realm_bind_changeset(tenant, Map.merge(key_attrs, %{"idp_realm_id" => "realm-1"})),
      Tenant.status_changeset(tenant, Map.merge(key_attrs, %{"status" => "active"}))
    ]

    for cs <- changesets do
      refute Map.has_key?(cs.changes, :scope_enforcement), inspect(cs.changes)
    end

    flag_cs =
      Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: :shadow, display_name: "z"})

    assert flag_cs.changes == %{scope_enforcement: :shadow}

    # REQ-517 2b: `on` is a STORED value now (the flip still cannot set it, see parse_mode/1).
    assert Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: :on}).valid?
    refute Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: :bogus}).valid?
  end

  # --- preconditions/1 ---------------------------------------------------------------------------

  test "preconditions/1 on a clean writer-built tenant reports zero gaps, a consistent tree and no exceeding token" do
    fx = admin_tenant!("req497-pre-clean")

    assert ScopeEnforcement.preconditions(fx.schema_name) == %{
             bindings_without_row: 0,
             org_consistency: :ok,
             tokens_exceeding_owner: 0
           }
  end

  # --- flip/4 ------------------------------------------------------------------------------------

  describe "flip/4 off -> shadow" do
    test "T-F9 a clean tenant flips; exactly one scope.enforcement_enabled entry with the 3.3 states" do
      fx = admin_tenant!("req497-f9-on")

      assert {:ok, %{mode: :shadow, previous: :off, changed: true}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert mode!(fx) == :shadow
      assert [entry] = entries(fx, "scope.enforcement_enabled")
      assert entries(fx, "scope.enforcement_disabled") == []
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == @trace
      assert entry.resource_type == "tenant"
      assert entry.resource_id == fx.tenant_id
      assert entry.before_state == %{"mode" => "off"}

      assert entry.after_state == %{
               "mode" => "shadow",
               "reason" => nil,
               "preconditions" => %{
                 "bindings_without_row" => 0,
                 "org_consistency" => "ok",
                 "tokens_exceeding_owner" => 0
               }
             }
    end

    test "T-F4 a binding without a grant row refuses with [:bindings_without_row], mode off, no audit" do
      fx = admin_tenant!("req497-f4")
      g = RSG.fresh_group!(fx.schema_name)
      _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)

      assert {:error, {:precondition_failed, [:bindings_without_row], report}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert report == %{bindings_without_row: 1, org_consistency: :ok, tokens_exceeding_owner: 0}
      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end

    test "T-F5 an inconsistent scope_node_paths table refuses with [:org_inconsistent]" do
      fx = admin_tenant!("req497-f5")
      :ok = seed_orphan_node!(fx.schema_name)

      assert {:error, {:precondition_failed, [:org_inconsistent], report}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert report.org_consistency == :inconsistent
      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end

    test "T-F6 a token whose roles exceed its owner's tenant-wide roles refuses with [:tokens_exceed_owner]" do
      fx = admin_tenant!("req497-f6")
      owner = TokenMintFixture.role_holder!(fx.schema_name, ["PROCESS_DESIGNER"])
      _token = raw_token!(fx.schema_name, owner.id, ["PROCESS_DESIGNER"], fx.admin.id)

      # Control: compliant while the owner still holds the role.
      assert ScopeEnforcement.preconditions(fx.schema_name).tokens_exceeding_owner == 0

      # The owner is removed from the role's group after the mint.
      {1, _} =
        Repo.delete_all(
          from(m in GroupMember,
            where:
              m.user_id == ^owner.id and
                m.group_id == ^RSG.group_of!(fx.schema_name, "PROCESS_DESIGNER")
          ),
          prefix: fx.schema_name
        )

      assert {:error, {:precondition_failed, [:tokens_exceed_owner], report}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert report.tokens_exceeding_owner == 1
      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end

    test "T-F4..T-F6 all three facts are evaluated: the refusal names every failure" do
      fx = admin_tenant!("req497-f456")
      g = RSG.fresh_group!(fx.schema_name)
      _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
      :ok = seed_orphan_node!(fx.schema_name)
      lone = RSG.user!(fx.schema_name)
      _token = raw_token!(fx.schema_name, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)

      assert {:error,
              {:precondition_failed,
               [:bindings_without_row, :org_inconsistent, :tokens_exceed_owner], report}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert report == %{
               bindings_without_row: 1,
               org_consistency: :inconsistent,
               tokens_exceeding_owner: 1
             }

      assert mode!(fx) == :off
    end

    test "T-F6b a non-expiring PLATFORM_ADMIN token (platform tenant) alone does not block the flip" do
      p = tenant!("req497-f6b")
      :ok = Fixture.pin!(p.tenant_id)
      admin = TokenMintFixture.role_holder!(p.schema_name, ["TENANT_ADMIN", "PLATFORM_ADMIN"])
      _pa_token = raw_token!(p.schema_name, admin.id, ["PLATFORM_ADMIN"], admin.id)

      assert ScopeEnforcement.preconditions(p.schema_name).tokens_exceeding_owner == 0

      assert {:ok, %{mode: :shadow, changed: true}} =
               ScopeEnforcement.flip(p.tenant_id, p.schema_name, :shadow, %{
                 actor_id: admin.id,
                 reason: nil,
                 trace_id: @trace
               })
    end

    test "T-F6c a NULL-issuer token (create_token/3) alone does not block the flip" do
      fx = admin_tenant!("req497-f6c")
      owner = TokenMintFixture.role_holder!(fx.schema_name, ["PROCESS_DESIGNER"])

      {:ok, %{token: token}} =
        Letflow.Identity.create_token(
          owner.id,
          %{roles: ["PROCESS_DESIGNER"], expires_at: seconds_from_now(3_600)},
          prefix: fx.schema_name
        )

      assert is_nil(token.issuer_user_id)

      assert {:ok, %{mode: :shadow, changed: true}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))
    end

    test "supervisor ruling: a tenant with ZERO tenant-wide admins flips to shadow; integrity lists the finding" do
      fx = zero_admin_tenant!("req497-zero-flip")

      assert Letflow.Identity.RoleScopeGrants.bindings_without_row_count(fx.schema_name) == 0
      assert Letflow.Identity.count_tenant_wide_admins(fx.schema_name) == 0
      assert ScopeEnforcement.integrity(fx.schema_name).findings == [:zero_tenant_wide_admins]

      assert {:ok, %{mode: :shadow, previous: :off, changed: true}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, %{
                 actor_id: nil,
                 reason: nil,
                 trace_id: @trace
               })

      assert mode!(fx) == :shadow
    end

    test "T-F9 a forced audit failure rolls the flip back (same transaction): error, mode unchanged, no entry" do
      fx = admin_tenant!("req497-f9-fault")

      result =
        with_audit_fault(fx, "scope.enforcement_enabled", fn ->
          ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))
        end)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} = result
      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end
  end

  describe "flip/4 shadow -> off" do
    test "T-F8 a reason is required; an invalid reason is refused; a valid one is trimmed and audited" do
      fx = admin_tenant!("req497-f8")
      {:ok, _} = ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, nil)) ==
               {:error, :reason_required}

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, %{
               actor_id: fx.admin.id,
               trace_id: @trace
             }) == {:error, :reason_required}

      for bad <- ["", "   ", "two\nlines", "zero​width", String.duplicate("a", 501), 42] do
        assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, bad)) ==
                 {:error, :invalid_reason},
               inspect(bad)
      end

      assert mode!(fx) == :shadow
      assert entries(fx, "scope.enforcement_disabled") == []

      assert {:ok, %{mode: :off, previous: :shadow, changed: true}} =
               ScopeEnforcement.flip(
                 fx.tenant_id,
                 fx.schema_name,
                 :off,
                 attrs(fx, "  rollback after shadow review  ")
               )

      assert mode!(fx) == :off
      assert [entry] = entries(fx, "scope.enforcement_disabled")
      assert entry.before_state == %{"mode" => "shadow"}
      assert entry.after_state == %{"mode" => "off", "reason" => "rollback after shadow review"}
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == @trace
    end

    test "T-F8 an off flip is never blocked by a precondition" do
      fx = admin_tenant!("req497-f8-nopre")
      {:ok, _} = ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))
      g = RSG.fresh_group!(fx.schema_name)
      _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
      :ok = seed_orphan_node!(fx.schema_name)

      assert {:ok, %{mode: :off, changed: true}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, "gap found"))
    end

    test "SEC advisory 3 (pins CURRENT behaviour): off with no reason on an ALREADY-off tenant is reason_required, not an idempotent no-op" do
      fx = admin_tenant!("req497-sec3")

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, nil)) ==
               {:error, :reason_required}

      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end
  end

  describe "T-F10 same-mode flip" do
    test "returns changed: false, writes no audit and evaluates no precondition (a T9 gap does not refuse it)" do
      fx = admin_tenant!("req497-f10")
      {:ok, _} = ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil))
      before = flip_entries(fx)
      g = RSG.fresh_group!(fx.schema_name)
      _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :shadow, attrs(fx, nil)) ==
               {:ok, %{mode: :shadow, previous: :shadow, changed: false}}

      assert flip_entries(fx) == before
      assert mode!(fx) == :shadow

      # And off -> off with a reason is equally a no-op.
      {:ok, _} = ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, "back"))
      after_off = flip_entries(fx)

      assert ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :off, attrs(fx, "again")) ==
               {:ok, %{mode: :off, previous: :off, changed: false}}

      assert flip_entries(fx) == after_off
    end
  end

  describe "flip/4 server faults" do
    test "a prefix that is not the tenant's own schema is refused before any write" do
      a = admin_tenant!("req497-pfx-a")
      b = tenant!("req497-pfx-b")

      assert ScopeEnforcement.flip(a.tenant_id, b.schema_name, :shadow, attrs(a, nil)) ==
               {:error, :tenant_prefix_mismatch}

      assert mode!(a) == :off
      assert {:ok, :off} = ScopeEnforcement.get_mode(b.tenant_id)
    end

    test "an unknown tenant id is :tenant_not_found (get_mode/1 and flip/4)" do
      missing = Ecto.UUID.generate()
      {:ok, prefix} = Letflow.TenantProvisioning.schema_name_for_tenant(missing)

      assert ScopeEnforcement.get_mode(missing) == {:error, :tenant_not_found}
      assert ScopeEnforcement.get_mode("not-a-uuid") == {:error, :tenant_not_found}

      assert ScopeEnforcement.flip(missing, prefix, :shadow, %{
               actor_id: nil,
               reason: nil,
               trace_id: nil
             }) == {:error, :tenant_not_found}
    end
  end

  # --- integrity/1 (T-I1 function level, AC16) ---------------------------------------------------

  describe "T-I1 integrity/1" do
    test "a clean writer-built tenant with an admin: zero gaps, no orphans, no findings" do
      fx = admin_tenant!("req497-i1-clean")

      assert ScopeEnforcement.integrity(fx.schema_name) == %{
               bindings_without_row: 0,
               items: [],
               orphan_group_rows: 0,
               truncated: false,
               findings: []
             }
    end

    test "a seeded gap is listed with role id, name and group id; an orphan group row is counted" do
      fx = admin_tenant!("req497-i1-gap")
      g = RSG.fresh_group!(fx.schema_name)
      gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
      orphan_group = RSG.fresh_group!(fx.schema_name)
      :ok = RSG.raw_tenant_wide_row!(fx.schema_name, orphan_group.id, "TASK_WORKER")

      report = ScopeEnforcement.integrity(fx.schema_name)
      assert report.bindings_without_row == 1
      assert [item] = report.items
      assert item.role_id == gap.id
      assert item.name == "PROCESS_OPERATOR"
      assert item.group_id == g.id
      assert report.orphan_group_rows == 1
      assert report.truncated == false
      assert report.findings == []
    end

    test "zero_tenant_wide_admins is reported when no tenant-wide admin is counted (informational)" do
      fx = zero_admin_tenant!("req497-i1-zero")

      assert ScopeEnforcement.integrity(fx.schema_name).findings == [:zero_tenant_wide_admins]

      # A member that is counted clears it.
      _ = TokenMintFixture.grant_roles!(fx.schema_name, fx.former_admin.id, ["TENANT_ADMIN"])
      assert ScopeEnforcement.integrity(fx.schema_name).findings == []
    end
  end
end
