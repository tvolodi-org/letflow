defmodule Letflow.Api.PlatformEscalationGuardTest do
  @moduledoc """
  REQ-447 PR 1, PART C (`lib/letflow/design/req447-tenant-admin-role.md` section 3.6b, F1 / INV-10;
  spec `test/specs/REQ-447-PR1.md`): a `TENANT_ADMIN` of the PLATFORM tenant holds `:TokensManage`,
  `:GroupsManage` and `:UsersManage`, and must still not become, impersonate, remove or disable a
  platform operator. Every guard in `Letflow.Routers.Identity` is decided by platform scope
  RECOMPUTED from the DB-resolved `auth_context`, before any write, and answers the fixed 403
  `insufficient permissions` (a body that names no role).

  Real Postgres, real router (`Letflow.Routers.Identity.call/2`), the platform tenant pinned on P.
  Caller under test: `TENANT_ADMIN` of P. Positive control for every refused call: the platform
  operator (`PLATFORM_ADMIN` of P) succeeds with the very same request, so no denial is vacuous.

  RAW-BYTE NEGATIVE TESTS (the SECURITY BLOCKER found at design/code review): `Ecto.UUID.cast/1`
  accepts the canonical lower-case id, the upper-case id and the raw 16-byte binary, and the
  downstream lookups (`Repo.get/3`, `where: id == ^id`) go through that same cast. A guard that
  compared the request's id to the bound group id as STRINGS would let the raw-byte or upper-case
  spelling of the very same group through. For each guarded route the id is therefore sent in every
  cast-accepted spelling; for each spelling the operator control proves the spelling REALLY reaches
  the handler and resolves to the real row, and the TENANT_ADMIN is then required to get 403 with
  the rows unchanged.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  import Ecto.Query, only: [from: 2]

  @admin ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  # --- helpers -----------------------------------------------------------------------------------

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
      username: "req447c-#{Ecto.UUID.generate()}",
      display_name: "REQ-447 C User",
      email: "req447c-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp insert_group!(fixture, name \\ nil) do
    %Group{}
    |> Ecto.Changeset.change(%{name: name || "req447c-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp add_member!(fixture, group, user) do
    {:ok, _} = Identity.add_group_member(group.id, user.id, opts(fixture))
    :ok
  end

  # a group bound (by BINDING, not by name) to the PLATFORM_ADMIN role, named so the name never
  # gives it away
  defp bound_group!(fixture) do
    group = insert_group!(fixture)

    {:ok, _role} =
      RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id, opts(fixture))

    group
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

  defp token_count(fixture), do: Repo.aggregate(ApiToken, :count, prefix: fixture.schema_name)

  # a platform-tenant world: the group bound to PLATFORM_ADMIN with one operator in it
  defp world!(ctx) do
    group = bound_group!(ctx.p)
    operator = insert_user!(ctx.p)
    add_member!(ctx.p, group, operator)
    %{group: group, operator: operator}
  end

  # percent-encode EVERY byte, upper-case or lower-case hex digits
  defp pct(bin, case_fun) do
    for <<byte <- bin>>, into: "", do: "%" <> case_fun.(Base.encode16(<<byte>>))
  end

  # Every spelling of `uuid` that Ecto.UUID.cast/1 accepts, as a PATH SEGMENT. The raw-byte forms are
  # the 16 bytes of the uuid percent-encoded (what a client sends to put raw bytes in a URL).
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

  defp assert_forbidden(conn, label) do
    assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["detail"] =~ "insufficient permissions", label
    refute conn.resp_body =~ ~r/platform.?admin/i, label
  end

  # --- sanity: the spellings are what we claim ---------------------------------------------------

  describe "the spelling table itself" do
    test "every spelling decodes (as the router does) to a binary that Ecto.UUID.cast/1 resolves to the same uuid" do
      uuid = Ecto.UUID.generate()

      for {label, segment} <- spellings(uuid) do
        decoded = URI.decode(segment)
        assert {:ok, ^uuid} = Ecto.UUID.cast(decoded), label
      end

      # the raw forms are really 16 bytes and NOT the canonical text (a string compare cannot match them)
      raw_forms = for {l, s} <- spellings(uuid), l =~ "raw 16 bytes", do: URI.decode(s)
      assert Enum.all?(raw_forms, &(byte_size(&1) == 16 and &1 != uuid))
    end
  end

  # --- (1) POST /tokens ----------------------------------------------------------------------------

  describe "POST /tokens" do
    test "platform-tenant TENANT_ADMIN: exact name, case and whitespace variants, among other roles, fixed 403, no token row",
         ctx do
      user = insert_user!(ctx.p)
      before = token_count(ctx.p)

      role_lists =
        [
          ["PLATFORM_ADMIN"],
          ["platform_admin"],
          ["Platform_Admin"],
          [" PLATFORM_ADMIN"],
          ["PLATFORM_ADMIN "],
          ["\tplatform_admin\n"],
          ["TASK_WORKER", "PLATFORM_ADMIN"],
          ["PLATFORM_ADMIN", "TASK_WORKER"],
          ["TENANT_ADMIN", "PROCESS_DESIGNER", " platform_admin "]
        ]

      for roles <- role_lists do
        conn =
          call(:post, "/tokens", ctx.p, @admin, %{"user_id" => user.id, "roles" => roles})

        assert_forbidden(conn, inspect(roles))
      end

      assert token_count(ctx.p) == before, "a token row was written"
    end

    test "403 wins over a 422 bad expires_at (the guard runs before the expiry parse)", ctx do
      user = insert_user!(ctx.p)

      conn =
        call(:post, "/tokens", ctx.p, @admin, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"],
          "expires_at" => "not-a-timestamp"
        })

      assert_forbidden(conn, "bad expires_at")

      # control for the claim: with a role that is not PLATFORM_ADMIN the same bad expires_at is the 422
      conn =
        call(:post, "/tokens", ctx.p, @admin, %{
          "user_id" => user.id,
          "roles" => ["TASK_WORKER"],
          "expires_at" => "not-a-timestamp"
        })

      assert conn.status == 422, conn.resp_body
    end

    test "the refusal body is byte-identical for every spelling and caller", ctx do
      user_p = insert_user!(ctx.p)
      user_a = insert_user!(ctx.a)

      bodies =
        for {fixture, user, roles} <- [
              {ctx.p, user_p, @admin},
              {ctx.a, user_a, @admin},
              {ctx.a, user_a, ["PROCESS_DESIGNER", "TENANT_ADMIN"]}
            ],
            name <- ["PLATFORM_ADMIN", "platform_admin", " PLATFORM_ADMIN "] do
          conn =
            call(:post, "/tokens", fixture, roles, %{"user_id" => user.id, "roles" => [name]})

          assert conn.status == 403
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
    end

    test "CONTROL: the platform operator (PLATFORM_ADMIN of P) mints a PLATFORM_ADMIN token (201)",
         ctx do
      user = insert_user!(ctx.p)
      before = token_count(ctx.p)

      conn =
        call(:post, "/tokens", ctx.p, @operator, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"]
        })

      assert conn.status == 201, conn.resp_body
      assert token_count(ctx.p) == before + 1
    end

    test "CONTROL: a TENANT_ADMIN of P still mints a TENANT_ADMIN token and an ordinary-role token (the guard is not over-broad)",
         ctx do
      user = insert_user!(ctx.p)

      for roles <- [["TENANT_ADMIN"], ["TASK_WORKER", "PROCESS_DESIGNER"]] do
        conn = call(:post, "/tokens", ctx.p, @admin, %{"user_id" => user.id, "roles" => roles})
        assert conn.status == 201, "#{inspect(roles)}: #{conn.resp_body}"
      end
    end

    test "Identity.create_token/3 called directly is UNCHANGED in PR 1 (the check is in the router, design 3.6b)",
         ctx do
      user = insert_user!(ctx.p)

      assert {:ok, %{token: token}} =
               Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
                 prefix: ctx.p.schema_name
               )

      assert token.roles == ["PLATFORM_ADMIN"]
    end
  end

  # --- (8) legacy tenant PLATFORM_ADMIN ----------------------------------------------------------------

  describe "D10: legacy tenant PLATFORM_ADMIN" do
    test "legacy PLATFORM_ADMIN of ordinary tenant A holds nothing (403 for every token); a TENANT_ADMIN of A mints a TENANT_ADMIN token (201) but not a PLATFORM_ADMIN one (403)",
         ctx do
      user = insert_user!(ctx.a)
      before = token_count(ctx.a)

      conn =
        call(:post, "/tokens", ctx.a, @operator, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"]
        })

      assert_forbidden(conn, "legacy PLATFORM_ADMIN of A")
      assert token_count(ctx.a) == before

      # REQ-447 PR 2: the legacy own-tenant power is REMOVED, so it no longer holds even the
      # tenant-scope :TokensManage (was 201)
      conn =
        call(:post, "/tokens", ctx.a, @operator, %{
          "user_id" => user.id,
          "roles" => ["TENANT_ADMIN"]
        })

      assert_forbidden(conn, "legacy PLATFORM_ADMIN of A, TENANT_ADMIN token")
      assert token_count(ctx.a) == before

      # positive control: the TENANT_ADMIN of A holds the tenant-scope power
      conn =
        call(:post, "/tokens", ctx.a, @admin, %{
          "user_id" => user.id,
          "roles" => ["TENANT_ADMIN"]
        })

      assert conn.status == 201, conn.resp_body

      conn =
        call(:post, "/tokens", ctx.a, @admin, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"]
        })

      assert_forbidden(conn, "TENANT_ADMIN of A, PLATFORM_ADMIN token")
    end
  end

  # --- (2) group routes ----------------------------------------------------------------------------

  describe "the PLATFORM_ADMIN-bound group" do
    test "TENANT_ADMIN of P cannot add itself (or anyone) to the group: 403, membership unchanged",
         ctx do
      %{group: group, operator: operator} = world!(ctx)
      caller_user = insert_user!(ctx.p)
      other = insert_user!(ctx.p)
      before = member_ids(ctx.p, group)
      assert before == [operator.id]

      for user <- [caller_user, other] do
        conn =
          call(:post, "/groups/#{group.id}/members", ctx.p, @admin, %{"user_id" => user.id})

        assert_forbidden(conn, "add #{user.id}")
      end

      # the array form of the body is guarded by the same route
      conn =
        call(:post, "/groups/#{group.id}/members", ctx.p, @admin, %{
          "user_ids" => [caller_user.id]
        })

      assert_forbidden(conn, "user_ids form")
      assert member_ids(ctx.p, group) == before
    end

    test "the group is found by BINDING, not by name (a group merely NAMED PLATFORM_ADMIN is not protected)",
         ctx do
      %{group: bound} = world!(ctx)
      decoy = insert_group!(ctx.p, "PLATFORM_ADMIN-named-but-unbound")
      user = insert_user!(ctx.p)

      assert_forbidden(
        call(:post, "/groups/#{bound.id}/members", ctx.p, @admin, %{"user_id" => user.id}),
        "bound"
      )

      conn = call(:post, "/groups/#{decoy.id}/members", ctx.p, @admin, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body
      assert member_ids(ctx.p, decoy) == [user.id]
      assert member_ids(ctx.p, bound) != [user.id]
    end

    test "TENANT_ADMIN of P cannot remove an operator from the group: 403, operator still a member",
         ctx do
      %{group: group, operator: operator} = world!(ctx)

      conn = call(:delete, "/groups/#{group.id}/members/#{operator.id}", ctx.p, @admin, nil)

      assert_forbidden(conn, "remove operator")
      assert member_ids(ctx.p, group) == [operator.id]
    end

    test "TENANT_ADMIN of P cannot delete the group: 403, group and binding intact (also when empty)",
         ctx do
      %{group: group, operator: operator} = world!(ctx)
      roles_before = role_rows(ctx.p)

      assert_forbidden(call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil), "with members")
      assert group_exists?(ctx.p, group)

      # also when it has no members (the non-guarded outcome would be a real delete)
      Repo.delete_all(from(m in GroupMember, where: m.group_id == ^group.id),
        prefix: ctx.p.schema_name
      )

      assert_forbidden(call(:delete, "/groups/#{group.id}", ctx.p, @admin, nil), "empty")
      assert group_exists?(ctx.p, group)
      assert role_rows(ctx.p) == roles_before
      refute operator.id in member_ids(ctx.p, group)
    end

    test "CONTROL: the platform operator adds, removes and deletes (2xx), proving the three denials are not vacuous",
         ctx do
      %{group: group, operator: operator} = world!(ctx)
      user = insert_user!(ctx.p)

      conn = call(:post, "/groups/#{group.id}/members", ctx.p, @operator, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body
      assert user.id in member_ids(ctx.p, group)

      conn = call(:delete, "/groups/#{group.id}/members/#{user.id}", ctx.p, @operator, nil)
      assert conn.status == 204, conn.resp_body
      refute user.id in member_ids(ctx.p, group)

      conn = call(:delete, "/groups/#{group.id}/members/#{operator.id}", ctx.p, @operator, nil)
      assert conn.status == 204, conn.resp_body

      # The bound group cannot be deleted by anyone: tenant_role.group_id references it, so the
      # delete is a clean 409 (ISS-1032; it was a 500). The operator's request still REACHES the real
      # row, which is what makes the TENANT_ADMIN's 403 non-vacuous.
      conn = call(:delete, "/groups/#{group.id}", ctx.p, @operator, nil)
      assert conn.status == 409, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == "group is bound to a role"

      assert group_exists?(ctx.p, group)
    end

    test "CONTROL: a TENANT_ADMIN of P still manages an ordinary group (add, remove, delete)",
         ctx do
      ordinary = insert_group!(ctx.p)
      user = insert_user!(ctx.p)

      conn = call(:post, "/groups/#{ordinary.id}/members", ctx.p, @admin, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body

      conn = call(:delete, "/groups/#{ordinary.id}/members/#{user.id}", ctx.p, @admin, nil)
      assert conn.status == 204, conn.resp_body

      conn = call(:delete, "/groups/#{ordinary.id}", ctx.p, @admin, nil)
      assert conn.status == 204, conn.resp_body
    end
  end

  # --- (3) raw-byte and cast-variant ids -----------------------------------------------------------
  #
  # MEASURED FACT (Ecto 3.14.1, recorded here so the denials below are read correctly): `Ecto.UUID.cast/1`
  # accepts the raw 16-byte form, but `Repo.get(Schema, raw16)` and `where: id == ^raw16` do NOT: they
  # raise `Ecto.Query.CastError`. Since ISS-1033 every identity route casts the id FIRST
  # (`Identity.cast_id/1`) and uses the canonical text afterwards, so EVERY cast-accepted spelling
  # (including both raw-byte forms) resolves to the real row exactly like the canonical one, and a
  # spelling the cast rejects is the plain 404. A CastError is therefore a failure now, not a tolerated
  # outcome. The guard decides on the same canonical value (INV-10): the TENANT_ADMIN must always see
  # the fixed 403 for every spelling of the real guarded id, which is what a string-compare guard
  # would fail.

  @resolving [
    "canonical lower-case",
    "upper-case hyphenated",
    "mixed-case hyphenated",
    "raw 16 bytes, %XX upper-case hex",
    "raw 16 bytes, %xx lower-case hex",
    "canonical text, every char percent-encoded"
  ]

  # dispatch, turning a raised exception into {:raised, exception} (a Plug.Conn.WrapperError is unwrapped)
  defp try_call(method, path, fixture, roles, body) do
    {:resp, call(method, path, fixture, roles, body)}
  rescue
    e in Plug.Conn.WrapperError -> {:raised, e.reason}
    e -> {:raised, e}
  end

  defp assert_forbidden_resp({:resp, conn}, label), do: assert_forbidden(conn, label)

  defp assert_forbidden_resp({:raised, e}, label),
    do: flunk("#{label}: expected the fixed 403, the request raised #{inspect(e.__struct__)}")

  # the operator control: the spelling must resolve (status as expected, reached the real row).
  # Anything else, a raised CastError included, is a failure.
  defp operator_outcome({:resp, conn}, expected_status, label) do
    assert conn.status == expected_status,
           "control, #{label}: #{conn.status} #{conn.resp_body}"

    :resolved
  end

  defp operator_outcome({:raised, e}, _status, label),
    do: flunk("control, #{label}: unexpected #{inspect(e)}")

  defp assert_resolving_spellings_reached(outcomes) do
    for label <- @resolving do
      assert outcomes[label] == :resolved,
             "the denial for #{label} would be vacuous: the operator control did not reach the real row"
    end
  end

  describe "RAW-BYTE: group id spellings" do
    test "ADD MEMBER: every spelling is 403 for the TENANT_ADMIN, nothing written; the operator control resolves for every spelling",
         ctx do
      %{group: group} = world!(ctx)
      before = member_ids(ctx.p, group)

      outcomes =
        for {label, segment} <- spellings(group.id), into: %{} do
          user = insert_user!(ctx.p)
          body = %{"user_id" => user.id}

          resp = try_call(:post, "/groups/#{segment}/members", ctx.p, @admin, body)
          assert_forbidden_resp(resp, "add member, #{label}")
          assert member_ids(ctx.p, group) == before, "#{label}: membership changed"

          resp = try_call(:post, "/groups/#{segment}/members", ctx.p, @operator, body)
          outcome = operator_outcome(resp, 201, label)
          assert user.id in member_ids(ctx.p, group), "control, #{label}: not the REAL group"

          Repo.delete_all(
            from(m in GroupMember, where: m.group_id == ^group.id and m.user_id == ^user.id),
            prefix: ctx.p.schema_name
          )

          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)
    end

    test "REMOVE MEMBER: every spelling of the group id is 403 for the TENANT_ADMIN (member kept); every spelling of the user id too",
         ctx do
      %{group: group, operator: operator} = world!(ctx)

      outcomes =
        for {label, segment} <- spellings(group.id), into: %{} do
          resp =
            try_call(:delete, "/groups/#{segment}/members/#{operator.id}", ctx.p, @admin, nil)

          assert_forbidden_resp(resp, "remove member, group id #{label}")
          assert member_ids(ctx.p, group) == [operator.id], "#{label}: membership changed"

          resp =
            try_call(:delete, "/groups/#{segment}/members/#{operator.id}", ctx.p, @operator, nil)

          outcome = operator_outcome(resp, 204, label)
          assert member_ids(ctx.p, group) == [], "control, #{label}: not the REAL group"
          add_member!(ctx.p, group, operator)

          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)

      # the guard is decided on the GROUP id; the user-id segment may be spelled any way
      for {label, segment} <- spellings(operator.id) do
        resp = try_call(:delete, "/groups/#{group.id}/members/#{segment}", ctx.p, @admin, nil)
        assert_forbidden_resp(resp, "remove member, user id #{label}")
        assert member_ids(ctx.p, group) == [operator.id], "#{label}: membership changed"
      end
    end

    test "DELETE GROUP: every spelling is 403 for the TENANT_ADMIN (group intact); control reaches the real row for every spelling",
         ctx do
      bound = bound_group!(ctx.p)
      roles_before = role_rows(ctx.p)

      outcomes =
        for {label, segment} <- spellings(bound.id), into: %{} do
          resp = try_call(:delete, "/groups/#{segment}", ctx.p, @admin, nil)
          assert_forbidden_resp(resp, "delete group, #{label}")
          assert group_exists?(ctx.p, bound), "#{label}: the group was deleted"
          assert role_rows(ctx.p) == roles_before

          # the bound memberless group cannot be deleted by anyone: the operator's request reaches
          # the real row and is refused with the 409 (ISS-1032), for every spelling
          resp = try_call(:delete, "/groups/#{segment}", ctx.p, @operator, nil)
          outcome = operator_outcome(resp, 409, label)

          assert group_exists?(ctx.p, bound)
          assert role_rows(ctx.p) == roles_before
          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)
    end

    test "a spelling Ecto.UUID.cast/1 does NOT accept (padded, hyphenless, truncated, doubled) is a 404 and writes nothing",
         ctx do
      %{group: group} = world!(ctx)
      user = insert_user!(ctx.p)
      before = member_ids(ctx.p, group)

      for segment <- [
            "%20" <> group.id,
            group.id <> "%20",
            String.replace(group.id, "-", ""),
            String.slice(group.id, 0, 35),
            group.id <> group.id
          ] do
        assert :error == Ecto.UUID.cast(URI.decode(segment))

        resp =
          try_call(:post, "/groups/#{segment}/members", ctx.p, @admin, %{"user_id" => user.id})

        # ISS-1033: the cast runs first, so an uncastable group id is the plain 404 (never a raise)
        assert {:resp, conn} = resp, "#{segment}: raised"
        assert conn.status == 404, "#{segment}: #{conn.status} #{conn.resp_body}"

        assert member_ids(ctx.p, group) == before
      end
    end
  end

  describe "RAW-BYTE: user id spellings (PATCH, status)" do
    test "PATCH: every spelling resolves for the operator and is 403 for the TENANT_ADMIN, user unchanged",
         ctx do
      %{operator: operator} = world!(ctx)

      outcomes =
        for {label, segment} <- spellings(operator.id), into: %{} do
          before = user_row(ctx.p, operator)

          admin =
            try_call(:patch, "/users/#{segment}", ctx.p, @admin, %{"display_name" => "pwned"})

          assert user_row(ctx.p, operator) == before, "#{label}: the operator was modified"

          op =
            try_call(:patch, "/users/#{segment}", ctx.p, @operator, %{
              "display_name" => "ctl-#{label}"
            })

          outcome = operator_outcome(op, 200, label)
          assert_forbidden_resp(admin, "PATCH, #{label}")

          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)
    end

    test "STATUS: every spelling resolves for the operator and is 403 for the TENANT_ADMIN, who leaves the operator active",
         ctx do
      %{operator: operator} = world!(ctx)

      outcomes =
        for {label, segment} <- spellings(operator.id), into: %{} do
          admin =
            try_call(:post, "/users/#{segment}/status", ctx.p, @admin, %{"status" => "inactive"})

          assert {_, :active} = user_row(ctx.p, operator),
                 "#{label}: the operator was deactivated"

          op =
            try_call(:post, "/users/#{segment}/status", ctx.p, @operator, %{
              "status" => "inactive"
            })

          outcome = operator_outcome(op, 200, label)
          reactivate!(ctx.p, operator)
          assert_forbidden_resp(admin, "STATUS, #{label}")

          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)
    end
  end

  defp reactivate!(fixture, user) do
    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user.id), [set: [status: :active]],
        prefix: fixture.schema_name
      )

    :ok
  end

  describe "RAW-BYTE: token id spellings (DELETE)" do
    test "every spelling is 403 for the TENANT_ADMIN and the token stays unrevoked; the operator control resolves for every spelling",
         ctx do
      %{operator: operator} = world!(ctx)

      outcomes =
        for {label, _} <- spellings(Ecto.UUID.generate()), into: %{} do
          {:ok, %{token: token}} =
            Identity.create_token(operator.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
              prefix: ctx.p.schema_name
            )

          {_, segment} = Enum.find(spellings(token.id), fn {l, _} -> l == label end)
          before = token_row(ctx.p, token.id)
          assert {nil, ["PLATFORM_ADMIN"]} = before

          resp = try_call(:delete, "/tokens/#{segment}", ctx.p, @admin, nil)
          assert_forbidden_resp(resp, "revoke token, #{label}")
          assert token_row(ctx.p, token.id) == before, "#{label}: the token was revoked"

          resp = try_call(:delete, "/tokens/#{segment}", ctx.p, @operator, nil)
          outcome = operator_outcome(resp, 200, label)
          assert {%DateTime{}, _} = token_row(ctx.p, token.id), "control, #{label}: not revoked"

          {label, outcome}
        end

      assert_resolving_spellings_reached(outcomes)
    end
  end

  # --- (4) users ------------------------------------------------------------------------------------

  describe "PATCH /users/:id and POST /users/:id/status" do
    test "on a platform operator: 403 for the TENANT_ADMIN of P, state unchanged; 200 for the operator (control)",
         ctx do
      %{operator: operator} = world!(ctx)
      before = user_row(ctx.p, operator)

      assert_forbidden(
        call(:patch, "/users/#{operator.id}", ctx.p, @admin, %{"display_name" => "pwned"}),
        "patch"
      )

      assert_forbidden(
        call(:post, "/users/#{operator.id}/status", ctx.p, @admin, %{"status" => "inactive"}),
        "status"
      )

      assert user_row(ctx.p, operator) == before

      conn = call(:patch, "/users/#{operator.id}", ctx.p, @operator, %{"display_name" => "ctl"})
      assert conn.status == 200, conn.resp_body
      assert {"ctl", :active} = user_row(ctx.p, operator)

      conn =
        call(:post, "/users/#{operator.id}/status", ctx.p, @operator, %{"status" => "inactive"})

      assert conn.status == 200, conn.resp_body
      assert {_, :inactive} = user_row(ctx.p, operator)
    end

    test "on an ordinary member of P (not in the bound group): 2xx for the TENANT_ADMIN", ctx do
      world!(ctx)
      ordinary_group = insert_group!(ctx.p)
      member = insert_user!(ctx.p)
      add_member!(ctx.p, ordinary_group, member)

      conn = call(:patch, "/users/#{member.id}", ctx.p, @admin, %{"display_name" => "renamed"})
      assert conn.status == 200, conn.resp_body
      assert {"renamed", :active} = user_row(ctx.p, member)

      conn =
        call(:post, "/users/#{member.id}/status", ctx.p, @admin, %{"status" => "inactive"})

      assert conn.status == 200, conn.resp_body
      assert {_, :inactive} = user_row(ctx.p, member)
    end

    test "the guard follows the BINDING: a user in the group while it is bound is protected, and not protected after the binding moves away",
         ctx do
      %{group: group, operator: operator} = world!(ctx)

      assert_forbidden(
        call(:patch, "/users/#{operator.id}", ctx.p, @admin, %{"display_name" => "x"}),
        "bound"
      )

      other = insert_group!(ctx.p)

      # GH 2524: moving a binding is the explicit rebind (upsert_role/4 refuses it).
      [%{id: role_id}] =
        Enum.filter(RoleRegistry.list_roles(opts(ctx.p)), &(&1.name == "PLATFORM_ADMIN"))

      {:ok, _} =
        RoleRegistry.rebind_role(
          role_id,
          other.id,
          %{actor_id: nil, reason: "test: move the operator binding"},
          Keyword.put(opts(ctx.p), :platform_scope, true)
        )

      # the old group no longer confers the operator role, so its members are ordinary users now
      conn = call(:patch, "/users/#{operator.id}", ctx.p, @admin, %{"display_name" => "y"})
      assert conn.status == 200, conn.resp_body
      assert member_ids(ctx.p, group) == [operator.id]
    end
  end

  # --- (5) tokens ----------------------------------------------------------------------------------

  describe "DELETE /tokens/:id" do
    test "a PLATFORM_ADMIN token: 403 for the TENANT_ADMIN of P, token stays unrevoked; 200 for the operator (control)",
         ctx do
      %{operator: operator} = world!(ctx)

      {:ok, %{token: token}} =
        Identity.create_token(
          operator.id,
          %{roles: ["TASK_WORKER", "PLATFORM_ADMIN"], expires_at: nil},
          prefix: ctx.p.schema_name
        )

      before = token_row(ctx.p, token.id)
      assert_forbidden(call(:delete, "/tokens/#{token.id}", ctx.p, @admin, nil), "revoke")
      assert token_row(ctx.p, token.id) == before
      assert {nil, _} = before

      conn = call(:delete, "/tokens/#{token.id}", ctx.p, @operator, nil)
      assert conn.status == 200, conn.resp_body
      assert {%DateTime{}, _} = token_row(ctx.p, token.id)
    end

    test "an ordinary token (no PLATFORM_ADMIN): 2xx for the TENANT_ADMIN; an unknown id keeps its 404",
         ctx do
      user = insert_user!(ctx.p)

      {:ok, %{token: token}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.p.schema_name
        )

      conn = call(:delete, "/tokens/#{token.id}", ctx.p, @admin, nil)
      assert conn.status == 200, conn.resp_body
      assert {%DateTime{}, _} = token_row(ctx.p, token.id)

      conn = call(:delete, "/tokens/#{Ecto.UUID.generate()}", ctx.p, @admin, nil)
      assert conn.status == 404
    end
  end

  # --- (6) POST /roles ----------------------------------------------------------------------------

  describe "POST /roles for the PLATFORM_ADMIN name (H1)" do
    test "TENANT_ADMIN of P, both kinds, name variants: 403 and the binding is unchanged; the operator rebinds (control)",
         ctx do
      %{group: group} = world!(ctx)
      attacker_group = insert_group!(ctx.p)
      before = role_rows(ctx.p)

      for kind <- ["platform_role", "process_routing_role"],
          name <- ["PLATFORM_ADMIN", "platform_admin", " Platform_Admin "] do
        conn =
          call(:post, "/roles", ctx.p, @admin, %{
            "name" => name,
            "kind" => kind,
            "group_id" => attacker_group.id
          })

        assert_forbidden(conn, "#{kind} #{inspect(name)}")
        assert role_rows(ctx.p) == before
      end

      assert {"PLATFORM_ADMIN", :platform_role, group.id} in role_rows(ctx.p)

      # GH 2524: the explicit rebind route keeps H1 for the TENANT_ADMIN of P ...
      [%{id: role_id}] =
        Enum.filter(RoleRegistry.list_roles(opts(ctx.p)), &(&1.name == "PLATFORM_ADMIN"))

      rebind = %{"group_id" => attacker_group.id, "reason" => "move it"}

      assert_forbidden(call(:post, "/roles/#{role_id}/rebind", ctx.p, @admin, rebind), "rebind")
      assert role_rows(ctx.p) == before

      # ... while POST /roles no longer moves a binding for anyone (the operator gets 409) ...
      conn =
        call(:post, "/roles", ctx.p, @operator, %{
          "name" => "PLATFORM_ADMIN",
          "kind" => "platform_role",
          "group_id" => attacker_group.id
        })

      assert conn.status == 409, conn.resp_body
      assert role_rows(ctx.p) == before

      # ... and the operator rebinds through the explicit route (control).
      conn = call(:post, "/roles/#{role_id}/rebind", ctx.p, @operator, rebind)

      assert conn.status == 200, conn.resp_body
      assert {"PLATFORM_ADMIN", :platform_role, attacker_group.id} in role_rows(ctx.p)
    end
  end

  # --- (7) :none reliance --------------------------------------------------------------------------

  describe "reliance: no PLATFORM_ADMIN binding" do
    test "ordinary tenant A, no binding: a TENANT_ADMIN adds, removes, deletes groups and edits users freely",
         ctx do
      assert RoleRegistry.platform_admin_group_id(opts(ctx.a)) == :none

      group = insert_group!(ctx.a)
      user = insert_user!(ctx.a)

      conn = call(:post, "/groups/#{group.id}/members", ctx.a, @admin, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body

      conn = call(:patch, "/users/#{user.id}", ctx.a, @admin, %{"display_name" => "ok"})
      assert conn.status == 200, conn.resp_body

      conn = call(:post, "/users/#{user.id}/status", ctx.a, @admin, %{"status" => "inactive"})
      assert conn.status == 200, conn.resp_body

      conn = call(:delete, "/groups/#{group.id}/members/#{user.id}", ctx.a, @admin, nil)
      assert conn.status == 204, conn.resp_body

      conn = call(:delete, "/groups/#{group.id}", ctx.a, @admin, nil)
      assert conn.status == 204, conn.resp_body
    end

    test "P with the pin set but NO binding: nothing to protect, H1 still blocks minting",
         ctx do
      assert RoleRegistry.platform_admin_group_id(opts(ctx.p)) == :none
      group = insert_group!(ctx.p)
      user = insert_user!(ctx.p)

      conn = call(:post, "/groups/#{group.id}/members", ctx.p, @admin, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body

      # the POST /tokens guard does not depend on the binding
      conn =
        call(:post, "/tokens", ctx.p, @admin, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"]
        })

      assert_forbidden(conn, "mint without a binding")
    end

    test "pin UNSET: nobody has platform scope, so even the would-be operator is refused on the bound group (fails closed)",
         ctx do
      %{group: group} = world!(ctx)
      Fixture.unpin!()
      user = insert_user!(ctx.p)

      conn = call(:post, "/groups/#{group.id}/members", ctx.p, @operator, %{"user_id" => user.id})
      assert_forbidden(conn, "pin unset, group")
      assert user.id not in member_ids(ctx.p, group)

      conn =
        call(:post, "/tokens", ctx.p, @operator, %{
          "user_id" => user.id,
          "roles" => ["PLATFORM_ADMIN"]
        })

      assert_forbidden(conn, "pin unset, token")
    end
  end
end
