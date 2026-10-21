defmodule Letflow.Routers.SelfServiceScopeTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-b, AC 21 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  4.1 to 4.4, 10.1 T-S2, T-S3, T-S5, T-S6, T-S7, T-S9; spec `test/specs/REQ-518-2c-i-b.md`): the
  `:self_service` routes `GET /me/memberships` (M1), `GET /me/modules` (M2) (REQ-449 later added
  `GET /me/access`, covered by one extra test below) and
  `GET /help/resolved` (H1) through their REAL routers with the per-request enforcement mode in
  the `auth_context`.

    * T-S2: under `on` a caller whose role is held ONLY through a scoped row gets 200 from all
      three (the 2b answer for the default class was 403);
    * T-S3 / T-S5: a caller failing the coarse role check gets the unchanged 403 under every mode
      (the class passes through only AFTER the coarse allow), and a request with no
      `auth_context` never reaches the handler;
    * T-S6: under `shadow` these routes are counted as requests only, no reason, no would-deny;
    * T-S7: M1 holds only the caller's own memberships (a second user's never appear);
    * T-S9 (SEC ruling R-2): `process_definition_id` is only a FILTER over help rows, so an existing
      definition with no help row and a nonexistent definition give BYTE-IDENTICAL responses (and
      the same number of statements) for a scoped-only user: the route is not a definition-existence
      oracle.

  `async: false`: committed writes and VM-global telemetry / ETS counters.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Help
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantMembership
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @me Letflow.Routers.Me
  @help Letflow.Routers.Help
  @worker "TASK_WORKER"
  @evidence :letflow_scope_shadow_evidence
  @would_deny [:letflow, :scope, :shadow, :would_deny]

  setup do
    fx = S.tenant!("r518-ss")
    {:ok, fx: fx, scoped: On.scoped_holder!(fx, @worker)}
  end

  defp get(router, path, fx, user_id, roles, mode),
    do: On.call(router, :get, path, fx, user_id, roles, mode, nil)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ===========================================================================================
  describe "T-S2 a scoped-only caller reaches all three routes under on" do
    test "M1 and M2 answer 200", %{fx: fx, scoped: scoped} do
      memberships = get(@me, "/memberships", fx, scoped.id, [@worker], :on)
      assert memberships.status == 200
      assert [%{"tenant_id" => tenant_id}] = json(memberships)["memberships"]
      assert tenant_id == fx.tenant.id

      modules = get(@me, "/modules", fx, scoped.id, [@worker], :on)
      assert modules.status == 200
      assert json(modules) == %{"installed_modules" => []}
    end

    test "REQ-449 /me/access answers 200 for a scoped-only caller under on", %{
      fx: fx,
      scoped: scoped
    } do
      access = get(@me, "/access", fx, scoped.id, [@worker], :on)
      assert access.status == 200
      assert json(access)["roles"] == [@worker]
    end

    test "H1 answers 200 with the live help row", %{fx: fx, scoped: scoped} do
      screen_id = unique_screen()
      live = live!(fx, %{screen_id: screen_id})

      conn = get(@help, "/resolved?screen_id=#{screen_id}", fx, scoped.id, [@worker], :on)
      assert conn.status == 200
      assert json(conn)["id"] == live.id
    end

    test "the answers equal the tenant-wide caller's, and equal the answers under off (the class changes nothing for a holder of the coarse permission)",
         %{fx: fx, scoped: scoped} do
      wide = RSG.user!(fx.schema_name)
      :ok = RSG.raw_user_row!(fx.schema_name, wide.id, @worker, nil)
      screen_id = unique_screen()
      _live = live!(fx, %{screen_id: screen_id})

      for path <- ["/memberships", "/modules"] do
        on = get(@me, path, fx, scoped.id, [@worker], :on)
        off = get(@me, path, fx, scoped.id, [@worker], :off)
        wide_on = get(@me, path, fx, wide.id, [@worker], :on)

        assert on.status == 200 and off.status == 200 and wide_on.status == 200, path
        assert on.resp_body == off.resp_body, path
        assert on.resp_body == wide_on.resp_body, path
      end

      path = "/resolved?screen_id=#{screen_id}"
      on = get(@help, path, fx, scoped.id, [@worker], :on)
      assert on.resp_body == get(@help, path, fx, scoped.id, [@worker], :off).resp_body
      assert on.resp_body == get(@help, path, fx, wide.id, [@worker], :on).resp_body
    end
  end

  # ===========================================================================================
  describe "T-S3 / T-S5 the class passes through only AFTER the coarse allow" do
    test "a caller failing the coarse role check is refused 403 on every route in every mode, with the same body in every mode",
         %{fx: fx} do
      stranger = RSG.user!(fx.schema_name)

      for {router, path} <- [
            {@me, "/memberships"},
            {@help, "/resolved?screen_id=x"}
          ] do
        refused =
          for mode <- [:off, :shadow, :on] do
            conn = get(router, path, fx, stranger.id, ["CANDIDATE"], mode)
            assert conn.status == 403, "#{path} under #{mode}"
            assert conn.halted, "#{path} under #{mode}"
            conn
          end

        assert refused |> Enum.map(& &1.resp_body) |> Enum.uniq() |> length() == 1, path
      end
    end

    test "a caller with no roles at all is refused 403 on M2, M1 and H1 under on", %{fx: fx} do
      stranger = RSG.user!(fx.schema_name)

      for {router, path} <- [
            {@me, "/memberships"},
            {@help, "/resolved?screen_id=x"}
          ] do
        conn = get(router, path, fx, stranger.id, [], :on)
        assert conn.status == 403, path
        assert conn.halted
      end
    end

    test "an unauthenticated request (no auth_context) never reaches the handler: halted, no data" do
      for {router, path} <- [
            {@me, "/memberships"},
            {@me, "/modules"},
            {@help, "/resolved?screen_id=x"}
          ] do
        conn = Plug.Test.conn(:get, path) |> then(&router.call(&1, router.init([])))

        assert conn.halted, path
        assert conn.status in 400..599, path
        refute conn.resp_body =~ "memberships", path
        refute conn.resp_body =~ "installed_modules", path
      end
    end
  end

  # ===========================================================================================
  describe "T-S6 shadow counts these routes as requests only" do
    test "a scoped-only caller on the six reclassified routes under shadow adds requests and NO reason, no would-deny event",
         %{fx: fx, scoped: scoped} do
      admin_scoped = On.scoped_holder!(fx, "TENANT_ADMIN")
      ref = make_ref()

      :telemetry.attach(
        {__MODULE__, ref},
        @would_deny,
        fn _event, _measurements, metadata, pid -> send(pid, {:would_deny, ref, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      :ets.delete_all_objects(@evidence)
      on_exit(fn -> :ets.delete_all_objects(@evidence) end)

      calls = [
        fn -> get(@me, "/memberships", fx, scoped.id, [@worker], :shadow) end,
        fn -> get(@me, "/modules", fx, scoped.id, [@worker], :shadow) end,
        fn -> get(@help, "/resolved?screen_id=x", fx, scoped.id, [@worker], :shadow) end,
        fn ->
          On.call(Letflow.Routers.Entities, :post, "/query", fx, scoped.id, [@worker], :shadow, %{
            "entity_type" => "no_such_type_518"
          })
        end,
        fn ->
          On.call(
            Letflow.Routers.Entities,
            :post,
            "/query/aggregate",
            fx,
            scoped.id,
            [@worker],
            :shadow,
            %{
              "entity_type" => "no_such_type_518",
              "aggregates" => [%{"fn" => "count"}]
            }
          )
        end,
        fn ->
          On.call(
            Letflow.Routers.Entities,
            :post,
            "/records/no_such_type_518/export",
            fx,
            admin_scoped.id,
            ["TENANT_ADMIN"],
            :shadow,
            %{"entity_type" => "no_such_type_518"}
          )
        end
      ]

      for call <- calls, do: call.()

      refute_received {:would_deny, ^ref, _metadata}

      counted =
        @evidence
        |> :ets.match_object({{fx.schema_name, :_, :_}, :_})
        |> Enum.map(fn {{_prefix, _day, metric}, count} -> {metric, count} end)
        |> Enum.sort()

      assert counted == [requests: 6]
    end
  end

  # ===========================================================================================
  describe "T-S7 M1 holds only the caller's own memberships" do
    test "a second user's tenant memberships never appear in the first user's body, and appear in the second user's own",
         %{fx: fx, scoped: scoped} do
      other_user = unique_email_user!(fx)
      other_tenant = insert_tenant!("r518-ss-other")

      %TenantMembership{}
      |> TenantMembership.create_changeset(%{
        subject_key: other_user.email,
        tenant_id: other_tenant.id,
        display_label: "Other Co 518"
      })
      |> Repo.insert!()

      mine = get(@me, "/memberships", fx, scoped.id, [@worker], :on)
      assert mine.status == 200

      refute mine.resp_body =~ other_tenant.id
      refute mine.resp_body =~ other_tenant.slug
      refute mine.resp_body =~ "Other Co 518"
      assert Enum.map(json(mine)["memberships"], & &1["tenant_id"]) == [fx.tenant.id]

      theirs = get(@me, "/memberships", fx, other_user.id, [@worker], :on)
      assert theirs.status == 200
      tenant_ids = Enum.map(json(theirs)["memberships"], & &1["tenant_id"])
      assert Enum.sort(tenant_ids) == Enum.sort([fx.tenant.id, other_tenant.id])
    end

    test "the first user's identity is the context's, not a query parameter or header", %{
      fx: fx,
      scoped: scoped
    } do
      other_user = unique_email_user!(fx)
      other_tenant = insert_tenant!("r518-ss-spoof")

      %TenantMembership{}
      |> TenantMembership.create_changeset(%{
        subject_key: other_user.email,
        tenant_id: other_tenant.id,
        display_label: "Spoof Co 518"
      })
      |> Repo.insert!()

      conn =
        On.call(
          @me,
          :get,
          "/memberships?user_id=#{other_user.id}&email=#{URI.encode_www_form(other_user.email)}",
          fx,
          scoped.id,
          [@worker],
          :on,
          nil
        )

      assert conn.status == 200
      refute conn.resp_body =~ other_tenant.id
    end
  end

  # ===========================================================================================
  describe "T-S9 (R-2) /help/resolved is not a definition-existence oracle" do
    test "existing vs nonexistent definition id: byte-identical response and equal statement count at every stage",
         %{fx: fx, scoped: scoped} do
      screen_id = unique_screen()
      existing = create_definition!(fx)
      other = create_definition!(fx)
      missing = Ecto.UUID.generate()

      ask = fn definition_id ->
        Fixture.capture_repo_queries(fn ->
          get(
            @help,
            "/resolved?screen_id=#{screen_id}&process_definition_id=#{definition_id}",
            fx,
            scoped.id,
            [@worker],
            :on
          )
        end)
      end

      # (A) no help row at all: both are the 404
      assert_indistinguishable(ask.(existing.id), ask.(missing), 404)

      # (B) a row bound to a DIFFERENT definition only: still the 404 for both
      _bound_other = live!(fx, %{screen_id: screen_id, process_definition_id: other.id})
      assert_indistinguishable(ask.(existing.id), ask.(missing), 404)

      # (C) a general row exists: both get that same row, stale false
      general = live!(fx, %{screen_id: screen_id})
      pair_existing = ask.(existing.id)
      assert_indistinguishable(pair_existing, ask.(missing), 200)
      {conn_existing, _queries} = pair_existing
      assert json(conn_existing)["id"] == general.id
      assert json(conn_existing)["stale"] == false

      # (D) control: the request id IS a filter over help rows - a row bound to the existing
      # definition now wins for that id, while the nonexistent id still gets the general row.
      bound = live!(fx, %{screen_id: screen_id, process_definition_id: existing.id})
      {with_existing, _} = ask.(existing.id)
      {with_missing, _} = ask.(missing)

      assert json(with_existing)["id"] == bound.id
      assert json(with_missing)["id"] == general.id
    end

    test "stale comes from the SELECTED row's own definition, never from the requested id",
         %{fx: fx, scoped: scoped} do
      screen_id = unique_screen()
      definition = create_definition!(fx)
      _bound = live!(fx, %{screen_id: screen_id, process_definition_id: definition.id})

      assert {:ok, _} =
               Definitions.update(definition.id, %{version: "9.0.0"}, prefix: fx.schema_name)

      path = "/resolved?screen_id=#{screen_id}"

      asked_for_it =
        get(
          @help,
          path <> "&process_definition_id=#{definition.id}",
          fx,
          scoped.id,
          [@worker],
          :on
        )

      asked_for_nothing = get(@help, path, fx, scoped.id, [@worker], :on)

      # no general row exists, so without the filter nothing resolves; with it the row is stale
      assert asked_for_it.status == 200
      assert json(asked_for_it)["stale"] == true
      assert asked_for_nothing.status == 404
    end
  end

  # ---- fixtures -------------------------------------------------------------------------------

  defp assert_indistinguishable({conn_a, queries_a}, {conn_b, queries_b}, status) do
    assert conn_a.status == status
    assert conn_b.status == status
    assert conn_a.resp_body == conn_b.resp_body
    assert conn_a.resp_headers == conn_b.resp_headers
    assert length(queries_a) == length(queries_b)
  end

  defp unique_screen, do: "r518-screen-#{System.unique_integer([:positive])}"

  # A second tenant row (global table) with a collision-proof slug, removed again with its
  # memberships when the test exits, so no run leaves a row another run could collide with.
  defp insert_tenant!(slug_prefix) do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: "#{slug_prefix}-#{String.slice(Ecto.UUID.generate(), 0, 8)}",
          display_name: "Other Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(m in TenantMembership, where: m.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    tenant
  end

  # A real user whose e-mail (the subject key of memberships, a GLOBAL table) can never collide
  # with a row another run left behind.
  defp unique_email_user!(fx) do
    fx.schema_name
    |> RSG.user!()
    |> Ecto.Changeset.change(%{email: "r518-#{Ecto.UUID.generate()}@example.com"})
    |> Repo.update!(prefix: fx.schema_name)
  end

  defp create_definition!(fx) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: "r518-def-#{System.unique_integer([:positive])}",
                 version: "1.0.0",
                 graph: %{
                   "nodes" => [
                     %{"id" => "start", "node_type" => "START"},
                     %{"id" => "end", "node_type" => "END"}
                   ],
                   "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
                 },
                 created_by: Ecto.UUID.generate()
               },
               prefix: fx.schema_name
             )

    definition
  end

  defp live!(fx, overrides) do
    attrs =
      Map.merge(
        %{title: "R518 help", body: "Some help text.", created_by: Ecto.UUID.generate()},
        overrides
      )

    assert {:ok, help} = Help.create_draft(attrs, prefix: fx.schema_name)
    assert {:ok, published} = Help.publish(help.id, prefix: fx.schema_name)
    published
  end
end
