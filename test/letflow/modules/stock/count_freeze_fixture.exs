Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.CountFreezeFixture do
  @moduledoc """
  REQ-765 / GH #3906: shared setup of the count freeze tests. A committed tenant (Sandbox `:auto`
  mode, callers are `async: false`) with the count world of `Letflow.CountsFixture` (unit, chair,
  members, locations `a` > `a1` > `a11` and `b`), the document masters of `Letflow.StockDocsFixture`
  moved into that unit and location `a1`, a chair and a member who are real users, and a task
  completer. Everything goes through the full `Letflow.Router` with real OIDC bearer tokens.
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: L
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  def call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        b -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(b))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  def status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  def window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  @doc "The context of one tenant `name` (`:a` or `:b`): see the moduledoc."
  def world!(ctx, name) do
    t = S.tenant!("cfrz", Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    member_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "member-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    status!(call(:get, "/counts", member_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    member_user = Repo.one!(from(u in User, where: u.username == ^"member-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    w = %{w | chair: chair, members: [member]}
    m = D.masters!(s)
    # a second org unit that also has the location `a1` linked (the pair rule tests)
    L.link!(s, m.unit, w.a1)

    %{
      t: t,
      s: s,
      schema: s,
      w: w,
      chair_tok: chair_tok,
      member_tok: member_tok,
      tok_a: chair_tok,
      chair_user: chair_user,
      holder: TokenMintFixture.role_holder!(s, ["TENANT_ADMIN"]),
      m: m,
      # the masters of the documents: the count unit, location `a1`
      ma: %{m | unit: w.unit, location: w.a1},
      other_unit: m.unit
    }
  end

  @doc "Masters at another location of the count unit (`loc`)."
  def at(x, loc), do: %{x.ma | location: loc}

  def plain_line(m, q),
    do: %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => q}

  @doc "Receives `qty` of the plain item at `m` (a posted receipt document)."
  def receive!(x, m, qty) do
    doc = P.issue!(x, D.body(m, nil, %{"lines" => [plain_line(m, qty)]}))
    P.post_and_complete!(x, doc["id"])
    doc
  end

  @doc "Creates and issues a count order over `roots` (default `[a]`); returns its id."
  def ordered!(x, extra \\ %{}, roots \\ nil) do
    input =
      F.input(x.w, Map.merge(window(), Map.merge(%{"location_ids" => roots || [x.w.a]}, extra)))

    id = status!(call(:post, "/counts", x.chair_tok, input), 201)["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    id
  end

  @doc "An order with `freeze_locations` true, issued and opened; returns its id."
  def frozen!(x, extra \\ %{}, roots \\ nil) do
    id = ordered!(x, Map.merge(%{"freeze_locations" => true}, extra), roots)
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)
    id
  end

  def count(x, id), do: status!(call(:get, "/counts/#{id}", x.chair_tok), 200)

  def cancel!(x, id), do: status!(call(:post, "/counts/#{id}/cancel", x.chair_tok, %{}), 200)

  @doc "The refusal of a completion: `{held_by}` of a `location_frozen` answer, else a failed assertion."
  def held_by!(result) do
    assert {:error, {:entity_write_refused_detailed, _index, _code, "location_frozen", details}} =
             result

    Map.get(details, :held_by) || Map.get(details, "held_by")
  end

  @doc "Total balance quantity (decimal text) of `item` at `location` for the count unit."
  def balance(x, item, location) do
    rows = S.get("/balances?sku=#{item}", x.chair_tok) |> P.status!(200) |> Map.fetch!("rows")

    rows
    |> Enum.filter(&(&1["location"] == location))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc "Rows of the audit log of `schema` whose action starts with `prefix`."
  def audits(schema, action) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT resource_id, after_state::text FROM "#{schema}".audit_entries WHERE action = $1 ORDER BY timestamp|,
        [action]
      )

    Enum.map(rows, fn [id, state] -> {id, state} end)
  end
end
