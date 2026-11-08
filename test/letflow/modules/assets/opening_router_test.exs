Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.OpeningRouterTest do
  @moduledoc """
  GH #4037 (assets G5 part 1): the draft side and the check route of the asset opening document
  through the full `Letflow.Router` with real OIDC bearer tokens. D1 save and reads, D2 replace and
  discard, C1 the check writes nothing, C3 check refusals, I2 issue is refused 409
  `posting_not_available`, N1 INV-10 cross-tenant negatives, T1 access, R3 the document type exists.
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Documents.DocumentType
  alias Letflow.Repo

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  defp save!(ctx, extra \\ %{}), do: D.save!(ctx, D.opening_body(ctx.ma, extra))

  describe "D1 save and reads" do
    test "creates a draft with the five line keys and no event_time", ctx do
      m = ctx.ma
      doc = save!(ctx)

      assert doc["kind"] == "opening" and doc["state"] == "draft"
      assert doc["number"] == nil and doc["issued_at"] == nil
      assert doc["org_unit_id"] == m.unit and doc["note"] == "opening balance"
      refute Map.has_key?(doc, "event_time")

      assert [line] = doc["lines"]

      assert Map.take(
               line,
               ~w(line_no asset_id location_id material_responsible_id actual_user_id quantity)
             ) ==
               %{
                 "line_no" => 1,
                 "asset_id" => m.fixed,
                 "location_id" => m.location,
                 "material_responsible_id" => m.employee,
                 "actual_user_id" => m.employee2,
                 "quantity" => "1.000000000"
               }

      assert D.get!(ctx, doc["id"]) == doc
      row = Repo.get!(Letflow.Documents.Document, doc["id"], prefix: ctx.schema)
      assert row.type_key == "assets_opening" and row.issuing_org_unit_id == m.unit
    end

    test "the list filters by kind and shows no event time", ctx do
      doc = save!(ctx)
      D.save!(ctx)
      rows = D.request(:get, "/documents?kind=opening&state=draft", ctx.tok_a) |> D.status!(200)

      assert [%{"id" => id, "kind" => "opening", "state" => "draft", "event_time" => nil}] =
               rows["rows"]

      assert id == doc["id"]
    end

    test "the document type AOP is registered (yearly, pad 6)", ctx do
      save!(ctx)
      type = Repo.get!(DocumentType, "assets_opening", prefix: ctx.schema)
      assert {type.owner_module, type.number_prefix, type.number_pad} == {"assets", "AOP", 6}
      assert type.numbering_scope == :year
    end

    test "event_time and a header location are field_not_allowed", ctx do
      for key <- ["event_time", "location_id"] do
        body = D.opening_body(ctx.ma, %{key => "x"})
        conn = D.request(:post, "/documents", ctx.tok_a, body)
        json = D.status!(conn, 422)
        assert json["reason"] == "field_not_allowed" and json["field"] == key
      end
    end
  end

  describe "D2 replace and discard" do
    test "replace takes the whole document", ctx do
      m = ctx.ma
      two = [D.opening_line(m, m.fixed), D.opening_line(m, m.low, %{"quantity" => "5"})]
      doc = save!(ctx, %{"lines" => two})
      assert length(doc["lines"]) == 2

      one = D.opening_line(m, m.low, %{"quantity" => "7"}) |> Map.delete("actual_user_id")
      body = D.opening_body(m, %{"note" => "changed", "lines" => [one]})
      replaced = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body) |> D.status!(200)

      assert replaced["note"] == "changed"

      assert [%{"asset_id" => low, "quantity" => "7.000000000", "actual_user_id" => nil}] =
               replaced["lines"]

      assert low == m.low
      assert D.get!(ctx, doc["id"]) == replaced
    end

    test "another org unit in a replace is 422 field_invalid", ctx do
      doc = save!(ctx)
      body = D.opening_body(ctx.ma, %{"org_unit_id" => D.unit!(ctx.schema)})
      json = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body) |> D.status!(422)
      assert json["reason"] == "field_invalid" and json["field"] == "org_unit_id"
    end

    test "discard answers 204, then the document is 404 and nothing is left", ctx do
      doc = save!(ctx)
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(204) == nil
      D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(404)
      assert {0, _discarded} = D.written(ctx.schema)
    end
  end

  describe "G6 the external reference pair" do
    test "H-1 two headers with the same pair: 409 external_ref_taken", ctx do
      pair = %{"external_ref_system" => "erp", "external_ref_id" => "H-1"}
      save!(ctx, pair)

      json =
        D.request(:post, "/documents", ctx.tok_a, D.opening_body(ctx.ma, pair)) |> D.status!(409)

      assert json["reason"] == "external_ref_taken"
    end

    test "H-2 a replace keeping its own pair is allowed; taking another's is 409", ctx do
      pair = %{"external_ref_system" => "erp", "external_ref_id" => "H-2"}
      doc = save!(ctx, pair)
      other = save!(ctx, %{"external_ref_system" => "erp", "external_ref_id" => "H-2b"})

      again = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, D.opening_body(ctx.ma, pair))
      assert D.status!(again, 200)["external_ref_id"] == "H-2"

      json =
        D.request(:put, "/documents/#{other["id"]}", ctx.tok_a, D.opening_body(ctx.ma, pair))
        |> D.status!(409)

      assert json["reason"] == "external_ref_taken"
    end

    test "H-3 save returns the pair of the header and of a line", ctx do
      line =
        D.opening_line(ctx.ma, ctx.ma.fixed, %{
          "external_ref_system" => "erp",
          "external_ref_id" => "L-1"
        })

      pair = %{"external_ref_system" => "erp", "external_ref_id" => "H-3", "lines" => [line]}
      doc = save!(ctx, pair)
      assert doc["external_ref_system"] == "erp" and doc["external_ref_id"] == "H-3"
      assert [%{"external_ref_system" => "erp", "external_ref_id" => "L-1"}] = doc["lines"]
      assert D.get!(ctx, doc["id"]) == doc
    end
  end

  describe "C1 and C3 the check route" do
    test "C1 a clean draft is ok with empty reasons and nothing is written", ctx do
      doc = save!(ctx)
      before = D.written(ctx.schema)
      json = D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_a) |> D.status!(200)

      assert %{
               "ok" => true,
               "header" => [],
               "lines" => [%{"line_no" => 1, "reasons" => [], "fields" => []}]
             } =
               json

      assert D.written(ctx.schema) == before
      assert D.get!(ctx, doc["id"]) == doc
    end

    test "C3 a document that is not a draft, another kind, an unknown id", ctx do
      commission = D.save!(ctx)
      json = D.request(:post, "/documents/#{commission["id"]}/check", ctx.tok_a) |> D.status!(422)
      assert json["reason"] == "unknown_kind"

      opening = save!(ctx)
      D.issue_directly!(ctx, opening["id"])
      json = D.request(:post, "/documents/#{opening["id"]}/check", ctx.tok_a) |> D.status!(409)
      assert json["reason"] == "document_not_draft"

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        D.request(:post, "/documents/#{id}/check", ctx.tok_a) |> D.status!(404)
      end
    end
  end

  describe "I2 issue" do
    test "a clean opening is refused 409 posting_not_available and takes no number", ctx do
      doc = save!(ctx)
      before = D.written(ctx.schema)
      json = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(409)
      assert json["reason"] == "posting_not_available"

      after_doc = D.get!(ctx, doc["id"])
      assert after_doc["state"] == "draft" and after_doc["number"] == nil
      assert D.written(ctx.schema) == before

      # no number was consumed: the next commission gets number 1
      issued = D.issue!(ctx)
      assert issued["number"] =~ ~r/^ACM-\d{4}-000001$/
    end
  end

  describe "N1 INV-10 cross-tenant negatives" do
    test "tenant B cannot read, replace, discard, check or issue tenant A's opening", ctx do
      id = save!(ctx)["id"]
      before = D.written(ctx.b.schema_name)
      unknown = Ecto.UUID.generate()

      for {m, p, b} <- [
            {:get, "/documents/ID", nil},
            {:put, "/documents/ID", D.opening_body(ctx.mb)},
            {:delete, "/documents/ID", nil},
            {:post, "/documents/ID/check", nil},
            {:post, "/documents/ID/issue", nil}
          ] do
        mine =
          D.request(m, String.replace(p, "ID", id), ctx.tok_b, b) |> D.status!(404) |> strip()

        other =
          D.request(m, String.replace(p, "ID", unknown), ctx.tok_b, b)
          |> D.status!(404)
          |> strip()

        assert mine == other, p
      end

      assert D.written(ctx.b.schema_name) == before
    end

    test "A's card, location and employee ids in B's lines are plain check reasons", ctx do
      tb = Map.put(ctx, :tok_a, ctx.tok_b) |> Map.put(:schema, ctx.b.schema_name)
      ma = ctx.ma

      line =
        D.opening_line(ctx.mb, ma.fixed, %{
          "location_id" => ma.location,
          "material_responsible_id" => ma.employee
        })

      doc = D.save!(tb, D.opening_body(ctx.mb, %{"lines" => [line]}))
      json = D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_b) |> D.status!(200)

      assert %{"ok" => false, "lines" => [%{"reasons" => reasons, "fields" => fields}]} = json
      assert reasons == ["card_not_active", "employee_not_active"]
      assert fields == ["material_responsible_id"]

      # B's own card with A's location: the location is not linked in B
      own = D.opening_line(ctx.mb, ctx.mb.fixed, %{"location_id" => ma.location})
      doc2 = D.save!(tb, D.opening_body(ctx.mb, %{"lines" => [own]}))
      json2 = D.request(:post, "/documents/#{doc2["id"]}/check", ctx.tok_b) |> D.status!(200)
      assert [%{"reasons" => ["not_linked"]}] = json2["lines"]
    end
  end

  describe "T1 access" do
    test "a TASK_WORKER is forbidden on the check route and on save", ctx do
      doc = save!(ctx)
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
      before = D.written(ctx.schema)

      for {path, body} <- [
            {"/documents/#{doc["id"]}/check", nil},
            {"/documents", D.opening_body(ctx.ma)}
          ] do
        conn = D.request(:post, path, tok, body)
        assert D.status!(conn, 403)["title"] == "Forbidden", path
      end

      assert D.written(ctx.schema) == before
    end
  end
end
