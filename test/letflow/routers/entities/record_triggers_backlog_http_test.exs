defmodule Letflow.Routers.Entities.RecordTriggersBacklogHttpTest do
  @moduledoc """
  REQ-606 / GH #3411 part 2, criterion 13 (decision 0067 D6): with a full trigger backlog the record
  create, update, delete and import-upsert routes answer 503 `{"error": "trigger_backlog_full"}`
  with a `Retry-After` header and commit nothing; create-mode import keeps its 200 with a per-entry
  reason; a forced `trigger_enqueue_failed` stays a 500. Full pipeline (`Letflow.Router.call/2`,
  real API-token bearer). The 503 and the Retry-After value are provisional (REQ-606 open_questions).
  This part adds no route, so the cross-tenant route negative test belongs to slices T-3 and T-5.

  `async: false`: provisioned tenant, application env.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)
    Application.put_env(:letflow, :record_trigger_backlog_cap, 2)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_backlog_cap)
    end)

    tenant = F.tenant!("r606h")
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "r606h-#{Ecto.UUID.generate()}",
        display_name: "R606 route test",
        email: "r606h-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    P.active_definition!(schema, "tt", ["name"])
    for event <- ~w(created updated deleted), do: RF.bind!(schema, "tt", event)

    ctx = %{schema: schema, slug: tenant.tenant.slug, plaintext: plaintext, user_id: user.id}
    {:ok, ctx: ctx}
  end

  defp request(method, path, ctx, body \\ %{}) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp write(ctx, name \\ "Ann") do
    Records.create_record(
      %{
        entity_type: "tt",
        field_values: %{"name" => name},
        actor_id: ctx.user_id,
        idempotency_key: Ecto.UUID.generate()
      },
      ctx.schema
    )
  end

  # Cap 2: fills the backlog with two pending rows and returns the first record's id.
  defp fill!(ctx) do
    {:ok, %{record: record}} = write(ctx)
    {:ok, _} = write(ctx, "Bob")
    assert length(RF.outbox_rows(ctx.schema)) == 2
    record.record_id
  end

  defp drain!(ctx) do
    Repo.update_all(Letflow.RecordTriggers.OutboxRow, [set: [status: :done]], prefix: ctx.schema)
  end

  defp assert_full(conn) do
    assert conn.status == 503, conn.resp_body
    assert Jason.decode!(conn.resp_body) == %{"error" => "trigger_backlog_full"}
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  defp latest_count(ctx), do: Repo.aggregate(Latest, :count, prefix: ctx.schema)

  defp import_body(records, upsert?) do
    base = %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => "tt",
      "records" => records
    }

    if upsert?, do: Map.put(base, "upsert_by", "external_ref"), else: base
  end

  defp upsert_entry(id, name),
    do: %{"external_ref" => %{"system" => "s", "id" => id}, "field_values" => %{"name" => name}}

  test "H1 create answers 503 with Retry-After and commits nothing", %{ctx: ctx} do
    fill!(ctx)
    rows = RF.outbox_rows(ctx.schema)

    conn =
      request(:post, "/api/v1/entities/records/tt", ctx, %{"field_values" => %{"name" => "Cy"}})

    assert_full(conn)
    assert latest_count(ctx) == 2
    assert RF.outbox_rows(ctx.schema) == rows
  end

  test "H2 update answers 503", %{ctx: ctx} do
    record_id = fill!(ctx)

    conn =
      request(:put, "/api/v1/entities/records/tt/#{record_id}", ctx, %{
        "field_values" => %{"name" => "Zed"}
      })

    assert_full(conn)
    assert length(RF.outbox_rows(ctx.schema)) == 2
  end

  test "H3 delete answers 503", %{ctx: ctx} do
    record_id = fill!(ctx)
    conn = request(:delete, "/api/v1/entities/records/tt/#{record_id}", ctx)
    assert_full(conn)
    assert length(RF.outbox_rows(ctx.schema)) == 2
  end

  test "H4 import upsert answers 503, nothing committed", %{ctx: ctx} do
    fill!(ctx)

    conn =
      request(
        :post,
        "/api/v1/entities/records/tt/import",
        ctx,
        import_body([upsert_entry("1", "Ann")], true)
      )

    assert_full(conn)
    assert latest_count(ctx) == 2
  end

  test "H4b create-mode import filling partway keeps 200 with a per-entry reason", %{ctx: ctx} do
    {:ok, _} = write(ctx)

    records =
      for n <- 1..3,
          do: %{"record_id" => Ecto.UUID.generate(), "field_values" => %{"name" => "n#{n}"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          self(),
          {:conn,
           request(:post, "/api/v1/entities/records/tt/import", ctx, import_body(records, false))}
        )
      end)

    assert_received {:conn, conn}
    assert conn.status == 200, conn.resp_body
    assert [ok, full1, full2] = Jason.decode!(conn.resp_body)["results"]
    assert ok["status"] == "ok"

    for r <- [full1, full2],
        do: assert(%{"status" => "error", "reason" => %{"type" => "trigger_backlog_full"}} = r)

    refute conn.resp_body =~ "internal_error"
    refute log =~ "entity record import entry failed"
    assert get_resp_header(conn, "retry-after") == []
  end

  test "H4c upsert import filling partway answers 503; a re-POST after draining is in place", %{
    ctx: ctx
  } do
    {:ok, _} = write(ctx)
    body = import_body(for(n <- 1..3, do: upsert_entry("#{n}", "n#{n}")), true)

    assert_full(request(:post, "/api/v1/entities/records/tt/import", ctx, body))
    committed = latest_count(ctx)
    assert committed == 2

    drain!(ctx)
    conn = request(:post, "/api/v1/entities/records/tt/import", ctx, body)
    assert conn.status == 200, conn.resp_body
    assert length(Jason.decode!(conn.resp_body)["results"]) == 3
    # the pre-existing record plus exactly three imported ones: the entry committed by the first
    # call was updated in place, not duplicated.
    assert latest_count(ctx) == 4
  end

  test "H5 a forced trigger_enqueue_failed stays a 500", %{ctx: ctx} do
    schema = ctx.schema
    Repo.query!(~s(ALTER TABLE "#{schema}".record_trigger_outbox RENAME TO outbox_moved))

    try do
      conn =
        ExUnit.CaptureLog.with_log(fn ->
          request(:post, "/api/v1/entities/records/tt", ctx, %{
            "field_values" => %{"name" => "Cy"}
          })
        end)
        |> elem(0)

      assert conn.status == 500
      refute conn.resp_body =~ "trigger_backlog_full"
    after
      Repo.query!(~s(ALTER TABLE "#{schema}".outbox_moved RENAME TO record_trigger_outbox))
    end
  end
end
