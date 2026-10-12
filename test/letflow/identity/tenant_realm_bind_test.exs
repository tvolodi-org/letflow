defmodule Letflow.Identity.TenantRealmBindTest do
  @moduledoc """
  ISS-1030 PR 1 -- `Letflow.Identity.bind_tenant_realm/3` (bind-once, row-locked)
  and `Letflow.Identity.Tenant.realm_bind_changeset/2`. Design:
  `lib/letflow/design/iss1030-onboarding-administrator.md` sections 3.2, 7a, 10.1.

  Real Postgres, real tenant schemas (`Letflow.TenantFixture`). The tenant chain
  is the fixture tenant's own schema; the platform chain is a second fixture
  tenant's schema. `async: false`: `TenantFixture` flips the sandbox to `:auto`.

  The concurrency test uses a lock-holder (a raw `SELECT ... FOR UPDATE` in an
  open transaction) and polls `pg_stat_activity` until BOTH binders are waiting
  on that lock, so the interleaving is forced and no sleep is involved.

  Status: WRITTEN, NOT YET RUN (see test/specs/ISS-1030-PR1.md).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind")
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-plat")
    %{tenant: tenant, platform: platform, actor_id: Ecto.UUID.generate()}
  end

  defp opts(ctx),
    do: [actor_id: ctx.actor_id, platform_prefix: ctx.platform.schema_name, trace_id: "t-1"]

  defp realm, do: Letflow.TenantSlugFixture.unique_realm("iss1030")

  defp entries(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp stored_realm(tenant_id), do: Repo.get!(Tenant, tenant_id).idp_realm_id

  test "bind_tenant_realm sets idp_realm_id only while it is NULL", ctx do
    first = realm()
    assert stored_realm(ctx.tenant.tenant_id) == nil

    assert {:ok, %Tenant{idp_realm_id: ^first}} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, first, opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == first

    # Same realm again: idempotent, no second audit entry in either chain.
    assert {:ok, %Tenant{idp_realm_id: ^first}} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, first, opts(ctx))

    assert length(entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")) == 1
    assert length(entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")) == 1

    # A different realm is refused and the tenant is unchanged.
    assert {:error, :realm_already_bound} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == first
    assert length(entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")) == 1
  end

  test "bind_tenant_realm audits a NIL actor in the tenant chain and the operator in the platform chain",
       ctx do
    bound = realm()
    assert {:ok, _tenant} = Identity.bind_tenant_realm(ctx.tenant.tenant_id, bound, opts(ctx))

    assert [tenant_entry] = entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")
    assert tenant_entry.actor_id == nil

    assert tenant_entry.after_state == %{
             "idp_realm_id" => bound,
             "actor_class" => "platform_operator"
           }

    refute inspect(tenant_entry) =~ ctx.actor_id

    assert [platform_entry] = entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")
    assert platform_entry.actor_id == ctx.actor_id
    assert platform_entry.after_state["tenant_id"] == ctx.tenant.tenant_id
    assert platform_entry.after_state["idp_realm_id"] == bound
  end

  test "bind_tenant_realm refuses a non-active tenant, an unknown tenant and a realm held elsewhere",
       ctx do
    for status <- [:migrating, :inactive] do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-status")
      {:ok, _} = other.tenant |> Tenant.status_changeset(%{status: status}) |> Repo.update()

      assert {:error, :tenant_not_active} =
               Identity.bind_tenant_realm(other.tenant_id, realm(), opts(ctx))

      assert stored_realm(other.tenant_id) == nil
      assert entries(other.schema_name, "tenant.idp_realm.bound") == []
    end

    assert {:error, :not_found} =
             Identity.bind_tenant_realm(Ecto.UUID.generate(), realm(), opts(ctx))

    held = realm()
    TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-held", idp_realm_id: held)

    assert {:error, :duplicate_realm} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, held, opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == nil
  end

  test "bind_tenant_realm without actor_id or platform_prefix writes nothing", ctx do
    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), platform_prefix: "x")

    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), actor_id: ctx.actor_id)

    assert stored_realm(ctx.tenant.tenant_id) == nil
  end

  test "realm bound: a forced failure of the platform write leaves idp_realm_id NULL and no tenant entry",
       ctx do
    # A platform prefix naming a schema that does not exist makes the second
    # audit write fail AFTER the tenant row and the tenant entry were written.
    bad = [
      actor_id: ctx.actor_id,
      platform_prefix: "tenant_00000000000000000000000000000000",
      trace_id: "t-2"
    ]

    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), bad)

    assert stored_realm(ctx.tenant.tenant_id) == nil
    assert entries(ctx.tenant.schema_name, "tenant.idp_realm.bound") == []
  end

  test "realm_bind_changeset casts nothing but idp_realm_id and rejects a malformed value", ctx do
    tenant = ctx.tenant.tenant

    cs =
      Tenant.realm_bind_changeset(tenant, %{
        "idp_realm_id" => "ok-realm",
        "slug" => "hijack",
        "status" => "inactive",
        "display_name" => "x"
      })

    assert cs.valid?
    assert Map.keys(cs.changes) == [:idp_realm_id]

    for bad <- ["", "a.b", "..", "a/b", "-x", "_x", "master", "Master", String.duplicate("a", 65)] do
      refute Tenant.realm_bind_changeset(tenant, %{"idp_realm_id" => bad}).valid?, bad
    end

    refute Tenant.realm_bind_changeset(tenant, %{}).valid?
  end

  test "no other changeset casts idp_realm_id on an existing tenant (structural)", ctx do
    tenant = ctx.tenant.tenant
    attrs = %{"idp_realm_id" => "smuggled", "idp_realm_id_" => "x"}

    changeset_funs =
      for {name, 2} <- Tenant.__info__(:functions),
          String.ends_with?(Atom.to_string(name), "_changeset"),
          name != :realm_bind_changeset,
          do: name

    assert changeset_funs != []

    for name <- changeset_funs do
      cs = apply(Tenant, name, [tenant, attrs])
      refute Map.has_key?(cs.changes, :idp_realm_id), "#{name} casts idp_realm_id"
    end

    # The bind-once changeset has exactly one production caller.
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "realm_bind_changeset("))
      |> Enum.sort()

    assert callers == ["lib/letflow/identity.ex", "lib/letflow/identity/tenant.ex"]
  end

  test "two concurrent bind_tenant_realm calls with different realms: exactly one wins and the loser gets realm_already_bound",
       ctx do
    parent = self()
    tenant_id = ctx.tenant.tenant_id
    realm_a = realm()
    realm_b = realm()

    # The holder owns the tenant row lock until released, so both binders are
    # guaranteed to be queued on it at the same time.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE"))
          send(parent, :row_locked)

          receive do
            :release -> :released
          end
        end)
      end)

    assert_receive :row_locked, 10_000

    binders =
      for realm_id <- [realm_a, realm_b] do
        Task.async(fn -> Identity.bind_tenant_realm(tenant_id, realm_id, opts(ctx)) end)
      end

    assert wait_for_lock_waiters(2, 10_000),
           "the two binders never both queued on the tenant row lock"

    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)

    results = Task.await_many(binders, 30_000)

    assert [{:ok, %Tenant{idp_realm_id: winner}}] =
             Enum.filter(results, &match?({:ok, %Tenant{}}, &1))

    assert winner in [realm_a, realm_b]
    assert Enum.count(results, &(&1 == {:error, :realm_already_bound})) == 1

    assert stored_realm(tenant_id) == winner
    assert length(entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")) == 1
    assert length(entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")) == 1
  end

  # True once `count` backends are blocked on a lock behind a `FOR UPDATE` read
  # of `tenants`. Polls through the repo (each poll is a round trip; no sleep).
  defp wait_for_lock_waiters(_count, 0), do: false

  defp wait_for_lock_waiters(count, attempts) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock' " <>
          "AND query ILIKE '%FOR UPDATE%' AND query ILIKE '%tenants%'",
        []
      )

    waiting >= count or wait_for_lock_waiters(count, attempts - 1)
  end

  test "realm_bind_changeset rejects a value with a trailing newline (the format check must not rely on a prior trim)",
       ctx do
    # `$` in a PCRE pattern also matches before a final "\n"; a stored realm
    # with a newline would never match a token's `iss` realm and would be
    # unbindable-yet-claimed.
    refute Tenant.realm_bind_changeset(ctx.tenant.tenant, %{"idp_realm_id" => "realm\n"}).valid?
    refute Tenant.realm_id_format?("realm\n")

    assert {:error, %Ecto.Changeset{}} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, "realm\n", opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == nil
  end
end
