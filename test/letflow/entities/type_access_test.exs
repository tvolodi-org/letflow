defmodule Letflow.Entities.TypeAccessTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.TypeAccess.authorized?/3` (REQ-394) --
  see `lib/letflow/design/req394-per-entity-type-authorization.md` §1 for
  the full design. Written by TEST-DESIGNER per REQ-394 AC5.

  Exercises the module's grant model directly (design §1.1) against a real
  Postgres tenant schema (`Letflow.DataCase`, no mocked database, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) rather than through
  the HTTP routes -- `test/letflow/routers/entities_test.exs`'s own REQ-394
  describe blocks cover the router-level `POST /entities/query` and
  definitions-read integration (AC1-AC4); this file covers `authorized?/3`
  as a unit in its own right (AC5).

  `async: false`: `TenantFixture.provisioned_tenant!/1` switches the sandbox
  to global `:auto` mode, same reason every other tenant-provisioning test
  in this codebase is `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.TypeAccess
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp tenant!(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-394 TypeAccess Test Tenant"
    )
  end

  defp insert_user!(schema_name, suffix) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req394-user-#{suffix}-#{Ecto.UUID.generate()}",
      display_name: "REQ-394 TypeAccess Test User",
      email: "req394-#{suffix}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp insert_type_restriction!(schema_name, entity_type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )
  end

  defp insert_type_grant!(schema_name, user_id, entity_type) do
    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- Letflow.Entities.TypeAccess.authorized?/3 unit coverage.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-394 AC5 -- default-allow: no entity_type_restrictions row at all" do
    test "a type with zero rows in entity_type_restrictions is {:ok, :allowed} for any user" do
      tenant = tenant!("req394-ta-default-allow")
      user = insert_user!(tenant.schema_name, "a")

      # No entity_type_restrictions row for "unrestricted_type" is ever
      # inserted -- the design's own "a tenant that never inserts a single
      # entity_type_restrictions row observes zero behavior change" claim
      # (design §1.1), exercised directly against the read-side function.
      assert TypeAccess.authorized?(user.id, "unrestricted_type", tenant.schema_name) ==
               {:ok, :allowed}
    end
  end

  describe "REQ-394 AC5 -- explicit restriction, no per-user override: denied" do
    test "a restricted type with no matching user_entity_type_grants row is {:ok, :denied}" do
      tenant = tenant!("req394-ta-denied")
      user = insert_user!(tenant.schema_name, "a")

      insert_type_restriction!(tenant.schema_name, "restricted_type")
      # Deliberately NO insert_type_grant!/3 call for this user -- absence
      # of the override row is exactly this user's denial (design §1.1).

      assert TypeAccess.authorized?(user.id, "restricted_type", tenant.schema_name) ==
               {:ok, :denied}
    end

    test "a restriction on one entity_type does not deny an unrelated, unrestricted entity_type" do
      tenant = tenant!("req394-ta-unrelated")
      user = insert_user!(tenant.schema_name, "a")

      insert_type_restriction!(tenant.schema_name, "restricted_type")

      assert TypeAccess.authorized?(user.id, "some_other_type", tenant.schema_name) ==
               {:ok, :allowed}
    end
  end

  describe "REQ-394 AC5 -- explicit restriction WITH a per-user override: allowed" do
    test "a restricted type with a matching user_entity_type_grants row is {:ok, :allowed}" do
      tenant = tenant!("req394-ta-granted")
      user = insert_user!(tenant.schema_name, "a")

      insert_type_restriction!(tenant.schema_name, "restricted_type")
      insert_type_grant!(tenant.schema_name, user.id, "restricted_type")

      assert TypeAccess.authorized?(user.id, "restricted_type", tenant.schema_name) ==
               {:ok, :allowed}
    end

    test "the grant is per-user -- a SECOND user with no grant row is still denied on the SAME restricted type" do
      tenant = tenant!("req394-ta-per-user")
      granted_user = insert_user!(tenant.schema_name, "granted")
      other_user = insert_user!(tenant.schema_name, "other")

      insert_type_restriction!(tenant.schema_name, "restricted_type")
      insert_type_grant!(tenant.schema_name, granted_user.id, "restricted_type")

      assert TypeAccess.authorized?(granted_user.id, "restricted_type", tenant.schema_name) ==
               {:ok, :allowed}

      assert TypeAccess.authorized?(other_user.id, "restricted_type", tenant.schema_name) ==
               {:ok, :denied}
    end
  end

  describe "REQ-394 AC5 -- tenant-scoping: a restriction/grant row in one tenant does not affect another" do
    test "a restriction row in tenant A leaves the SAME entity_type name allowed in tenant B" do
      tenant_a = tenant!("req394-ta-scope-a")
      tenant_b = tenant!("req394-ta-scope-b")

      # Same entity_type STRING in both tenants, same user's UUID reused
      # across both schemas (users are themselves tenant-scoped rows, per
      # REQ-063/REQ-064 -- the id namespace is not what isolates the two
      # tenants here, the SCHEMA is) -- this is exactly the shape that would
      # leak if `authorized?/3` ever queried without `prefix:`.
      user_a = insert_user!(tenant_a.schema_name, "a")
      user_b = insert_user!(tenant_b.schema_name, "b")

      insert_type_restriction!(tenant_a.schema_name, "shared_type_name")
      # Deliberately NOT restricted in tenant B.

      assert TypeAccess.authorized?(user_a.id, "shared_type_name", tenant_a.schema_name) ==
               {:ok, :denied}

      assert TypeAccess.authorized?(user_b.id, "shared_type_name", tenant_b.schema_name) ==
               {:ok, :allowed}
    end

    test "a grant row in tenant A does not lift the SAME entity_type's restriction in tenant B" do
      tenant_a = tenant!("req394-ta-scope-grant-a")
      tenant_b = tenant!("req394-ta-scope-grant-b")

      user_a = insert_user!(tenant_a.schema_name, "a")
      # Same user, inserted into BOTH tenant schemas as two independent rows
      # -- users are tenant-scoped, so "the same person" across tenants is,
      # deliberately, two unrelated rows with two unrelated ids in this
      # codebase. Re-using user_a.id as a raw UUID string against tenant B's
      # schema (where no such users row exists) is exactly the point: this
      # function keys purely on (user_id, entity_type) WITHIN the schema
      # named by `prefix`, and a grant minted in tenant A's schema must not
      # be visible when the same lookup runs with tenant B's prefix.
      insert_type_restriction!(tenant_a.schema_name, "cross_tenant_type")
      insert_type_grant!(tenant_a.schema_name, user_a.id, "cross_tenant_type")

      insert_type_restriction!(tenant_b.schema_name, "cross_tenant_type")
      # No grant inserted in tenant B for user_a.id.

      assert TypeAccess.authorized?(user_a.id, "cross_tenant_type", tenant_a.schema_name) ==
               {:ok, :allowed}

      assert TypeAccess.authorized?(user_a.id, "cross_tenant_type", tenant_b.schema_name) ==
               {:ok, :denied}
    end
  end

  describe "REQ-394 AC5 -- invalid tenant schema" do
    test "an unresolvable prefix returns {:error, :invalid_schema_name}, not a raised exception" do
      assert TypeAccess.authorized?(
               Ecto.UUID.generate(),
               "any_type",
               "tenant_definitely_does_not_exist_#{Ecto.UUID.generate() |> String.replace("-", "")}"
             ) == {:error, :invalid_schema_name}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Mutation check (fail-then-pass), performed this turn -- recorded in this
  # module's own describe block so it is discoverable alongside the tests
  # it validates. See the handoff report for the full transcript; this test
  # is the ordinary, permanent assertion left behind after the mutation was
  # reverted, not the mutation itself.
  # ═══════════════════════════════════════════════════════════════════════

  # ═══════════════════════════════════════════════════════════════════════
  # GH #2700 T-16 -- denied_types/3 (batch read; same rule as authorized?/3).
  # Spec: test/specs/GH2700-type-access.md
  # ═══════════════════════════════════════════════════════════════════════

  defp count_queries(fun) do
    id = "gh2700-ta-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:letflow, :repo, :query],
        fn _event, _m, _meta, _cfg -> if self() == parent, do: send(parent, :q) end,
        nil
      )

    try do
      result = fun.()
      {result, drain_count(0)}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_count(n) do
    receive do
      :q -> drain_count(n + 1)
    after
      0 -> n
    end
  end

  describe "GH #2700 T-16 -- denied_types/3" do
    test "empty input returns an empty set with ZERO queries (not even the tenant lookup)" do
      tenant = tenant!("gh2700-ta-empty")
      user = insert_user!(tenant.schema_name, "a")

      assert {{:ok, set}, 0} =
               count_queries(fn -> TypeAccess.denied_types(user.id, [], tenant.schema_name) end)

      assert MapSet.size(set) == 0
    end

    test "mixed fixture: restricted-ungranted denied; granted, unrestricted and nonexistent are not; agrees with authorized?/3 for every type" do
      tenant = tenant!("gh2700-ta-mixed")
      user = insert_user!(tenant.schema_name, "a")
      prefix = tenant.schema_name

      insert_type_restriction!(prefix, "r_denied")
      insert_type_restriction!(prefix, "r_granted")
      insert_type_grant!(prefix, user.id, "r_granted")

      # a restricted type granted to ANOTHER user only: still denied to `user`
      other = insert_user!(prefix, "b")
      insert_type_restriction!(prefix, "r_other_granted")
      insert_type_grant!(prefix, other.id, "r_other_granted")

      types = ["r_denied", "r_granted", "r_other_granted", "unrestricted", "never_defined"]

      assert {:ok, denied} = TypeAccess.denied_types(user.id, types, prefix)
      assert denied == MapSet.new(["r_denied", "r_other_granted"])

      for type <- types do
        {:ok, verdict} = TypeAccess.authorized?(user.id, type, prefix)
        assert verdict == :denied == MapSet.member?(denied, type), type
      end
    end

    test "another user's grant does not lift the denial for the caller" do
      tenant = tenant!("gh2700-ta-r2")
      caller = insert_user!(tenant.schema_name, "caller")
      other = insert_user!(tenant.schema_name, "other")
      prefix = tenant.schema_name

      insert_type_restriction!(prefix, "shared")
      insert_type_grant!(prefix, other.id, "shared")

      assert {:ok, set} = TypeAccess.denied_types(caller.id, ["shared"], prefix)
      assert set == MapSet.new(["shared"])
      assert {:ok, set} = TypeAccess.denied_types(other.id, ["shared"], prefix)
      assert MapSet.size(set) == 0
    end

    test "duplicate names in the input are de-duplicated" do
      tenant = tenant!("gh2700-ta-dup")
      user = insert_user!(tenant.schema_name, "a")
      insert_type_restriction!(tenant.schema_name, "dup_type")

      assert {:ok, set} =
               TypeAccess.denied_types(
                 user.id,
                 ["dup_type", "dup_type", "x", "dup_type"],
                 tenant.schema_name
               )

      assert set == MapSet.new(["dup_type"])
    end

    test "the query count is constant in the number of types (one batch read, not one per type)" do
      tenant = tenant!("gh2700-ta-count")
      user = insert_user!(tenant.schema_name, "a")
      prefix = tenant.schema_name

      names = for i <- 1..6, do: "ct_#{i}"
      Enum.each(names, &insert_type_restriction!(prefix, &1))

      # warm any tenant-id cache so both measurements see the steady state
      {:ok, _} = TypeAccess.denied_types(user.id, ["ct_1"], prefix)

      {{:ok, one}, one_q} =
        count_queries(fn -> TypeAccess.denied_types(user.id, ["ct_1"], prefix) end)

      {{:ok, six}, six_q} =
        count_queries(fn -> TypeAccess.denied_types(user.id, names, prefix) end)

      assert MapSet.size(one) == 1
      assert MapSet.size(six) == 6
      assert six_q == one_q
      assert six_q >= 1
    end

    test "names are bound parameters: quotes and SQL metacharacters are data, never SQL" do
      tenant = tenant!("gh2700-ta-bind")
      user = insert_user!(tenant.schema_name, "a")
      prefix = tenant.schema_name

      evil = ~s(o'brien"; DROP TABLE entity_type_restrictions; --)
      insert_type_restriction!(prefix, evil)

      assert {:ok, set} = TypeAccess.denied_types(user.id, [evil, "plain"], prefix)
      assert set == MapSet.new([evil])
      # the table survived
      assert {:ok, set} = TypeAccess.denied_types(user.id, [evil], prefix)
      assert MapSet.member?(set, evil)
    end

    test "an unresolvable prefix returns {:error, :invalid_schema_name} for non-empty input" do
      bogus =
        "tenant_definitely_does_not_exist_#{Ecto.UUID.generate() |> String.replace("-", "")}"

      assert TypeAccess.denied_types(Ecto.UUID.generate(), ["any"], bogus) ==
               {:error, :invalid_schema_name}
    end
  end

  describe "REQ-394 AC5 -- default-allow and denied are genuinely different outcomes" do
    test "the SAME entity_type name resolves differently depending solely on whether a restriction row exists" do
      tenant = tenant!("req394-ta-before-after")
      user = insert_user!(tenant.schema_name, "a")

      assert TypeAccess.authorized?(user.id, "toggle_type", tenant.schema_name) ==
               {:ok, :allowed}

      insert_type_restriction!(tenant.schema_name, "toggle_type")

      assert TypeAccess.authorized?(user.id, "toggle_type", tenant.schema_name) ==
               {:ok, :denied}
    end
  end
end
