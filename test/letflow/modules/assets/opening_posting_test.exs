Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.OpeningPostingTest do
  @moduledoc """
  GH #4037 (assets G5 part 2, decision 0083): issue, approve, post and reverse an asset opening through
  the full `Letflow.Router`, real tokens, committed tenants, Sandbox `:auto`, `async: false`.
  OP-DEF-1 definition and issue, OP-2P-1..3 two-person process, OP-TIME-1/2 no client time and money
  stays on the card, OP-REP-1 repeat, OP-ONCE-1..5 an asset is opened once, OP-REV-1 reversal,
  OP-TEN-1 INV-10 negatives.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LedgerFixture
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Assets.Documents.OpeningChecks
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  defp save!(ctx, extra \\ %{}), do: D.save!(ctx, D.opening_body(ctx.ma, extra))

  defp issue!(ctx, extra \\ %{}) do
    doc = save!(ctx, extra)
    D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(200)
  end

  defp card_fields(ctx, id) do
    Repo.one!(
      from(r in Letflow.Entities.Record.Latest,
        where: r.entity_type == "assets_card" and r.record_id == ^id,
        select: r.field_values
      ),
      prefix: ctx.schema
    )
  end

  defp task(ctx, id, node, status) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == ^status and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  defp complete(task, token, body \\ "{}") do
    D.task_route(task, token, "complete", body)
  end

  defp approve_as(ctx, id, token, body \\ "{}") do
    task = task(ctx, id, "approve", :pending) || flunk("no pending approve task")
    complete(task, token, body)
  end

  defp posted!(ctx, extra \\ %{}) do
    doc = issue!(ctx, extra)
    approve_as(ctx, doc["id"], ctx.tok_u2) |> D.status!(200)
    doc
  end

  describe "OP-DEF-1 definition and issue" do
    test "pack graph, lazy activation, submit completed by the issuer, approve pending", ctx do
      pack =
        "priv/modules/assets/pack.json" |> File.read!() |> Jason.decode!()

      defn = Enum.find(pack["definitions"], &(&1["process_key"] == "assets_opening"))
      nodes = defn["graph"]["nodes"]
      assert Enum.map(nodes, & &1["id"]) == ~w(start submit approve end)
      submit = Enum.find(nodes, &(&1["id"] == "submit"))
      approve = Enum.find(nodes, &(&1["id"] == "approve"))
      refute Map.has_key?(submit["attributes"], "module_writes")
      assert submit["attributes"]["role"] == "ASSETS_OPENING_SUBMIT"
      assert approve["attributes"]["distinct_from"] == ["submit"]

      assert [%{"module" => "assets", "handler" => "post_document"}] =
               approve["attributes"]["module_writes"]

      doc = issue!(ctx)
      assert doc["state"] == "issued"
      assert doc["number"] =~ ~r/^AOP-\d{4}-000001$/

      row =
        Repo.one(
          from(d in Letflow.Definitions.ProcessDefinition,
            where: d.name == "assets_opening" and d.status == :active
          ),
          prefix: ctx.schema
        )

      assert row.owner_module == "assets"
      assert task(ctx, doc["id"], "submit", :completed)
      assert task(ctx, doc["id"], "approve", :pending)
    end
  end

  describe "OP-2P two-person process" do
    test "OP-2P-1 the issuer completing approve is refused with the separation body", ctx do
      doc = issue!(ctx)
      conn = approve_as(ctx, doc["id"], ctx.tok_a)
      reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
      assert conn.status == 403 and conn.resp_body == reference.resp_body
      assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
      assert task(ctx, doc["id"], "approve", :pending)
    end

    test "OP-2P-2 a second user posts: one entry, one leg per line, balances show the assets",
         ctx do
      m = ctx.ma

      doc =
        issue!(ctx, %{
          "lines" => [
            D.opening_line(m, m.fixed),
            Map.delete(D.opening_line(m, m.intangible), "location_id"),
            D.opening_line(m, m.low, %{"quantity" => "3"}),
            m
            |> D.opening_line(m.low, %{
              "quantity" => "2",
              "material_responsible_id" => m.employee2
            })
            |> Map.delete("actual_user_id")
          ]
        })

      approve_as(ctx, doc["id"], ctx.tok_u2) |> D.status!(200)

      assert D.counts(ctx, doc["id"]) == %{entries: %{"opening" => 1}, marks: 1}
      [entry] = D.movements(ctx, doc["id"])
      assert entry["cause"] == "opening" and entry["document_type"] == "assets_opening"
      assert length(entry["legs"]) == 4
      assert Enum.all?(entry["legs"], &(&1["org_unit"] == m.unit))

      assert [fixed] = D.balances(ctx, m.fixed)
      assert fixed["quantity"] == "1.000000000" and fixed["location"] == m.location
      assert length(D.balances(ctx, m.low)) == 2

      assert D.balances(ctx, m.low)
             |> Enum.map(&Decimal.new(&1["quantity"]))
             |> Enum.reduce(&Decimal.add/2)
             |> Decimal.equal?(5)

      assert [_] = D.balances(ctx, m.intangible)

      read = D.get!(ctx, doc["id"])
      assert read["state"] == "posted" and read["posting_check"] == "ok"
      assert read["entry_id"] == entry["entry_id"]
    end

    test "OP-2P-3 posted_by is the approver, not the issuer", ctx do
      doc = posted!(ctx)
      read = D.get!(ctx, doc["id"])
      assert read["posted_by"] == task(ctx, doc["id"], "approve", :completed).completed_by
      refute read["posted_by"] == task(ctx, doc["id"], "submit", :completed).completed_by
    end
  end

  describe "OP-TIME no client time, money stays on the card" do
    test "OP-TIME-1 event time is the posting time; the card is unchanged", ctx do
      m = ctx.ma
      card_before = card_fields(ctx, m.fixed)
      doc = posted!(ctx)
      [entry] = D.movements(ctx, doc["id"])
      assert entry["event_time"] == entry["posting_time"]

      text = Jason.encode!(entry)

      for key <- ~w(acquisition_cost accumulated_depreciation acquisition_date book_value) do
        refute text =~ key
      end

      assert card_fields(ctx, m.fixed) == card_before
    end

    test "OP-TIME-2 a forged posting variable cannot backdate the entry", ctx do
      doc = issue!(ctx)
      task = task(ctx, doc["id"], "approve", :pending)

      instance =
        Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)

      forged =
        Map.merge(instance.variables["posting"], %{
          "device_id" => "forged",
          "client_seq" => 1,
          "client_event_time" =>
            DateTime.utc_now() |> DateTime.add(-48 * 3600) |> DateTime.to_iso8601()
        })

      body = Jason.encode!(%{"output_variables" => %{"posting" => forged}})
      assert complete(task, ctx.tok_u2, body).status == 200
      [entry] = D.movements(ctx, doc["id"])
      assert entry["event_time"] == entry["posting_time"]
      assert D.get!(ctx, doc["id"])["posting_check"] == "ok"
    end
  end

  describe "OP-REP repeat" do
    test "OP-REP-1 a second instance for the same version cannot post again", ctx do
      doc = posted!(ctx)
      id = doc["id"]
      {:ok, view} = Documents.fetch(ctx.schema, id)
      issued = Posting.issued(ctx.schema, id)
      assert {:ok, _instance} = Posting.start_post(ctx.schema, view, issued, Ecto.UUID.generate())

      if sub = task(ctx, id, "submit", :pending), do: complete(sub, ctx.tok_a)
      if task(ctx, id, "approve", :pending), do: approve_as(ctx, id, ctx.tok_u2)

      assert D.counts(ctx, id) == %{entries: %{"opening" => 1}, marks: 1}
    end
  end

  describe "OP-ONCE an asset is opened once" do
    test "OP-ONCE-1 a second opening of a posted asset is refused", ctx do
      posted!(ctx)
      second = save!(ctx)

      json =
        D.request(:post, "/documents/#{second["id"]}/issue", ctx.tok_a) |> D.status!(422)

      assert json["reason"] == "asset_already_in_register" and json["line_no"] == 1
      assert D.get!(ctx, second["id"])["number"] == nil
    end

    test "OP-ONCE-2/3 the balance half: a reversed-mark commission still holds the asset", ctx do
      commission = D.commission!(ctx)
      D.mark_reversed!(ctx, commission["id"], "assets_commission", ctx.ma.unit)
      doc = save!(ctx)

      json = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(422)
      assert json["reason"] == "asset_already_in_register"

      # control: without a register read the document half alone shows nothing
      assert {:ok, %{lines: [%{reasons: reasons}]}} = Documents.check(ctx.schema, doc["id"], nil)
      refute "asset_already_in_register" in reasons

      # OP-ONCE-3: the check route shows it
      checked = D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_a) |> D.status!(200)
      assert checked["ok"] == false
      assert [%{"line_no" => 1, "reasons" => r}] = checked["lines"]
      assert "asset_already_in_register" in r
    end

    test "OP-ONCE-4 no ledger read: register_unreadable, nothing issued", ctx do
      doc = save!(ctx)
      before = D.written(ctx.schema)

      assert {:error, :register_unreadable} =
               Documents.issue(ctx.schema, doc["id"], Ecto.UUID.generate(), authorized: nil)

      assert D.get!(ctx, doc["id"])["number"] == nil
      assert D.written(ctx.schema) == before
    end

    test "OP-ONCE-5 a scoped reader fails closed, a tenant-wide one sees the balance", ctx do
      commission = D.commission!(ctx)
      D.mark_reversed!(ctx, commission["id"], "assets_commission", ctx.ma.unit)
      doc = save!(ctx)
      before = D.written(ctx.schema)
      fx = %{schema_name: ctx.schema, tenant_id: ctx.a.tenant_id}

      node = RSG.node!(ctx.schema)
      user = TokenMintFixture.role_holder!(ctx.schema, [])
      :ok = RSG.raw_user_row!(ctx.schema, user.id, "TENANT_ADMIN", node)

      assert {:ok, scoped} =
               Letflow.Ledger.authorize(
                 LedgerFixture.conn_for(fx, user, ["TENANT_ADMIN"]),
                 "assets",
                 :read
               )

      assert {:nodes, [_ | _]} = Map.get(scoped, :scope)

      assert {:error, :register_unreadable} =
               Documents.issue(ctx.schema, doc["id"], Ecto.UUID.generate(), authorized: scoped)

      assert D.get!(ctx, doc["id"])["number"] == nil
      assert D.written(ctx.schema) == before

      # the advisory check with the scoped reader shows the document half only
      assert {:ok, %{lines: [%{reasons: reasons}]}} =
               Documents.check(ctx.schema, doc["id"], scoped)

      refute "asset_already_in_register" in reasons

      # control: a tenant-wide reader is refused for the balance, not for the scope
      admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

      assert {:ok, wide} =
               Letflow.Ledger.authorize(
                 LedgerFixture.conn_for(fx, admin, ["TENANT_ADMIN"]),
                 "assets",
                 :read
               )

      assert OpeningChecks.register_readable?(wide)

      assert {:error, {"asset_already_in_register", _}} =
               Documents.issue(ctx.schema, doc["id"], Ecto.UUID.generate(), authorized: wide)
    end

    test "OP-ONCE-6 register_readable? accepts only scope :all" do
      refute OpeningChecks.register_readable?(nil)
      refute OpeningChecks.register_readable?(%{scope: {:nodes, ["x"]}})
      refute OpeningChecks.register_readable?(%{})
      assert OpeningChecks.register_readable?(%{scope: :all})
    end
  end

  describe "OP-REV reversal" do
    test "OP-REV-1 a posted opening reverses; the asset may be opened again", ctx do
      m = ctx.ma
      doc = posted!(ctx)

      D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
        "reason_code" => "wrong_document"
      })
      |> D.status!(200)

      read = D.run_task!(ctx, doc["id"], "reverse")
      assert read["state"] == "reversed" and read["posting_check"] == "ok"

      assert D.balances(ctx, m.fixed)
             |> Enum.map(&Decimal.new(&1["quantity"]))
             |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
             |> Decimal.equal?(0)

      again = save!(ctx)
      D.request(:post, "/documents/#{again["id"]}/issue", ctx.tok_a) |> D.status!(200)
    end
  end

  describe "OP-TEN-1 INV-10 cross-tenant negatives" do
    test "tenant B cannot approve, issue, reverse or read tenant A's opening", ctx do
      draft = save!(ctx)
      issued = issue!(ctx, %{"lines" => [D.opening_line(ctx.ma, ctx.ma.fixed2)]})
      before = D.counts(ctx, issued["id"])
      task = task(ctx, issued["id"], "approve", :pending)
      assert complete(task, ctx.tok_b).status in [403, 404]
      assert D.counts(ctx, issued["id"]) == before

      for {m, p, b} <- [
            {:post, "/documents/#{draft["id"]}/issue", nil},
            {:post, "/documents/#{issued["id"]}/reverse", %{"reason_code" => "wrong_document"}},
            {:get, "/documents/#{issued["id"]}", nil}
          ] do
        D.request(m, p, ctx.tok_b, b) |> D.status!(404)
      end
    end
  end
end
