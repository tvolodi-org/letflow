defmodule Letflow.RecordTriggers.OutboxHttpTest do
  @moduledoc """
  REQ-606 / GH #3411 part 1, criterion 6 (G2..G4): lineage cannot be forged through the HTTP record
  routes. A create, an update and an upsert (import) whose field values are named `trigger_lineage`,
  `depth` and `chain`, with values that would suppress the trigger, are accepted, write the record and
  still insert one outbox row of depth 0 and an empty chain. `async: false`: committed provisioned
  tenant, VM-global OIDC config.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Support.ScopeWritesFixture, as: W

  @type_name "r606_http"

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end
    end)

    fx = W.provision!("r606h")
    schema = fx.schema_name

    fields =
      for f <- ~w(label trigger_lineage depth chain),
          do: %{name: f, type: :string, required: f == "label"}

    {:ok, row} =
      Definitions.create_definition(
        %{
          definition: %{name: @type_name, display_name: @type_name, fields: fields},
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    {:ok, _} = Definitions.activate_definition(row.name, Ecto.UUID.generate(), "r606", schema)
    created = RF.bind!(schema, @type_name, "created")
    updated = RF.bind!(schema, @type_name, "updated")
    {:ok, fx: fx, schema: schema, created: created, updated: updated}
  end

  defp forged(label, binding_id),
    do: %{
      "label" => label,
      "trigger_lineage" => binding_id,
      "depth" => "3",
      "chain" => binding_id
    }

  test "G2 HTTP create writes a depth 0 row", %{fx: fx, schema: s, created: b} do
    conn =
      W.admin_request(fx, :post, W.records_path(@type_name, nil), %{
        "field_values" => forged("one", b.id)
      })

    assert conn.status in [200, 201], conn.resp_body
    assert [%{event: :created, depth: 0, chain: [], binding_id: id}] = RF.outbox_rows(s)
    assert id == b.id
  end

  test "G3 HTTP update writes a depth 0 row", %{fx: fx, schema: s, created: c, updated: u} do
    conn =
      W.admin_request(fx, :post, W.records_path(@type_name, nil), %{
        "field_values" => forged("one", c.id)
      })

    record_id = W.json(conn)["record_id"] || W.json(conn)["record"]["record_id"]

    conn =
      W.admin_request(fx, :put, W.records_path(@type_name, record_id), %{
        "field_values" => forged("two", u.id)
      })

    assert conn.status == 200, conn.resp_body

    assert [%{event: :created}, %{event: :updated, depth: 0, chain: []}] = RF.outbox_rows(s)
  end

  test "G4 HTTP upsert import writes a depth 0 row", %{fx: fx, schema: s, created: b} do
    conn =
      W.admin_request(fx, :post, W.import_path(@type_name), %{
        "record_export_schema_version" => "entities/record-export/v1",
        "entity_type" => @type_name,
        "upsert_by" => "external_ref",
        "records" => [
          %{
            "external_ref" => %{"system" => "s", "id" => "1"},
            "field_values" => forged("imp", b.id)
          }
        ]
      })

    assert conn.status == 200, conn.resp_body
    assert [%{"status" => "ok", "outcome" => "created"}] = W.json(conn)["results"]
    assert [%{event: :created, depth: 0, chain: []}] = RF.outbox_rows(s)
  end
end
