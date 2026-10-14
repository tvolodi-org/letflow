defmodule Letflow.Api.IdentityIdHardeningTest do
  @moduledoc """
  ISS-1032 (Q-1014 / GH #2317) and ISS-1033 (Q-1015 / GH #2318); design
  `lib/letflow/design/iss1032-1033-identity-id-and-bound-group-hardening.md` section 4.1 (T-01..T-34),
  spec `test/specs/ISS-1032-1033.md`.

  ISS-1032: `DELETE /groups/:id` of a MEMBERLESS group that a `tenant_role` row points to hit the
  `tenant_role.group_id` foreign key and answered 500. It is now a 409 with the fixed detail
  `group is bound to a role`.

  ISS-1033: every identity route that takes an id casts it first (`Identity.cast_id/1`); an uncastable
  id and an unknown id are the same zero-detail 404 (byte-identical), guards and fetches use the
  canonical id text.

  Real Postgres, real router (`Letflow.Routers.Identity.call/2`), platform tenant pinned on P.
  Callers: `TENANT_ADMIN` of P (no platform scope, the guard-triggering caller) and the operator
  (`PLATFORM_ADMIN` of P). Fixed (not generated) ids for the "unknown" cases so every byte compared is
  deterministic.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  import Ecto.Query, only: [from: 2]

  @admin ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  @unknown "0b1c2d3e-4f50-4a61-8b72-9c8d7e6f5a4b"
  @unknown_b "6f5e4d3c-2b1a-4098-a7b6-c5d4e3f2a1b0"

  @conflict_detail "group is bound to a role"

  # --- ISS-1042 pooled tenant (design iss1042-pooled-tenant-fixture.md 6.2 adopter audit) ---------
  # Spawned/un-awaited processes (item 1): none -- no Task, spawn, start_supervised or GenServer
  #   in this module or in PlatformTenantFixture's two_tenants!/three_tenants!/pin!/router_conn.
  # lib/ fire-and-forget workers (item 2): none reachable -- only Letflow.Routers.Identity and
  #   Letflow.Identity.* are called; Alerts, LoginDiscovery.Dispatch and retention are not.
  # In-memory tenant-keyed state (item 3): ETS / telemetry / Admission: none touched (no api_conn,
  #   no mint_token!, no bearer token); Application env: the platform pin, restored by the
  #   fixture's own per-test on_exit.
  # T-12b commits a CREATE TABLE into slot P; the pool sees the definition drift and rebuilds it.
  setup_all context do
    Letflow.TenantFixture.start_pool!(context,
      slots: [[slug_prefix: "scope-a"], [slug_prefix: "scope-b"], [slug_prefix: "scope-p"]]
    )
  end

  # MUST stay the module's first setup (before anything that provisions a tenant).
  setup context do
    Letflow.TenantFixture.attach_pool!(context)
  end

  # --- helpers (copied from platform_escalation_guard_test.exs, test/support is not extended) -------

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp call(method, path, fixture, roles, body) do
    Letflow.Routers.Identity.call(
      Fixture.router_conn(method, path, fixture, roles, body),
      Letflow.Routers.Identity.init([])
    )
  end

  defp opts(fixture), do: [prefix: fixture.schema_name]

  defp insert_user!(fixture) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss1033-#{Ecto.UUID.generate()}",
      display_name: "ISS-1033 User",
      email: "iss1033-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp insert_group!(fixture) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "iss1033-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp add_member!(fixture, group, user) do
    {:ok, _} = Identity.add_group_member(group.id, user.id, opts(fixture))
    :ok
  end

  # a group bound (by BINDING) to `name` with `kind`; NO members (memberless)
  defp bind_group!(fixture, name, kind) do
    group = insert_group!(fixture)
    {:ok, _role} = RoleRegistry.upsert_role(name, kind, group.id, opts(fixture))
    group
  end

  defp bound_group!(fixture), do: bind_group!(fixture, "PLATFORM_ADMIN", :platform_role)

  # the platform world: the PLATFORM_ADMIN-bound group with one operator member
  defp world!(ctx) do
    group = bound_group!(ctx.p)
    operator = insert_user!(ctx.p)
    add_member!(ctx.p, group, operator)
    %{group: group, operator: operator}
  end

  defp member_ids(fixture, group) do
    from(m in GroupMember, where: m.group_id == ^group.id, select: m.user_id)
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.sort()
  end

  defp group_exists?(fixture, group),
    do: Repo.get(Group, group.id, prefix: fixture.schema_name) != nil

  defp role_rows(fixture) do
    TenantRole
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.map(&{&1.name, &1.kind, &1.group_id})
    |> Enum.sort()
  end

  defp user_row(fixture, user) do
    reloaded = Repo.get!(User, user.id, prefix: fixture.schema_name)
    {reloaded.display_name, reloaded.status}
  end

  defp token_row(fixture, token_id) do
    t = Repo.get!(ApiToken, token_id, prefix: fixture.schema_name)
    {t.revoked_at, t.roles}
  end

  # everything a refused / unknown-id request must leave untouched
  defp snapshot(fixture) do
    p = fixture.schema_name

    %{
      groups: Repo.all(from(g in Group, select: g.id, order_by: g.id), prefix: p),
      members:
        Repo.all(
          from(m in GroupMember,
            select: {m.group_id, m.user_id},
            order_by: [m.group_id, m.user_id]
          ),
          prefix: p
        ),
      roles: role_rows(fixture),
      users:
        Repo.all(from(u in User, select: {u.id, u.display_name, u.status}, order_by: u.id),
          prefix: p
        ),
      tokens:
        Repo.all(from(t in ApiToken, select: {t.id, t.revoked_at, t.roles}, order_by: t.id),
          prefix: p
        ),
      audit: Repo.aggregate(Entry, :count, prefix: p),
      directory: Repo.aggregate(TenantLoginDirectoryEntry, :count)
    }
  end

  # percent-encode EVERY byte, upper-case or lower-case hex digits
  defp pct(bin, case_fun) do
    for <<byte <- bin>>, into: "", do: "%" <> case_fun.(Base.encode16(<<byte>>))
  end

  # Every spelling of `uuid` that Ecto.UUID.cast/1 accepts, as a PATH SEGMENT.
  defp spellings(uuid) do
    {:ok, raw} = Ecto.UUID.dump(uuid)

    [
      {"canonical lower-case", uuid},
      {"upper-case hyphenated", String.upcase(uuid)},
      {"mixed-case hyphenated", mixed_case(uuid)},
      {"raw 16 bytes, %XX upper-case hex", pct(raw, &String.upcase/1)},
      {"raw 16 bytes, %xx lower-case hex", pct(raw, &String.downcase/1)},
      {"canonical text, every char percent-encoded", pct(uuid, &String.upcase/1)}
    ]
  end

  defp mixed_case(uuid) do
    uuid
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn {c, i} -> if rem(i, 2) == 0, do: String.upcase(c), else: c end)
  end

  # path segments Ecto.UUID.cast/1 REJECTS (design 4.1 malformed set)
  defp malformed(uuid) do
    {:ok, raw} = Ecto.UUID.dump(uuid)

    [
      {"not-a-uuid", "not-a-uuid"},
      {"leading space", "%20" <> uuid},
      {"trailing space", uuid <> "%20"},
      {"hyphenless", String.replace(uuid, "-", "")},
      {"truncated to 35 chars", String.slice(uuid, 0, 35)},
      {"doubled", uuid <> uuid},
      {"17 raw bytes", pct(raw <> <<171>>, &String.upcase/1)},
      {"single char", "x"}
    ]
  end

  defp variants(uuid), do: spellings(uuid) ++ malformed(uuid)

  # a request body carries the DECODED value of a path-segment spelling
  defp body_value(segment), do: URI.decode(segment)

  defp assert_forbidden(conn, label) do
    assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["detail"] =~ "insufficient permissions", label
    refute conn.resp_body =~ ~r/platform.?admin/i, label
  end

  # `ref` is the answer for a plain unknown canonical id; every variant must be those exact bytes
  defp assert_all_unknown_404(ref, variants, fun) do
    assert ref.status == 404, "reference: #{ref.status} #{ref.resp_body}"

    for {label, segment} <- variants do
      conn = fun.(segment)
      assert conn.status == 404, "#{label}: #{conn.status} #{conn.resp_body}"
      assert conn.resp_body == ref.resp_body, "#{label}: the 404 bytes differ from an unknown id"
    end

    :ok
  end

  defp callers, do: [{"TENANT_ADMIN of P", @admin}, {"platform operator", @operator}]

  # --- sanity: the tables are what we claim -----------------------------------------------------------

  describe "the spelling tables themselves" do
    test "every cast-accepted spelling casts to the uuid, every malformed one is rejected" do
      for {label, segment} <- spellings(@unknown) do
        assert {:ok, @unknown} = Ecto.UUID.cast(body_value(segment)), label
      end

      for {label, segment} <- malformed(@unknown) do
        assert :error == Ecto.UUID.cast(body_value(segment)), label
      end
    end
  end

  # --- ISS-1032 ------------------------------------------------------------------------------------------

  describe "ISS-1032: DELETE /groups/:id on a role-bound group" do
    test "T-01 operator on the PLATFORM_ADMIN-bound group (memberless): 409 with the fixed problem body, group and binding intact",
         ctx do
      group = bound_group!(ctx.p)
      before = snapshot(ctx.p)

      conn = call(:delete, "/groups/#{group.id}", ctx.p, @operator, nil)

      assert conn.status == 409, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] == @conflict_detail
      assert body["status"] == 409
      assert group_exists?(ctx.p, group)
      assert {"PLATFORM_ADMIN", :platform_role, group.id} in role_rows(ctx.p)
      assert snapshot(ctx.p) == before
    end

    test "T-02 TENANT_ADMIN on a group bound to a platform_role other than PLATFORM_ADMIN: 409",
         ctx do
      group = bind_group!(ctx.p, "TENANT_ADMIN", :platform_role)

      conn = call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil)

      assert conn.status == 409, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == @conflict_detail
      assert group_exists?(ctx.p, group)
    end

    test "T-03 TENANT_ADMIN on a group bound to a process_routing_role: 409 (any kind counts)",
         ctx do
      group = bind_group!(ctx.p, "ROUTE_BOUND_ONE", :process_routing_role)

      conn = call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil)

      assert conn.status == 409, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == @conflict_detail
      assert group_exists?(ctx.p, group)
      assert {"ROUTE_BOUND_ONE", :process_routing_role, group.id} in role_rows(ctx.p)
    end

    test "T-04 the 409 body is exactly the standard problem document and leaks no id, role name, kind or database text",
         ctx do
      platform_group = bound_group!(ctx.p)
      routing_group = bind_group!(ctx.p, "ROUTE_LEAK_CHECK", :process_routing_role)

      for {group, roles, role_name, kind} <- [
            {platform_group, @operator, "PLATFORM_ADMIN", "platform_role"},
            {routing_group, @admin, "ROUTE_LEAK_CHECK", "process_routing_role"}
          ] do
        conn = call(:delete, "/groups/#{group.id}", ctx.p, roles, nil)
        assert conn.status == 409, conn.resp_body

        body = Jason.decode!(conn.resp_body)
        assert Enum.sort(Map.keys(body)) == ["detail", "status", "title", "trace_id", "type"]
        assert body["type"] =~ ~r{/conflict$}
        assert body["title"] == "Conflict"
        assert body["status"] == 409
        assert body["detail"] == @conflict_detail
        assert body["trace_id"] == "platform-scope-test-trace-id"

        haystack = String.downcase(conn.resp_body)

        for forbidden <- [
              group.id,
              role_name,
              kind,
              "tenant_role",
              "fkey",
              "postgrex",
              "constraint",
              "foreign",
              "violat",
              "stack",
              "ecto"
            ] do
          refute haystack =~ String.downcase(forbidden),
                 "the 409 body contains #{inspect(forbidden)}"
        end
      end
    end

    test "T-05 TENANT_ADMIN of P on the PLATFORM_ADMIN-bound group is the fixed 403 (never 409) for all six id spellings, group intact",
         ctx do
      group = bound_group!(ctx.p)
      before = snapshot(ctx.p)

      for {label, segment} <- spellings(group.id) do
        conn = call(:delete, "/groups/#{segment}", ctx.p, @admin, nil)
        assert_forbidden(conn, "delete bound group, #{label}")
        assert group_exists?(ctx.p, group)
      end

      assert snapshot(ctx.p) == before

      # control: the operator on the very same id reaches the real row (409, not 403 / 404)
      assert call(:delete, "/groups/#{group.id}", ctx.p, @operator, nil).status == 409
    end

    test "T-06 an unbound empty group: 204 and the row is gone (unchanged)", ctx do
      group = insert_group!(ctx.p)

      conn = call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil)

      assert conn.status == 204, conn.resp_body
      refute group_exists?(ctx.p, group)
    end

    test "T-07 an unbound group with a member: the same 404 bytes as a nonexistent group, row survives (REQ-074 AC5)",
         ctx do
      group = insert_group!(ctx.p)
      user = insert_user!(ctx.p)
      add_member!(ctx.p, group, user)

      ref = call(:delete, "/groups/#{@unknown}", ctx.p, @admin, nil)
      conn = call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil)

      assert ref.status == 404
      assert conn.status == 404, conn.resp_body
      assert conn.resp_body == ref.resp_body
      assert group_exists?(ctx.p, group)
      assert member_ids(ctx.p, group) == [user.id]
    end

    test "T-08 a bound group WITH a member: the same unified 404 as a nonexistent group, nothing deleted (NOT EXISTS stops before the FK)",
         ctx do
      group = bind_group!(ctx.p, "TENANT_ADMIN", :platform_role)
      user = insert_user!(ctx.p)
      add_member!(ctx.p, group, user)
      before = snapshot(ctx.p)

      ref = call(:delete, "/groups/#{@unknown}", ctx.p, @admin, nil)
      conn = call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil)

      assert conn.status == 404, conn.resp_body
      assert conn.resp_body == ref.resp_body
      assert snapshot(ctx.p) == before
    end

    test "T-09 a group whose binding was moved to another group deletes (204)", ctx do
      old = bound_group!(ctx.p)
      new = insert_group!(ctx.p)

      # GH 2524: moving a binding is the explicit rebind (upsert_role/4 refuses it).
      [%{id: role_id}] = Enum.filter(RoleRegistry.list_roles(opts(ctx.p)), &(&1.name == "PLATFORM_ADMIN"))

      {:ok, _} =
        RoleRegistry.rebind_role(
          role_id,
          new.id,
          %{actor_id: nil, reason: "test: move the operator binding"},
          Keyword.put(opts(ctx.p), :platform_scope, true)
        )

      # the old group is no longer bound, so it is an ordinary empty group
      conn = call(:delete, "/groups/#{old.id}", ctx.p, @admin, nil)

      assert conn.status == 204, conn.resp_body
      refute group_exists?(ctx.p, old)
      assert {"PLATFORM_ADMIN", :platform_role, new.id} in role_rows(ctx.p)

      # and the new bound group is now the refused one
      assert call(:delete, "/groups/#{new.id}", ctx.p, @operator, nil).status == 409
    end

    test "T-10 a refused delete writes no audit row and changes no groups, group_members, tenant_role, users, tokens or directory row",
         ctx do
      platform_group = bound_group!(ctx.p)
      routing_group = bind_group!(ctx.p, "ROUTE_NO_AUDIT", :process_routing_role)
      with_member = insert_group!(ctx.p)
      add_member!(ctx.p, with_member, insert_user!(ctx.p))
      before = snapshot(ctx.p)

      refusals = [
        {409, platform_group.id, @operator},
        {409, routing_group.id, @admin},
        {403, platform_group.id, @admin},
        {404, with_member.id, @admin},
        {404, @unknown, @admin},
        {404, "not-a-uuid", @admin}
      ]

      for {status, id, roles} <- refusals do
        conn = call(:delete, "/groups/#{id}", ctx.p, roles, nil)
        assert conn.status == status, "#{id}: #{conn.status} #{conn.resp_body}"
      end

      assert snapshot(ctx.p) == before
    end

    test "T-11 Identity.delete_group/2 returns {:error, :bound_to_role} for a memberless bound group and does not raise",
         ctx do
      group = bound_group!(ctx.p)

      assert {:error, :bound_to_role} = Identity.delete_group(group.id, opts(ctx.p))
      assert group_exists?(ctx.p, group)

      # the same call on an ordinary empty group still deletes, on the same connection (no aborted transaction)
      other = insert_group!(ctx.p)
      assert :ok = Identity.delete_group(other.id, opts(ctx.p))
    end

    test "T-12 the FK constraint name the mapping depends on is real (tenant_role_group_id_fkey)",
         ctx do
      group = bound_group!(ctx.p)

      error =
        try do
          Repo.delete_all(from(g in Group, where: g.id == ^group.id), prefix: ctx.p.schema_name)
          nil
        rescue
          e in Postgrex.Error -> e
        end

      assert %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: constraint}} =
               error

      assert constraint == "tenant_role_group_id_fkey"
    end

    test "T-12b a foreign key violation from ANOTHER table is re-raised, not mapped to :bound_to_role",
         ctx do
      # a second table referencing groups, created inside the sandbox transaction (DDL rolls back)
      schema = ctx.p.schema_name

      Repo.query!(
        ~s|CREATE TABLE "#{schema}".zz_probe (group_id uuid REFERENCES "#{schema}".groups(id))|
      )

      group = insert_group!(ctx.p)
      {:ok, raw} = Ecto.UUID.dump(group.id)
      Repo.query!(~s|INSERT INTO "#{schema}".zz_probe VALUES ($1)|, [raw])

      error =
        try do
          Identity.delete_group(group.id, opts(ctx.p))
          nil
        rescue
          e in Postgrex.Error -> e
        end

      assert %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: constraint}} =
               error

      assert constraint == "zz_probe_group_id_fkey"
    end

    test "T-12c the probe table of T-12b never leaks out of the sandbox transaction" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_schema FROM information_schema.tables WHERE table_name = 'zz_probe'"
        )

      assert rows == []
    end
  end

  # --- ISS-1033: helper ----------------------------------------------------------------------------------

  describe "ISS-1033: id cast helper" do
    test "T-13 Identity.cast_id/1 returns the canonical lower-case text for canonical, upper-case, mixed-case and raw 16-byte input" do
      {:ok, raw} = Ecto.UUID.dump(@unknown)
      assert byte_size(raw) == 16

      for input <- [@unknown, String.upcase(@unknown), mixed_case(@unknown), raw] do
        assert {:ok, @unknown} = Identity.cast_id(input)
      end
    end

    test "T-14 Identity.cast_id/1 returns :error for malformed strings, a 17-byte binary, nil, an integer and a map" do
      {:ok, raw} = Ecto.UUID.dump(@unknown)

      for input <-
            [raw <> <<171>>, nil, 42, %{"id" => @unknown}, ""] ++
              Enum.map(malformed(@unknown), fn {_, segment} -> body_value(segment) end) do
        assert :error == Identity.cast_id(input), inspect(input)
      end
    end
  end

  # --- ISS-1033: users -----------------------------------------------------------------------------------

  describe "ISS-1033: users (PATCH /users/:id, POST /users/:id/status, GET /users/:id)" do
    test "T-15 PATCH: a nonexistent id answers the plain unknown-id 404 bytes for every spelling and malformed variant, for both callers",
         ctx do
      world!(ctx)
      body = %{"display_name" => "x"}

      for {_who, roles} <- callers() do
        ref = call(:patch, "/users/#{@unknown}", ctx.p, roles, body)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:patch, "/users/#{segment}", ctx.p, roles, body)
        end)
      end
    end

    test "T-16 STATUS: a nonexistent id answers the plain unknown-id 404 bytes for every spelling and malformed variant, for both callers",
         ctx do
      world!(ctx)
      body = %{"status" => "inactive"}

      for {_who, roles} <- callers() do
        ref = call(:post, "/users/#{@unknown}/status", ctx.p, roles, body)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:post, "/users/#{segment}/status", ctx.p, roles, body)
        end)
      end
    end

    test "T-17 GET /users/:id: raw-byte and malformed ids answer the same 404 as an unknown id (was 500)",
         ctx do
      for {_who, roles} <- callers() do
        ref = call(:get, "/users/#{@unknown}", ctx.p, roles, nil)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:get, "/users/#{segment}", ctx.p, roles, nil)
        end)
      end
    end

    test "T-18 PATCH and STATUS on a nonexistent id write nothing: no user row, no audit row, no login-directory change",
         ctx do
      world!(ctx)
      before = snapshot(ctx.p)

      for {_who, roles} <- callers(), {_label, segment} <- variants(@unknown) do
        call(:patch, "/users/#{segment}", ctx.p, roles, %{"display_name" => "ghost"})
        call(:post, "/users/#{segment}/status", ctx.p, roles, %{"status" => "inactive"})
      end

      assert snapshot(ctx.p) == before
    end

    test "T-19 operator user: 403 for TENANT_ADMIN on every spelling, 200 for the operator on every spelling",
         ctx do
      %{operator: operator} = world!(ctx)

      for {label, segment} <- spellings(operator.id) do
        before = user_row(ctx.p, operator)

        patch = call(:patch, "/users/#{segment}", ctx.p, @admin, %{"display_name" => "pwned"})
        assert_forbidden(patch, "PATCH, #{label}")

        status = call(:post, "/users/#{segment}/status", ctx.p, @admin, %{"status" => "inactive"})
        assert_forbidden(status, "STATUS, #{label}")

        assert user_row(ctx.p, operator) == before, "#{label}: the operator was modified"

        # the operator control: the SAME spelling resolves to the real row (non-vacuous denial)
        conn =
          call(:patch, "/users/#{segment}", ctx.p, @operator, %{"display_name" => "ctl-#{label}"})

        assert conn.status == 200, "control PATCH, #{label}: #{conn.status} #{conn.resp_body}"
        assert {"ctl-" <> ^label, :active} = user_row(ctx.p, operator)

        conn =
          call(:post, "/users/#{segment}/status", ctx.p, @operator, %{"status" => "inactive"})

        assert conn.status == 200, "control STATUS, #{label}: #{conn.status} #{conn.resp_body}"
        assert {_, :inactive} = user_row(ctx.p, operator)

        {1, _} =
          Repo.update_all(from(u in User, where: u.id == ^operator.id), [set: [status: :active]],
            prefix: ctx.p.schema_name
          )
      end
    end

    test "T-20 an existing ordinary member is still 2xx for the TENANT_ADMIN for every spelling (the guard is not over-broad)",
         ctx do
      world!(ctx)
      ordinary_group = insert_group!(ctx.p)
      member = insert_user!(ctx.p)
      add_member!(ctx.p, ordinary_group, member)

      for {label, segment} <- spellings(member.id) do
        conn = call(:patch, "/users/#{segment}", ctx.p, @admin, %{"display_name" => "r-#{label}"})
        assert conn.status == 200, "PATCH, #{label}: #{conn.status} #{conn.resp_body}"
        assert {"r-" <> ^label, :active} = user_row(ctx.p, member)

        conn = call(:post, "/users/#{segment}/status", ctx.p, @admin, %{"status" => "inactive"})
        assert conn.status == 200, "STATUS, #{label}: #{conn.status} #{conn.resp_body}"
        assert {_, :inactive} = user_row(ctx.p, member)

        conn = call(:get, "/users/#{segment}", ctx.p, @admin, nil)
        assert conn.status == 200, "GET, #{label}: #{conn.status}"
        assert Jason.decode!(conn.resp_body)["id"] == member.id

        {1, _} =
          Repo.update_all(from(u in User, where: u.id == ^member.id), [set: [status: :active]],
            prefix: ctx.p.schema_name
          )
      end
    end
  end

  # --- ISS-1033: groups and group members ----------------------------------------------------------------

  describe "ISS-1033: groups and group members" do
    test "T-21 DELETE /groups/:id: nonexistent and malformed ids answer the plain unknown-group 404 bytes for every variant, both callers",
         ctx do
      world!(ctx)
      before = snapshot(ctx.p)

      for {_who, roles} <- callers() do
        ref = call(:delete, "/groups/#{@unknown}", ctx.p, roles, nil)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:delete, "/groups/#{segment}", ctx.p, roles, nil)
        end)
      end

      assert snapshot(ctx.p) == before
    end

    test "T-22 POST /groups/:id/members: nonexistent and malformed group ids answer the unknown-group 404 bytes (valid body)",
         ctx do
      world!(ctx)
      user = insert_user!(ctx.p)
      body = %{"user_id" => user.id}
      before = snapshot(ctx.p)

      for {_who, roles} <- callers() do
        ref = call(:post, "/groups/#{@unknown}/members", ctx.p, roles, body)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:post, "/groups/#{segment}/members", ctx.p, roles, body)
        end)
      end

      assert snapshot(ctx.p) == before
    end

    test "T-23 POST members: a malformed or unknown body user_id is the unknown-user 404; cast runs after guard and validation",
         ctx do
      %{group: bound} = world!(ctx)
      group = insert_group!(ctx.p)
      before = snapshot(ctx.p)

      for {_who, roles} <- callers() do
        ref = call(:post, "/groups/#{group.id}/members", ctx.p, roles, %{"user_id" => @unknown})
        assert ref.status == 404

        for {label, segment} <- variants(@unknown), form <- ["user_id", "user_ids"] do
          value = body_value(segment)
          body = if form == "user_id", do: %{"user_id" => value}, else: %{"user_ids" => [value]}

          conn = call(:post, "/groups/#{group.id}/members", ctx.p, roles, body)
          assert conn.status == 404, "#{form} #{label}: #{conn.status} #{conn.resp_body}"

          assert conn.resp_body == ref.resp_body,
                 "#{form} #{label}: bytes differ from unknown user"
        end
      end

      assert snapshot(ctx.p) == before

      # order: the group guard (403) beats the body-id cast (404) on the bound group
      for {label, segment} <- malformed(@unknown) do
        conn =
          call(:post, "/groups/#{bound.id}/members", ctx.p, @admin, %{
            "user_id" => body_value(segment)
          })

        assert_forbidden(conn, "bound group, malformed body id, #{label}")
      end

      # order: body validation (422) beats the body-id cast (404) on an ordinary group
      conn = call(:post, "/groups/#{group.id}/members", ctx.p, @admin, %{})
      assert conn.status == 422, conn.resp_body

      conn = call(:post, "/groups/#{group.id}/members", ctx.p, @admin, %{"user_id" => 12})
      assert conn.status == 422, conn.resp_body
    end

    test "T-24 DELETE /groups/:id/members/:user_id: nonexistent and malformed GROUP ids answer the unknown-group 404 bytes",
         ctx do
      %{operator: operator} = world!(ctx)

      for {_who, roles} <- callers() do
        ref = call(:delete, "/groups/#{@unknown}/members/#{operator.id}", ctx.p, roles, nil)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:delete, "/groups/#{segment}/members/#{operator.id}", ctx.p, roles, nil)
        end)
      end
    end

    test "T-25 DELETE member: malformed user id is 404, unknown well-formed user id is still 204",
         ctx do
      world!(ctx)
      group = insert_group!(ctx.p)
      member = insert_user!(ctx.p)
      add_member!(ctx.p, group, member)

      ref_404 = call(:delete, "/groups/#{@unknown}/members/#{member.id}", ctx.p, @admin, nil)
      assert ref_404.status == 404

      for {label, segment} <- malformed(@unknown) do
        conn = call(:delete, "/groups/#{group.id}/members/#{segment}", ctx.p, @admin, nil)
        assert conn.status == 404, "#{label}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body == ref_404.resp_body, "#{label}: bytes differ"
      end

      for {label, segment} <- spellings(@unknown_b) do
        conn = call(:delete, "/groups/#{group.id}/members/#{segment}", ctx.p, @admin, nil)
        assert conn.status == 204, "unknown user, #{label}: #{conn.status} #{conn.resp_body}"
      end

      assert member_ids(ctx.p, group) == [member.id]
    end

    test "T-26 DELETE member on the bound group: 403 for every spelling; malformed ids are 404 (cast before guard)",
         ctx do
      %{group: group, operator: operator} = world!(ctx)
      ref_404 = call(:delete, "/groups/#{@unknown}/members/#{operator.id}", ctx.p, @admin, nil)

      for {label, segment} <- spellings(group.id) do
        conn = call(:delete, "/groups/#{segment}/members/#{operator.id}", ctx.p, @admin, nil)
        assert_forbidden(conn, "group id, #{label}")
        assert member_ids(ctx.p, group) == [operator.id]
      end

      for {label, segment} <- spellings(operator.id) do
        conn = call(:delete, "/groups/#{group.id}/members/#{segment}", ctx.p, @admin, nil)
        assert_forbidden(conn, "user id, #{label}")
        assert member_ids(ctx.p, group) == [operator.id]
      end

      for {label, segment} <- malformed(operator.id) do
        conn = call(:delete, "/groups/#{group.id}/members/#{segment}", ctx.p, @admin, nil)
        assert conn.status == 404, "malformed user id, #{label}: #{conn.status}"
        assert conn.resp_body == ref_404.resp_body

        conn = call(:delete, "/groups/#{segment}/members/#{operator.id}", ctx.p, @admin, nil)
        assert conn.status == 404, "malformed group id, #{label}: #{conn.status}"
      end

      assert member_ids(ctx.p, group) == [operator.id]
    end

    test "T-27 GET /groups/:id/members: nonexistent and malformed group ids answer the unknown-group 404 bytes",
         ctx do
      world!(ctx)

      for {_who, roles} <- callers() do
        ref = call(:get, "/groups/#{@unknown}/members", ctx.p, roles, nil)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:get, "/groups/#{segment}/members", ctx.p, roles, nil)
        end)
      end
    end

    test "T-28 guard-triggering caller: 404 for an unknown group id, 403 for the bound group id, bound id is in GET /roles",
         ctx do
      %{group: group, operator: operator} = world!(ctx)
      user = insert_user!(ctx.p)

      routes = fn id ->
        [
          {"add", call(:post, "/groups/#{id}/members", ctx.p, @admin, %{"user_id" => user.id})},
          {"remove", call(:delete, "/groups/#{id}/members/#{operator.id}", ctx.p, @admin, nil)},
          {"delete", call(:delete, "/groups/#{id}", ctx.p, @admin, nil)}
        ]
      end

      for {name, conn} <- routes.(@unknown), do: assert(conn.status == 404, "unknown, #{name}")
      for {name, conn} <- routes.(group.id), do: assert_forbidden(conn, "bound, #{name}")

      listing = call(:get, "/roles", ctx.p, @admin, nil)
      assert listing.status == 200, listing.resp_body

      group_ids =
        listing.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["group_id"])

      assert group.id in group_ids
    end

    test "T-29 POST /groups/:id/members with an upper-case group id and user id answers with the canonical ids in the response body",
         ctx do
      group = insert_group!(ctx.p)
      user = insert_user!(ctx.p)

      conn =
        call(:post, "/groups/#{String.upcase(group.id)}/members", ctx.p, @admin, %{
          "user_id" => String.upcase(user.id)
        })

      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["group_id"] == group.id
      assert body["user_id"] == user.id
      assert member_ids(ctx.p, group) == [user.id]
    end

    test "T-30 raw-byte and upper-case spellings of a REAL unguarded group resolve like the canonical one",
         ctx do
      world!(ctx)

      for {label, _} <- spellings(@unknown) do
        group = insert_group!(ctx.p)
        user = insert_user!(ctx.p)
        {_, gseg} = Enum.find(spellings(group.id), fn {l, _} -> l == label end)

        conn = call(:post, "/groups/#{gseg}/members", ctx.p, @admin, %{"user_id" => user.id})
        assert conn.status == 201, "add, #{label}: #{conn.status} #{conn.resp_body}"
        assert member_ids(ctx.p, group) == [user.id]

        conn = call(:get, "/groups/#{gseg}/members", ctx.p, @admin, nil)
        assert conn.status == 200, "list, #{label}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body =~ user.id

        conn = call(:delete, "/groups/#{gseg}/members/#{user.id}", ctx.p, @admin, nil)
        assert conn.status == 204, "remove, #{label}: #{conn.status} #{conn.resp_body}"
        assert member_ids(ctx.p, group) == []

        conn = call(:delete, "/groups/#{gseg}", ctx.p, @admin, nil)
        assert conn.status == 204, "delete, #{label}: #{conn.status} #{conn.resp_body}"
        refute group_exists?(ctx.p, group)
      end
    end
  end

  # --- ISS-1033: tokens and roles ------------------------------------------------------------------------

  describe "ISS-1033: tokens and roles" do
    test "T-31 DELETE /tokens/:id: unknown and malformed ids are the unknown-token 404, nothing written",
         ctx do
      %{operator: operator} = world!(ctx)

      {:ok, %{token: _armed}} =
        Identity.create_token(operator.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: ctx.p.schema_name
        )

      before = snapshot(ctx.p)

      for {_who, roles} <- callers() do
        ref = call(:delete, "/tokens/#{@unknown}", ctx.p, roles, nil)

        assert_all_unknown_404(ref, variants(@unknown), fn segment ->
          call(:delete, "/tokens/#{segment}", ctx.p, roles, nil)
        end)
      end

      assert snapshot(ctx.p) == before
    end

    test "T-32 DELETE /tokens/:id: every spelling of a real PLATFORM_ADMIN token is 403 for TENANT_ADMIN, 200 for operator",
         ctx do
      %{operator: operator} = world!(ctx)

      for {label, _} <- spellings(@unknown) do
        {:ok, %{token: token}} =
          Identity.create_token(operator.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
            prefix: ctx.p.schema_name
          )

        {_, segment} = Enum.find(spellings(token.id), fn {l, _} -> l == label end)
        before = token_row(ctx.p, token.id)
        assert {nil, ["PLATFORM_ADMIN"]} = before

        conn = call(:delete, "/tokens/#{segment}", ctx.p, @admin, nil)
        assert_forbidden(conn, "revoke, #{label}")
        assert token_row(ctx.p, token.id) == before, "#{label}: the token was revoked"

        conn = call(:delete, "/tokens/#{segment}", ctx.p, @operator, nil)
        assert conn.status == 200, "control, #{label}: #{conn.status} #{conn.resp_body}"
        assert {%DateTime{}, _} = token_row(ctx.p, token.id), "control, #{label}: not revoked"
      end
    end

    test "T-33 POST /tokens: unknown-user 404 bytes; order is name guard 403, expires_at 422, user_id 404",
         ctx do
      user = insert_user!(ctx.p)
      before = snapshot(ctx.p)

      ref =
        call(:post, "/tokens", ctx.p, @admin, %{"user_id" => @unknown, "roles" => ["TASK_WORKER"]})

      assert ref.status == 404, ref.resp_body

      for {label, segment} <- variants(@unknown) do
        conn =
          call(:post, "/tokens", ctx.p, @admin, %{
            "user_id" => body_value(segment),
            "roles" => ["TASK_WORKER"]
          })

        assert conn.status == 404, "#{label}: #{conn.status} #{conn.resp_body}"
        assert conn.resp_body == ref.resp_body, "#{label}: bytes differ from unknown user"
      end

      assert snapshot(ctx.p) == before

      # the PLATFORM_ADMIN-name guard is target-independent: identical 403 for every kind of user_id
      forbidden_bodies =
        for user_id <- [user.id, @unknown, "not-a-uuid"] do
          conn =
            call(:post, "/tokens", ctx.p, @admin, %{
              "user_id" => user_id,
              "roles" => ["PLATFORM_ADMIN"]
            })

          assert_forbidden(conn, "name guard, user_id #{user_id}")
          conn.resp_body
        end

      assert length(Enum.uniq(forbidden_bodies)) == 1

      # order: guard 403 > expires_at 422 > user_id 404
      bad_expiry = "not-a-timestamp"

      conn =
        call(:post, "/tokens", ctx.p, @admin, %{
          "user_id" => @unknown,
          "roles" => ["PLATFORM_ADMIN"],
          "expires_at" => bad_expiry
        })

      assert_forbidden(conn, "guard before expiry")

      for user_id <- [@unknown, "not-a-uuid"] do
        conn =
          call(:post, "/tokens", ctx.p, @admin, %{
            "user_id" => user_id,
            "roles" => ["TASK_WORKER"],
            "expires_at" => bad_expiry
          })

        assert conn.status == 422,
               "expiry before user, #{user_id}: #{conn.status} #{conn.resp_body}"
      end

      assert snapshot(ctx.p) == before

      # control: the same request with a real user mints
      conn =
        call(:post, "/tokens", ctx.p, @admin, %{"user_id" => user.id, "roles" => ["TASK_WORKER"]})

      assert conn.status == 201, conn.resp_body
    end

    test "T-34 POST /roles: name guards are the same 403 for every group_id; ordinary name keeps 422 / 404",
         ctx do
      group = insert_group!(ctx.p)
      before = snapshot(ctx.p)

      # H1: the PLATFORM_ADMIN name for the TENANT_ADMIN (either kind); H2: a built-in name for a
      # PROCESS_DESIGNER, who lacks :UsersGroupsRolesManage (either kind)
      for {roles, name, kind} <- [
            {@admin, "PLATFORM_ADMIN", "platform_role"},
            {@admin, "PLATFORM_ADMIN", "process_routing_role"},
            {["PROCESS_DESIGNER"], "TENANT_ADMIN", "platform_role"},
            {["PROCESS_DESIGNER"], "TENANT_ADMIN", "process_routing_role"}
          ] do
        bodies =
          for group_id <- [group.id, @unknown, "not-a-uuid"] do
            conn =
              call(:post, "/roles", ctx.p, roles, %{
                "name" => name,
                "kind" => kind,
                "group_id" => group_id
              })

            assert_forbidden(conn, "#{name} #{kind} #{group_id}")
            conn.resp_body
          end

        assert length(Enum.uniq(bodies)) == 1, "#{name} #{kind}: 403 bodies differ by group_id"
      end

      assert snapshot(ctx.p) == before

      ordinary = fn group_id ->
        call(:post, "/roles", ctx.p, @admin, %{
          "name" => "ROUTE_ORDINARY",
          "kind" => "process_routing_role",
          "group_id" => group_id
        })
      end

      conn = ordinary.("not-a-uuid")
      assert conn.status == 422, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] =~ "invalid_group_id"

      conn = ordinary.(@unknown)
      assert conn.status == 404, conn.resp_body

      # control: a real group binds (the 422 / 404 above are not vacuous)
      conn = ordinary.(group.id)
      assert conn.status == 200, conn.resp_body
      assert {"ROUTE_ORDINARY", :process_routing_role, group.id} in role_rows(ctx.p)
    end
  end

  # --- ISS-1033: authorise BEFORE cast ----------------------------------------------------------------------

  describe "ISS-1033: the permission gate runs before the id cast" do
    test "T-35 an unauthorised caller sending a malformed id gets the gate's 403 on every id route, never the 404; an authorised caller gets the 404 (control)",
         ctx do
      %{operator: operator} = world!(ctx)
      group = insert_group!(ctx.p)

      routes = fn bad ->
        [
          {"GET /users/:id", :get, "/users/#{bad}", nil},
          {"PATCH /users/:id", :patch, "/users/#{bad}", %{"display_name" => "x"}},
          {"POST /users/:id/status", :post, "/users/#{bad}/status", %{"status" => "inactive"}},
          {"DELETE /groups/:id", :delete, "/groups/#{bad}", nil},
          {"GET /groups/:id/members", :get, "/groups/#{bad}/members", nil},
          {"POST /groups/:id/members", :post, "/groups/#{bad}/members",
           %{"user_id" => operator.id}},
          {"DELETE member, group id", :delete, "/groups/#{bad}/members/#{operator.id}", nil},
          {"DELETE member, user id", :delete, "/groups/#{group.id}/members/#{bad}", nil},
          {"DELETE /tokens/:id", :delete, "/tokens/#{bad}", nil}
        ]
      end

      # a TASK_WORKER holds none of :UsersManage, :GroupsManage, :TokensManage
      for {_label, bad} <- malformed(@unknown), {name, method, path, body} <- routes.(bad) do
        denied = call(method, path, ctx.p, ["TASK_WORKER"], body)
        assert denied.status == 403, "#{name} #{bad}: #{denied.status} #{denied.resp_body}"

        well_formed =
          call(method, String.replace(path, bad, @unknown), ctx.p, ["TASK_WORKER"], body)

        assert denied.resp_body == well_formed.resp_body, "#{name} #{bad}: gate body differs"

        # control: the authorised caller gets the plain 404 for the same malformed id
        allowed = call(method, path, ctx.p, @admin, body)

        assert allowed.status == 404,
               "control #{name} #{bad}: #{allowed.status} #{allowed.resp_body}"
      end

      # POST /tokens with a malformed body user_id
      for {label, bad} <- malformed(@unknown) do
        body = %{"user_id" => body_value(bad), "roles" => ["TASK_WORKER"]}
        denied = call(:post, "/tokens", ctx.p, ["TASK_WORKER"], body)
        assert denied.status == 403, "POST /tokens #{label}: #{denied.status} #{denied.resp_body}"

        allowed = call(:post, "/tokens", ctx.p, @admin, body)
        assert allowed.status == 404, "control POST /tokens #{label}: #{allowed.status}"
      end
    end
  end
end
