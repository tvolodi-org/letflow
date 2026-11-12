Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardLocksTest do
  @moduledoc """
  T-1490 / G3 through the real `Letflow.Router` with OIDC bearer tokens on committed tenants: after the
  first posted document the card's `inventory_number` and `kind` are refused (422), the other fields stay
  editable with one audit entry each, `GET /cards/:id/lock` tells the screen, and tenant B cannot read
  or change tenant A's card (INV-10). `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.CardLocks
  alias Letflow.Modules.Org
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Repo

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp patch(ctx, id, body, tok \\ nil) do
    D.request(
      :patch,
      "/cards/#{id}",
      tok || ctx.tok_a,
      Map.put(body, "idempotency_key", Ecto.UUID.generate())
    )
  end

  defp reason(conn, status), do: conn |> D.status!(status) |> Map.fetch!("reason")

  defp lock(ctx, id, tok \\ nil), do: D.request(:get, "/cards/#{id}/lock", tok || ctx.tok_a)

  defp audits(schema, id) do
    Repo.all(
      from(e in Entry,
        where: e.resource_type == "assets_card" and e.resource_id == ^id,
        select: e.action
      ),
      prefix: schema
    )
  end

  defp fv(schema, id) do
    Repo.one!(from(l in Latest, where: l.record_id == ^id, select: l.field_values),
      prefix: schema
    )
  end

  defp posted!(ctx), do: D.commission!(ctx)

  test "L1 L2 inventory number and kind are refused after a posted commission", ctx do
    posted!(ctx)
    id = ctx.ma.fixed
    before = fv(ctx.schema, id)
    n = length(audits(ctx.schema, id))

    assert reason(patch(ctx, id, %{"inventory_number" => "NEW-1"}), 422) ==
             "inventory_number_locked"

    assert reason(patch(ctx, id, %{"kind" => "low_value"}), 422) == "kind_locked"
    assert fv(ctx.schema, id) == before
    assert length(audits(ctx.schema, id)) == n
  end

  test "L3 the lock holds after the commission is reversed", ctx do
    doc = posted!(ctx)

    assert D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
             "reason_code" => "wrong_document"
           }).status == 200

    D.run_task!(ctx, doc["id"], "reverse")

    assert reason(patch(ctx, ctx.ma.fixed, %{"inventory_number" => "NEW-2"}), 422) ==
             "inventory_number_locked"

    assert %{"posted" => true} = D.status!(lock(ctx, ctx.ma.fixed), 200)
  end

  test "L4 a card on a draft and on an issued-only commission can change both", ctx do
    draft = D.save!(ctx)
    id = ctx.ma.fixed
    assert patch(ctx, id, %{"inventory_number" => "DRAFT-1"}).status == 200
    D.request(:post, "/documents/#{draft["id"]}/issue", ctx.tok_a)
    assert patch(ctx, id, %{"kind" => "low_value", "name" => "x"}).status == 200
    assert fv(ctx.schema, id)["inventory_number"] == "DRAFT-1"
  end

  test "L5 resending the same number and kind with another change is allowed", ctx do
    posted!(ctx)
    id = ctx.ma.fixed
    stored = fv(ctx.schema, id)

    body = %{
      "inventory_number" => stored["inventory_number"],
      "kind" => stored["kind"],
      "name" => "Renamed"
    }

    assert patch(ctx, id, body).status == 200
    assert fv(ctx.schema, id)["name"] == "Renamed"
  end

  test "L6 the other fields stay editable after posting, one audit entry per change", ctx do
    posted!(ctx)
    id = ctx.ma.fixed
    n = length(audits(ctx.schema, id))

    for body <- [
          %{"name" => "Pump"},
          %{"acquisition_cost" => "1000.00", "currency" => "KZT"},
          %{"accumulated_depreciation" => "10.00", "book_value" => "990.00"},
          %{"external_ref_system" => "erp", "external_ref_id" => "A-1"}
        ] do
      assert patch(ctx, id, body).status == 200, inspect(body)
    end

    updated = Enum.filter(audits(ctx.schema, id), &(&1 == "assets_card.updated"))
    assert length(updated) >= 4
    assert length(audits(ctx.schema, id)) == n + 4

    # valid_until is for intangible cards
    posted_intangible = ctx.ma.intangible
    assert patch(ctx, posted_intangible, %{"valid_until" => "2030-01-01"}).status == 200
  end

  test "L10 the xlsx import refuses a changed kind of a posted card with asset_kind_locked",
       ctx do
    # GH #3899 / REQ-762, E10 end to end: the import row goes through the real route, the card
    # has a posted commission, so the changed kind is refused per row and nothing is written.
    id = ctx.ma.fixed

    {:ok, _} =
      Org.update_unit(
        ctx.schema,
        ctx.ma.unit,
        %{"external_ref_system" => "erp", "external_ref_id" => "UNIT-L10"},
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    assert patch(ctx, id, %{"external_ref_system" => "erp", "external_ref_id" => "A-L10"}).status ==
             200

    posted!(ctx)
    stored = fv(ctx.schema, id)
    n = length(audits(ctx.schema, id))
    header = ~w(inventory_number name kind org_unit_id external_ref_system external_ref_id)

    import_row = fn kind ->
      cells = [stored["inventory_number"], stored["name"], kind, "UNIT-L10", "erp", "A-L10"]

      Plug.Test.conn(
        :post,
        "/api/v1/entities/records/assets_card/import?upsert_by=external_ref",
        Letflow.XlsxFixture.build([[header, cells]])
      )
      |> Plug.Conn.put_req_header(
        "content-type",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.tok_a)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
    end

    other = if stored["kind"] == "low_value", do: "fixed", else: "low_value"
    conn = import_row.(other)
    assert conn.status == 200, conn.resp_body

    assert [%{"reason" => %{"type" => "asset_kind_locked", "header" => "kind"}}] =
             Jason.decode!(conn.resp_body)["results"]

    assert fv(ctx.schema, id) == stored
    assert length(audits(ctx.schema, id)) == n

    # the other branch: the same kind is not a change, the row is not refused as locked
    conn = import_row.(stored["kind"])
    assert conn.status == 200, conn.resp_body
    refute conn.resp_body =~ "asset_kind_locked"
  end

  test "L7 holder fields are refused with field_not_allowed", ctx do
    posted!(ctx)

    for key <- ~w(org_unit_id quantity location responsible user) do
      conn = patch(ctx, ctx.ma.fixed, %{key => "x"})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["reason"] == "field_not_allowed", key
    end
  end

  test "L8 posted?/2 is false before posting and true after, any card only", ctx do
    refute CardLocks.posted?(ctx.schema, ctx.ma.fixed)
    posted!(ctx)
    assert CardLocks.posted?(ctx.schema, ctx.ma.fixed)
    refute CardLocks.posted?(ctx.schema, ctx.ma.fixed2)
    refute CardLocks.posted?(ctx.schema, "not-a-uuid")
    assert CardLocks.check(ctx.schema, ctx.ma.fixed, %{"kind" => "a"}, %{"kind" => "a"}) == :ok

    assert CardLocks.check(ctx.schema, ctx.ma.fixed, %{"kind" => "a"}, %{"kind" => "b"}) ==
             {:error, :kind_locked}
  end

  test "L9 the lock route answers posted false and true, and refuses a caller without read",
       ctx do
    assert %{"posted" => false} = D.status!(lock(ctx, ctx.ma.fixed), 200)
    posted!(ctx)
    assert %{"posted" => true} = D.status!(lock(ctx, ctx.ma.fixed), 200)
    assert %{"posted" => false} = D.status!(lock(ctx, ctx.ma.fixed2), 200)
    assert lock(ctx, ctx.ma.fixed, "garbage-token").status in [401, 403]
  end

  test "L10 cross-tenant: tenant B gets the same 404 for A's card, an unknown and a bad id",
       ctx do
    posted!(ctx)
    id = ctx.ma.fixed
    before = fv(ctx.schema, id)

    a = lock(ctx, id, ctx.tok_b)
    u = lock(ctx, Ecto.UUID.generate(), ctx.tok_b)
    bad = lock(ctx, "nope", ctx.tok_b)
    assert a.status == 404 and u.status == 404 and bad.status == 404
    assert strip(a.resp_body) == strip(u.resp_body)
    assert strip(a.resp_body) == strip(bad.resp_body)

    assert patch(ctx, id, %{"name" => "hijack"}, ctx.tok_b).status == 404
    assert fv(ctx.schema, id) == before
  end

  defp strip(body), do: body |> Jason.decode!() |> M.strip()

  test "L12 a refused call is not cached: the same key refuses again", ctx do
    posted!(ctx)
    key = Ecto.UUID.generate()
    body = %{"inventory_number" => "NEW-3", "idempotency_key" => key}

    for _ <- 1..2,
        do:
          assert(
            reason(D.request(:patch, "/cards/#{ctx.ma.fixed}", ctx.tok_a, body), 422) ==
              "inventory_number_locked"
          )
  end
end
