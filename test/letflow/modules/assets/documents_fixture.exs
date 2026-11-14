Code.require_file("register_fixture.exs", __DIR__)
Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.AssetsDocsFixture do
  @moduledoc """
  GH #3891 / #3890 (assets C10): setup and helpers of the asset document tests. One committed tenant
  with `org`, `locations` and `assets` installed, real masters (an org unit, a location linked to it,
  two employees, a fixed, a low-value and an intangible card), a bearer token of a TENANT_ADMIN, and
  request helpers that go through the full `Letflow.Router`. The human task of a posting is claimed
  and completed through the real tasks routes (`task_route/4`, rule D-098). A `.exs` file loaded with
  `Code.require_file/2`; callers are `async: false` and run in Sandbox `:auto` mode.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions
  import Plug.Conn

  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.Repo

  @base "/api/v1/modules/assets"

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  @doc "The test context: tenant `a` (names `extra` get realms too), masters and a TENANT_ADMIN token."
  def setup!(names \\ [:a]) do
    ctx = S.setup_oidc!(names)
    a = S.tenant!("ast-da", ctx.names.a)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:letflow, :assets_post_start_fail?)
      Application.delete_env(:letflow, :assets_documents_clock)
    end)

    Map.merge(ctx, %{
      a: a,
      schema: a.schema_name,
      ma: masters!(a.schema_name),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])
    })
  end

  @doc "A second tenant `b` with masters and a token (realm `:b` must be in `setup!/1`'s names)."
  def tenant_b!(ctx) do
    b = S.tenant!("ast-db", ctx.names.b)
    %{b: b, mb: masters!(b.schema_name), tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])}
  end

  @doc "A live org unit (no staff) in `schema`; returns its record id."
  def unit!(schema, le_name \\ "LE") do
    n = System.unique_integer([:positive])

    {:ok, le} =
      Org.create_legal_entity(
        schema,
        %{"code" => "LE#{n}", "name" => le_name, "bin" => String.pad_leading("#{n}", 12, "5")},
        opts()
      )

    {:ok, site} =
      Org.create_site(
        schema,
        %{"code" => "S#{n}", "name" => "S", "legal_entity_id" => le["record_id"]},
        opts()
      )

    {:ok, unit} =
      Org.create_unit(
        schema,
        %{
          "code" => "U#{n}",
          "name" => "U",
          "legal_entity_id" => le["record_id"],
          "site_id" => site["record_id"]
        },
        opts()
      )

    unit["record_id"]
  end

  @doc "A location linked to `unit_id`; returns its record id."
  def location!(schema, unit_id) do
    n = System.unique_integer([:positive])

    {:ok, node} =
      Locations.create_node(
        schema,
        %{"code" => "L#{n}", "name" => "L", "node_kind" => "zone"},
        opts()
      )

    {:ok, _link} = Locations.link_unit_location(schema, unit_id, node["record_id"], opts())
    node["record_id"]
  end

  def employee!(schema, unit_id) do
    n = System.unique_integer([:positive])

    OrgFixture.create!(
      schema,
      "org_employee",
      OrgFixture.values("org_employee", "E#{n}", %{"org_unit_id" => unit_id})
    ).record_id
  end

  @doc "An asset card of `kind` in `unit` (the record id)."
  def card!(schema, kind, unit, extra \\ %{}) do
    n = System.unique_integer([:positive])

    Cards.card!(
      schema,
      "INV#{n}",
      Map.merge(%{"kind" => kind, "org_unit_id" => unit}, extra)
    ).record_id
  end

  @doc "Masters in `schema`: unit, linked location, two employees, one card of each kind."
  def masters!(schema) do
    unit = unit!(schema)

    %{
      unit: unit,
      location: location!(schema, unit),
      employee: employee!(schema, unit),
      employee2: employee!(schema, unit),
      fixed: card!(schema, "fixed", unit),
      fixed2: card!(schema, "fixed", unit),
      low: card!(schema, "low_value", unit),
      intangible: card!(schema, "intangible", unit)
    }
  end

  @doc "A valid commission body for `m`: one fixed card, quantity 1. `extra` overrides keys."
  def body(m, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "commission",
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "material_responsible_id" => m.employee,
        "actual_user_id" => m.employee2,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "note" => "new equipment",
        "lines" => [%{"asset_id" => m.fixed, "quantity" => "1"}]
      },
      extra
    )
  end

  @doc "Sends `method` `path` (relative to the module base) with an optional JSON body."
  def request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, @base <> path)
        body -> Plug.Test.conn(method, @base <> path, Jason.encode!(body))
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  def status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
  end

  def save!(ctx, body \\ nil),
    do: request(:post, "/documents", ctx.tok_a, body || body(ctx.ma)) |> status!(201)

  @doc "Saves and issues a commission through the routes; returns the issued document."
  def issue!(ctx, body \\ nil) do
    doc = save!(ctx, body)
    request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)
  end

  def get!(ctx, id), do: request(:get, "/documents/#{id}", ctx.tok_a) |> status!(200)

  @doc "The pending task of `node` (\"post\" / \"reverse\") of an active instance of document `id`."
  def pending_task(ctx, id, node) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  @doc "POSTs `action` (\"claim\" / \"complete\") of `task` through the real tasks route."
  def task_route(task, token, action, body) do
    Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/#{action}", body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  @doc "Claims and completes `task` through the tasks routes with `token`; returns the complete conn."
  def claim_and_complete(task, token) do
    assert task_route(task, token, "claim", "{}").status == 200
    task_route(task, token, "complete", ~s({"output_variables":{}}))
  end

  @doc "Claims and completes the pending `node` task of document `id` through HTTP; returns the document."
  def run_task!(ctx, id, node \\ "post") do
    task = pending_task(ctx, id, node) || flunk("no pending #{node} task")
    conn = claim_and_complete(task, ctx.tok_a)
    assert conn.status == 200, "complete answered #{conn.status}: #{conn.resp_body}"
    get!(ctx, id)
  end

  @doc "Ledger entry counts by cause and the mark count of document `id`."
  def counts(ctx, id) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT cause, count(*) FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1 GROUP BY cause|,
        [id]
      )

    %{rows: [[marks]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{ctx.schema}".entity_record_latest WHERE entity_type = 'assets_posting_mark' AND NOT deleted AND field_values->>'document_id' = $1|,
        [id]
      )

    %{entries: Map.new(rows, fn [cause, n] -> {cause, n} end), marks: marks}
  end

  @doc "Every document, header record and line record of `schema` (for 'nothing written' counts)."
  def written(schema) do
    records =
      Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest,
          where:
            r.entity_type in [
              "assets_commission",
              "assets_commission_line",
              "assets_change",
              "assets_change_line",
              "assets_handover",
              "assets_handover_line",
              "assets_writeoff",
              "assets_writeoff_line",
              "assets_opening",
              "assets_opening_line"
            ] and not r.deleted
        ),
        :count,
        prefix: schema
      )

    {records, Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: schema)}
  end

  @doc "A valid body of kind `change` for `m` (employee and user swap places)."
  def change_body(m, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "change",
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "from_material_responsible_id" => m.employee,
        "from_actual_user_id" => m.employee2,
        "to_material_responsible_id" => m.employee2,
        "to_actual_user_id" => m.employee,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "lines" => [%{"asset_id" => m.fixed, "quantity" => "1"}]
      },
      extra
    )
  end

  @doc "A valid body of kind `handover` from `m`'s place to `to` (`unit`, `location`, `employee`)."
  def handover_body(m, to, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "handover",
        "org_unit_id" => m.unit,
        "from_location_id" => m.location,
        "from_material_responsible_id" => m.employee,
        "from_actual_user_id" => m.employee2,
        "to_org_unit_id" => to.unit,
        "to_location_id" => to.location,
        "to_material_responsible_id" => to.employee,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "lines" => [%{"asset_id" => m.fixed, "quantity" => "1"}]
      },
      extra
    )
  end

  @doc "A valid body of kind `writeoff` for `m`."
  def writeoff_body(m, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "writeoff",
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "material_responsible_id" => m.employee,
        "actual_user_id" => m.employee2,
        "reason_code" => "disposed",
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "lines" => [%{"asset_id" => m.fixed, "quantity" => "1"}]
      },
      extra
    )
  end

  @doc "A valid opening body for `m` (G5): one fixed card at the location, quantity 1."
  def opening_body(m, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "opening",
        "org_unit_id" => m.unit,
        "note" => "opening balance",
        "lines" => [opening_line(m, m.fixed)]
      },
      extra
    )
  end

  @doc "An opening line of `asset` at `m`'s place; `extra` overrides keys."
  def opening_line(m, asset, extra \\ %{}) do
    Map.merge(
      %{
        "asset_id" => asset,
        "location_id" => m.location,
        "material_responsible_id" => m.employee,
        "actual_user_id" => m.employee2,
        "quantity" => "1"
      },
      extra
    )
  end

  @doc """
  Issues the saved draft `id` straight through `Letflow.Documents` (the route refuses an opening in
  part 1, so a test that needs an issued opening goes around it). Returns the issued version.
  """
  def issue_directly!(ctx, id) do
    {:ok, issued} =
      Letflow.Documents.issue(ctx.schema, %{document_id: id, actor_id: Ecto.UUID.generate()})

    issued
  end

  @doc "Writes the `reversed` posting mark of document `id` (as the reversal handler does)."
  def mark_reversed!(ctx, id, type_key, unit) do
    {:ok, _} =
      Letflow.Entities.Records.create_record(
        %{
          entity_type: "assets_posting_mark",
          field_values: %{
            "document_id" => id,
            "document_type" => type_key,
            "version_no" => 1,
            "mark" => "reversed",
            "org_unit_id" => unit
          },
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema,
        Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Assets)
      )

    :ok
  end

  @doc "A second place in `schema`: unit, linked location, one employee."
  def place!(schema, le_name \\ "LE") do
    unit = unit!(schema, le_name)
    %{unit: unit, location: location!(schema, unit), employee: employee!(schema, unit)}
  end

  @doc "Issues and posts a commission (body `body`); returns the posted document."
  def commission!(ctx, body \\ nil) do
    doc = issue!(ctx, body)
    run_task!(ctx, doc["id"])
  end

  @doc "Balance rows of `asset` through the real read route."
  def balances(ctx, asset) do
    S.get("/balances", ctx.tok_a)
    |> status!(200)
    |> Map.fetch!("rows")
    |> Enum.filter(&(&1["asset"] == asset))
  end

  @doc "Movement rows of the document through the real read route."
  def movements(ctx, id) do
    S.get("/movements?document_id=#{id}", ctx.tok_a) |> status!(200) |> Map.fetch!("rows")
  end
end
