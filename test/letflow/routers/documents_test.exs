defmodule Letflow.Routers.DocumentsTest do
  @moduledoc """
  REQ-536 / GH #3106, part (b): the three document routes of `Letflow.Routers.Documents`
  (decision 0063 S4, S5, S7; tests A7, A8, A9). Design: state/tasks/T-0393/design.md section 6,
  IDs T1..T8 and C1 (the INV-10 cross-tenant negative test).

    * T1 the permission check comes first: the same 403 for an existing and an absent id;
    * T2 order: 422 (body) before 404 (lookup) before 409 (state);
    * T3 a node-scoped holder under `on`: in scope 200, out of scope and absent the same 404;
    * T4 / C1 an unknown key and a key of another tenant are the same 404;
    * T5 refusals write no audit event, a success writes exactly one;
    * T6 policy route: happy path, broken tie, missing reason_code;
    * T7 policy route under `on`: a node-scoped grant is refused 403, a tenant-wide one succeeds;
    * T8 set, release, set through the routes.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture,
    only: [insert_document!: 4, insert_type!: 3, exec!: 2, table: 2]

  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @router Letflow.Routers.Documents
  @role "TENANT_ADMIN"
  @hold %{"reason_code" => "legal_matter", "reason_note" => "freeze for case 17"}
  @release %{"reason_code" => "case_closed", "reason_note" => "case closed"}
  @policy %{
    "retention_period_days" => 30,
    "retention_from" => "issued",
    "retention_action" => "purge",
    "reason_code" => "policy_review"
  }

  defp world!(slug) do
    fx = S.tenant!(slug)
    key = insert_type!(fx.schema_name, fx.tenant_id, "req536_type")
    %{fx: fx, key: key}
  end

  defp doc!(w, opts \\ []), do: insert_document!(w.fx.schema_name, w.fx.tenant_id, w.key, opts)

  defp call(fx, method, path, body, user_id \\ nil, roles \\ [@role], mode \\ :off) do
    On.call(@router, method, path, fx, user_id || fx.admin.id, roles, mode, body)
  end

  defp hold(fx, id, body \\ @hold, opts \\ []),
    do:
      call(
        fx,
        :post,
        "/#{id}/hold",
        body,
        opts[:user],
        opts[:roles] || [@role],
        opts[:mode] || :off
      )

  defp release(fx, id, body \\ @release), do: call(fx, :post, "/#{id}/hold/release", body)

  defp policy(fx, key, body, opts \\ []),
    do:
      call(
        fx,
        :put,
        "/types/#{key}/retention",
        body,
        opts[:user],
        opts[:roles] || [@role],
        opts[:mode] || :off
      )

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp doc_events(fx) do
    Letflow.Repo.query!(
      "SELECT action FROM #{table(fx.schema_name, "audit_entries")} WHERE action LIKE 'document.%' ORDER BY timestamp, id",
      []
    ).rows
    |> Enum.map(&hd/1)
  end

  defp doc_row(fx, id) do
    exec!(
      "SELECT on_hold, hold_reason_code, hold_cleared_at IS NOT NULL FROM #{table(fx.schema_name, "documents")} WHERE id = $1",
      [id]
    ).rows
  end

  defp type_row(fx, key) do
    exec!(
      "SELECT retention_period_days, retention_from, retention_action FROM #{table(fx.schema_name, "document_types")} WHERE key = $1",
      [key]
    ).rows
  end

  # A TENANT_ADMIN-role holder whose only grant is scoped to one node, a UUID that documents can use.
  defp scoped_holder!(fx) do
    user = RSG.user!(fx.schema_name)
    node = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, node, nil}, fx.schema_name)
    :ok = RSG.raw_user_row!(fx.schema_name, user.id, @role, node)
    {user, node}
  end

  defp same_response?(a, b) do
    a.status == b.status and a.resp_body == b.resp_body and a.resp_headers == b.resp_headers
  end

  describe "T1 permission first" do
    test "a caller without the permission gets the same 403 for an existing and an absent id" do
      w = world!("r536-t1")
      id = doc!(w)
      absent = Ecto.UUID.generate()
      user = Ecto.UUID.generate()

      for roles <- [[], ["TASK_WORKER"]] do
        a = hold(w.fx, id, @hold, user: user, roles: roles)
        b = hold(w.fx, absent, @hold, user: user, roles: roles)
        assert a.status == 403
        assert same_response?(a, b)

        c = call(w.fx, :post, "/#{id}/hold/release", @release, user, roles)
        d = call(w.fx, :post, "/#{absent}/hold/release", @release, user, roles)
        assert c.status == 403
        assert same_response?(c, d)

        e = policy(w.fx, w.key, @policy, user: user, roles: roles)
        f = policy(w.fx, "no_such_key", @policy, user: user, roles: roles)
        assert e.status == 403
        assert same_response?(e, f)
      end

      assert doc_events(w.fx) == []
      assert doc_row(w.fx, id) == [[false, nil, false]]
    end
  end

  describe "T2 order of checks" do
    test "422 before 404 before 409" do
      w = world!("r536-t2")
      id = doc!(w)
      absent = Ecto.UUID.generate()

      assert hold(w.fx, absent, %{}).status == 422

      assert hold(w.fx, absent, %{"reason_code" => "legal_matter", "reason_note" => " "}).status ==
               422

      assert hold(w.fx, absent).status == 404
      assert hold(w.fx, "not-a-uuid").status == 404

      assert hold(w.fx, id).status == 200
      assert hold(w.fx, id).status == 409
      # a bad body on a held document is still 422, not 409
      assert hold(w.fx, id, %{"reason_code" => "legal_matter"}).status == 422
      assert doc_events(w.fx) == ["document.hold_set"]
    end
  end

  describe "T3 scoped holder under on" do
    test "in scope 200; out of scope and absent: the same 404 on both hold routes" do
      w = world!("r536-t3")
      {user, node} = scoped_holder!(w.fx)
      mine = doc!(w, issuing_org_unit_id: node)
      theirs = doc!(w, issuing_org_unit_id: Ecto.UUID.generate())
      absent = Ecto.UUID.generate()
      opts = [user: user.id, mode: :on]

      out = hold(w.fx, theirs, @hold, opts)
      gone = hold(w.fx, absent, @hold, opts)
      assert out.status == 404
      assert same_response?(out, gone)
      assert doc_row(w.fx, theirs) == [[false, nil, false]]

      ok = hold(w.fx, mine, @hold, opts)
      assert ok.status == 200

      assert json(ok) == %{
               "document_id" => mine,
               "on_hold" => true,
               "reason_code" => "legal_matter"
             }

      refute ok.resp_body =~ "freeze"

      path = fn id -> "/#{id}/hold/release" end
      out = call(w.fx, :post, path.(theirs), @release, user.id, [@role], :on)
      gone = call(w.fx, :post, path.(absent), @release, user.id, [@role], :on)
      assert out.status == 404
      assert same_response?(out, gone)

      assert call(w.fx, :post, path.(mine), @release, user.id, [@role], :on).status == 200
      assert doc_events(w.fx) == ["document.hold_set", "document.hold_cleared"]
    end

    test "a tenant-wide holder under on reaches every document" do
      w = world!("r536-t3w")
      id = doc!(w)
      assert hold(w.fx, id, @hold, mode: :on).status == 200
    end
  end

  describe "T5 audit on refusals" do
    test "403, 404, 409 and 422 write nothing; a success writes exactly one event" do
      w = world!("r536-t5")
      id = doc!(w)

      assert hold(w.fx, id, @hold, user: Ecto.UUID.generate(), roles: []).status == 403
      assert hold(w.fx, Ecto.UUID.generate()).status == 404
      assert hold(w.fx, id, %{}).status == 422
      assert release(w.fx, id).status == 409
      assert doc_events(w.fx) == []

      assert hold(w.fx, id).status == 200
      assert doc_events(w.fx) == ["document.hold_set"]
      assert hold(w.fx, id).status == 409
      assert doc_events(w.fx) == ["document.hold_set"]
    end
  end

  describe "T6 policy route" do
    test "a valid body changes the columns and writes the event; an unchanged body is a no-op" do
      w = world!("r536-t6")

      conn = policy(w.fx, w.key, @policy)
      assert conn.status == 200

      assert json(conn) == %{
               "type_key" => w.key,
               "retention_period_days" => 30,
               "retention_from" => "issued",
               "retention_action" => "purge",
               "changed" => true
             }

      assert type_row(w.fx, w.key) == [[30, "issued", "purge"]]
      assert doc_events(w.fx) == ["document.retention_policy_changed"]

      again = policy(w.fx, w.key, @policy)
      assert again.status == 200
      assert json(again)["changed"] == false
      assert length(doc_events(w.fx)) == 1

      forever = %{@policy | "retention_action" => "keep"} |> Map.put("retention_period_days", nil)
      assert policy(w.fx, w.key, forever).status == 200
      assert type_row(w.fx, w.key) == [[nil, "issued", "keep"]]
    end

    test "a broken tie, a missing field or a missing reason_code is 422 and changes nothing" do
      w = world!("r536-t6b")
      before = type_row(w.fx, w.key)

      for bad <- [
            %{@policy | "retention_action" => "keep"},
            Map.put(@policy, "retention_period_days", nil),
            Map.delete(@policy, "retention_period_days"),
            Map.delete(@policy, "reason_code"),
            %{@policy | "retention_from" => "never"},
            %{@policy | "retention_period_days" => 0},
            %{}
          ] do
        assert policy(w.fx, w.key, bad).status == 422
      end

      assert type_row(w.fx, w.key) == before
      assert doc_events(w.fx) == []
    end

    test "T4: an unknown key is 404" do
      w = world!("r536-t4")
      conn = policy(w.fx, "no_such_type", @policy)
      assert conn.status == 404
      assert doc_events(w.fx) == []
    end
  end

  describe "T7 policy route needs a tenant-wide grant" do
    test "a node-scoped grant is 403 under on; a tenant-wide admin succeeds" do
      w = world!("r536-t7")
      {user, _node} = scoped_holder!(w.fx)

      conn = policy(w.fx, w.key, @policy, user: user.id, mode: :on)
      assert conn.status == 403
      assert json(conn)["detail"] == "insufficient permissions"
      assert type_row(w.fx, w.key) == [[nil, "issued", "keep"]]
      assert doc_events(w.fx) == []

      assert policy(w.fx, w.key, @policy, mode: :on).status == 200
      assert type_row(w.fx, w.key) == [[30, "issued", "purge"]]
    end
  end

  describe "T8 set, release, set" do
    test "the routes follow the state machine" do
      w = world!("r536-t8")
      id = doc!(w)

      assert hold(w.fx, id).status == 200
      assert doc_row(w.fx, id) == [[true, "legal_matter", false]]
      assert hold(w.fx, id).status == 409

      rel = release(w.fx, id)
      assert rel.status == 200

      assert json(rel) == %{
               "document_id" => id,
               "on_hold" => false,
               "reason_code" => "case_closed"
             }

      assert release(w.fx, id).status == 409

      again = hold(w.fx, id, %{"reason_code" => "second_matter", "reason_note" => "again"})
      assert again.status == 200
      assert doc_row(w.fx, id) == [[true, "second_matter", false]]

      assert doc_events(w.fx) == [
               "document.hold_set",
               "document.hold_cleared",
               "document.hold_set"
             ]
    end

    test "a forced audit failure raises out of the router (the pipeline answers 500) and rolls back" do
      w = world!("r536-t8f")
      id = doc!(w)

      assert_raise Plug.Conn.WrapperError, fn ->
        ExUnit.CaptureLog.capture_log(fn ->
          S.with_audit_fault(w.fx, "document.hold_set", fn -> hold(w.fx, id) end)
        end)
      end

      assert doc_row(w.fx, id) == [[false, nil, false]]
      assert doc_events(w.fx) == []
    end
  end

  describe "C1 INV-10 cross-tenant" do
    test "tenant B's admin gets the absent-id 404 for tenant A's key and document" do
      a = world!("r536-c1a")
      b = world!("r536-c1b")
      key_a = insert_type!(a.fx.schema_name, a.fx.tenant_id, "req536_only_a")
      id_a = doc!(%{a | key: key_a})
      absent = Ecto.UUID.generate()

      before_type = type_row(a.fx, key_a)
      before_doc = doc_row(a.fx, id_a)

      # the type key exists only in A
      assert type_row(b.fx, key_a) == []

      assert same_response?(hold(b.fx, id_a), hold(b.fx, absent))
      assert hold(b.fx, id_a).status == 404

      rel_a = call(b.fx, :post, "/#{id_a}/hold/release", @release)
      rel_absent = call(b.fx, :post, "/#{absent}/hold/release", @release)
      assert rel_a.status == 404
      assert same_response?(rel_a, rel_absent)

      pol_a = policy(b.fx, key_a, @policy)
      pol_absent = policy(b.fx, "req536_nobody_has_it", @policy)
      assert pol_a.status == 404
      assert same_response?(pol_a, pol_absent)

      # a tenant identifier in the body changes nothing
      sneaky = Map.merge(@hold, %{"tenant_id" => a.fx.tenant_id, "tenant" => a.fx.schema_name})
      assert hold(b.fx, id_a, sneaky).status == 404

      assert type_row(a.fx, key_a) == before_type
      assert doc_row(a.fx, id_a) == before_doc
      assert doc_events(a.fx) == []
      assert doc_events(b.fx) == []
    end
  end
end
