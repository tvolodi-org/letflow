Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountSheetRouterTest do
  @moduledoc """
  REQ-817 / GH #4374 (asset count K2) through the full `Letflow.Router` with real OIDC bearer tokens:
  K2-RT (the life of a count through the eight routes), K2-R4 (criterion 6: a chair of tenant A opens
  nothing of tenant B), K2-P1 (permission), K2-F1 (the flag). Committed tenants, Sandbox `:auto`,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.Modules.Assets.Counts

  setup do
    ctx = D.setup!([:a, :b, :n])
    n = S.tenant!("ast-ck2n", ctx.names.n, install: false)
    F.enable!(ctx.schema)
    b = D.tenant_b!(ctx)
    F.enable!(b.b.schema_name)
    {:ok, Map.merge(ctx, Map.merge(b, %{n: n, tok_n: S.token(ctx, :n, ["TENANT_ADMIN"])}))}
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  # A token whose user exists in the tenant (the first request provisions it); returns {token, user_id}.
  defp user_token(ctx, sub) do
    tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub)
    assert D.request(:get, "/counts", tok).status == 200
    {tok, Repo.one!(from(u in User, where: u.username == ^sub), prefix: ctx.schema).id}
  end

  describe "the life of a count" do
    test "K2-RT: open, lines, input, surplus, log, close, sheet, marks", ctx do
      s = ctx.schema
      m = ctx.ma
      {chair_tok, chair_user} = user_token(ctx, "chair-k2")
      {member_tok, member_user} = user_token(ctx, "member-k2")
      chair = F.employee!(s, m.unit, chair_user)
      member = F.employee!(s, m.unit, member_user)
      D.commission!(ctx, D.body(m))

      w = %{unit: m.unit, chair: chair, members: [member], a: m.location}
      created = D.request(:post, "/counts", chair_tok, F.input(w, F.window())) |> D.status!(201)
      id = created["id"]
      D.request(:post, "/counts/#{id}/issue", chair_tok, %{}) |> D.status!(200)

      # a body on an empty-body route is refused before anything happens
      refused = D.request(:post, "/counts/#{id}/open", chair_tok, %{"x" => 1}) |> D.status!(422)
      assert %{"reason" => "field_not_allowed", "field" => "x"} = refused

      assert D.request(:post, "/counts/#{id}/open", member_tok, %{})
             |> D.status!(422)
             |> Map.get("reason") ==
               "not_chair"

      opened = D.request(:post, "/counts/#{id}/open", chair_tok, %{}) |> D.status!(200)
      assert opened["status"] == "counting" and is_binary(opened["cut_off_at"])

      assert %{"rows" => [line], "next_cursor" => nil} =
               D.request(:get, "/counts/#{id}/lines", member_tok) |> D.status!(200)

      assert line["asset_id"] == m.fixed and line["book_quantity"] == "1"

      done =
        D.request(:put, "/counts/#{id}/lines/1", member_tok, %{"found" => true}) |> D.status!(200)

      assert done["counted_quantity"] == "1"

      assert D.request(:put, "/counts/#{id}/lines/1", member_tok, %{"found" => "yes"})
             |> D.status!(422)
             |> Map.get("field") == "found"

      surplus =
        D.request(:post, "/counts/#{id}/surplus-lines", member_tok, %{
          "description" => "a chair",
          "counted_quantity" => "1"
        })
        |> D.status!(201)

      assert surplus["line_no"] == 2

      assert %{"rows" => [_, _]} =
               D.request(:get, "/counts/#{id}/entries", member_tok) |> D.status!(200)

      assert D.request(:get, "/counts/#{id}/sheet-document", chair_tok).status == 404

      closed = D.request(:post, "/counts/#{id}/close", chair_tok, %{}) |> D.status!(200)
      assert closed["status"] == "counted" and String.starts_with?(closed["sheet_number"], "ACS")

      sheet = D.request(:get, "/counts/#{id}/sheet-document", member_tok) |> D.status!(200)
      assert sheet["number_label"] == closed["sheet_number"]

      body = %{"signer_employee_ids" => [chair, member, m.employee]}

      signed =
        D.request(:post, "/counts/#{id}/sheet-signatures", chair_tok, body) |> D.status!(200)

      assert signed["status"] == "sheet_signed"
    end
  end

  describe "criterion 6: isolation, permission, flag" do
    test "K2-R4: tenant A's chair cannot open tenant B's order, B's order is unchanged", ctx do
      sb = ctx.b.schema_name
      chair_b = F.employee!(sb, ctx.mb.unit, Ecto.UUID.generate())
      w = %{unit: ctx.mb.unit, chair: chair_b, members: [], a: ctx.mb.location}
      {:ok, %{"id" => b_id}} = Counts.create(sb, F.input(w, F.window()), F.opts())
      {:ok, _} = Counts.issue(sb, b_id, F.opts())

      unknown = D.request(:post, "/counts/#{Ecto.UUID.generate()}/open", ctx.tok_a, %{})
      foreign = D.request(:post, "/counts/#{b_id}/open", ctx.tok_a, %{})
      assert unknown.status == 404 and foreign.status == 404
      assert strip(foreign) == strip(unknown)

      for {method, path, body} <- [
            {:put, "/counts/#{b_id}/lines/1", %{"found" => true}},
            {:post, "/counts/#{b_id}/surplus-lines",
             %{"description" => "x", "counted_quantity" => "1"}},
            {:post, "/counts/#{b_id}/close", %{}},
            {:post, "/counts/#{b_id}/sheet-signatures", %{"signer_employee_ids" => []}},
            {:get, "/counts/#{b_id}/lines", nil},
            {:get, "/counts/#{b_id}/entries", nil},
            {:get, "/counts/#{b_id}/sheet-document", nil}
          ] do
        assert D.request(method, path, ctx.tok_a, body).status == 404, path
      end

      assert D.request(:get, "/counts/#{b_id}", ctx.tok_b) |> D.status!(200) |> Map.get("status") ==
               "ordered"
    end

    test "K2-P1: a TASK_WORKER is refused 403 on open, input and the reads", ctx do
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-k2")
      id = Ecto.UUID.generate()
      assert D.request(:post, "/counts/#{id}/open", worker, %{}).status == 403
      assert D.request(:put, "/counts/#{id}/lines/1", worker, %{"found" => true}).status == 403
      assert D.request(:get, "/counts/#{id}/lines", worker).status == 403
    end

    test "K2-F1: with the flag off all eight routes answer the 404 of a tenant without the module",
         ctx do
      F.disable!(ctx.schema)
      id = Ecto.UUID.generate()

      requests = [
        {:post, "/counts/#{id}/open", %{}},
        {:put, "/counts/#{id}/lines/1", %{"found" => true}},
        {:post, "/counts/#{id}/surplus-lines",
         %{"description" => "x", "counted_quantity" => "1"}},
        {:post, "/counts/#{id}/close", %{}},
        {:post, "/counts/#{id}/sheet-signatures", %{"signer_employee_ids" => []}},
        {:get, "/counts/#{id}/lines", nil},
        {:get, "/counts/#{id}/entries", nil},
        {:get, "/counts/#{id}/sheet-document", nil}
      ]

      for {method, path, body} <- requests do
        mine = D.request(method, path, ctx.tok_a, body)
        theirs = D.request(method, path, ctx.tok_n, body)
        assert mine.status == 404 and theirs.status == 404, path
        assert strip(mine) == strip(theirs), path
      end
    end
  end
end
