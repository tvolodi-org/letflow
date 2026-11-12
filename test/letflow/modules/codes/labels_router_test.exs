Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.LabelsRouterTest do
  @moduledoc """
  GH #4017 / REQ-779: `POST /api/v1/modules/codes/labels` through the full pipeline with real
  bearer tokens (R3-1..R5-3). `async: false`: tenant provisioning runs DDL.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Codes.Labels
  alias Letflow.Repo

  @base "/api/v1/modules/codes"

  setup do
    a = Fx.installed_tenant!("gh4017a")
    b = Fx.installed_tenant!("gh4017b")
    %{a: a, b: b, admin: user!(a, ["TENANT_ADMIN"]), admin_b: user!(b, ["TENANT_ADMIN"])}
  end

  defp user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh4017-user-#{Ecto.UUID.generate()}",
        display_name: "Codes Labels Test User",
        email: "gh4017-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema)

    %{user_id: user.id, plaintext: plaintext, slug: ctx.slug}
  end

  defp labels(user, body) do
    conn(:post, @base <> "/labels", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-4017")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: M.json(conn)
  defp strip(body), do: M.strip(body)

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp counts(schema) do
    import Ecto.Query, only: [from: 2]

    n =
      Repo.aggregate(
        from(l in Letflow.Entities.Record.Latest, where: l.entity_type == "code_tag"),
        :count,
        prefix: schema
      )

    {n, Repo.query!("SELECT count(*) FROM \"#{schema}\".audit_entries").rows}
  end

  test "R3-1 200 PDF equal to Labels.render of the two codes in order", ctx do
    t1 = Fx.tag!(ctx.a.schema, "L-1")
    t2 = Fx.tag!(ctx.a.schema, "L-2", %{"kind" => "qr"})
    before = counts(ctx.a.schema)
    conn = labels(ctx.admin, %{"code_ids" => [t2.record_id, t1.record_id]})
    assert conn.status == 200
    assert ["application/pdf"] = get_resp_header(conn, "content-type")

    assert ["attachment; filename=\"code-labels.pdf\""] =
             get_resp_header(conn, "content-disposition")

    assert ["no-store"] = get_resp_header(conn, "cache-control")

    {:ok, a} = Codes.lookup(ctx.a.schema, t2.record_id)
    {:ok, b} = Codes.lookup(ctx.a.schema, t1.record_id)
    assert {:ok, pdf} = Labels.render([a, b])
    assert conn.resp_body == pdf
    # R3-2 nothing written
    assert counts(ctx.a.schema) == before
  end

  test "R4-1 and R4-2 body shape", ctx do
    t = Fx.tag!(ctx.a.schema, "B-1")
    id = t.record_id

    for {body, field} <- [
          {%{"code_ids" => [id], "x" => 1}, nil},
          {%{}, "code_ids"},
          {%{"code_ids" => "a"}, "code_ids"},
          {%{"code_ids" => []}, "code_ids"},
          {%{"code_ids" => List.duplicate(id, 1001)}, "code_ids"},
          {%{"code_ids" => [1]}, "code_ids"},
          {%{"_json" => [id]}, "code_ids"}
        ] do
      b = ok!(labels(ctx.admin, body), 422)
      assert b["reason"] in ["field_invalid", "field_not_allowed"]
      if field, do: assert(b["field"] == field)
    end
  end

  test "R4-3 duplicate id names the second index", ctx do
    t = Fx.tag!(ctx.a.schema, "D-1")
    b = ok!(labels(ctx.admin, %{"code_ids" => [t.record_id, String.upcase(t.record_id)]}), 422)
    assert b["reason"] == "entry_invalid"
    assert b["index"] == 1
    assert b["entry_reason"] == "duplicate_in_batch"
  end

  test "R4-4 unknown, bad, deleted and history ids are the same 404", ctx do
    tag = Fx.tag!(ctx.a.schema, "N-1")
    gone = Fx.tag!(ctx.a.schema, "N-2")
    Fx.delete!(ctx.a.schema, gone)
    asg = Fx.assign!(ctx.a.schema, tag, "location_node", Ecto.UUID.generate())

    bodies =
      for id <- ["not-a-uuid", Ecto.UUID.generate(), gone.record_id, asg.record_id] do
        strip(ok!(labels(ctx.admin, %{"code_ids" => [tag.record_id, id]}), 404))
      end

    assert length(Enum.uniq(bodies)) == 1
  end

  test "R4-5..R4-9 refusal reasons carry index and reason, never the value", ctx do
    ok = Fx.tag!(ctx.a.schema, "OK-1")
    epc = Fx.tag!(ctx.a.schema, "EPC-SECRET", %{"kind" => "epc"})
    ret = Fx.tag!(ctx.a.schema, "RET-SECRET")
    Fx.set_status!(ctx.a.schema, ret, "retired")
    long = Fx.tag!(ctx.a.schema, String.duplicate("9", 21))

    for {tag, reason} <- [
          {epc, "kind_not_printable"},
          {ret, "code_retired"},
          {long, "value_too_long"}
        ] do
      conn = labels(ctx.admin, %{"code_ids" => [ok.record_id, tag.record_id]})
      b = ok!(conn, 422)
      assert b["reason"] == "entry_invalid"
      assert b["index"] == 1
      assert b["entry_reason"] == reason
      refute conn.resp_body =~ "SECRET"
    end
  end

  test "R5-1 other roles are refused", ctx do
    t = Fx.tag!(ctx.a.schema, "R-1")

    for role <- ["PROCESS_DESIGNER", "PROCESS_OPERATOR", "TASK_WORKER", "TENANT_AUDITOR"] do
      assert labels(user!(ctx.a, [role]), %{"code_ids" => [t.record_id]}).status == 403, role
    end
  end

  test "R5-2 another tenant's code id is 404 and rows are unchanged", ctx do
    t = Fx.tag!(ctx.a.schema, "X-1")
    before = counts(ctx.a.schema)
    own = Fx.tag!(ctx.b.schema, "X-B")

    unknown = strip(ok!(labels(ctx.admin_b, %{"code_ids" => [Ecto.UUID.generate()]}), 404))
    foreign = strip(ok!(labels(ctx.admin_b, %{"code_ids" => [t.record_id]}), 404))
    assert foreign == unknown
    assert labels(ctx.admin_b, %{"code_ids" => [own.record_id]}).status == 200
    assert counts(ctx.a.schema) == before
  end

  test "R5-3 the route is in the manifest policies" do
    assert {"POST", "/labels", :CodesRead} in Codes.manifest().route_policies
  end
end
