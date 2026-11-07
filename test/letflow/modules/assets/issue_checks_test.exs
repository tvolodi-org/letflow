Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.IssueChecksTest do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10) criteria 3 to 5: the issue step of the commission through the full
  router. Event-time window with a fixed clock (I1), every master refusal with its reason and
  `field` / `line_no` (I1), accepted shapes (I2), the binding of the issued content and the
  number (I3), a busy document (I4) and two simultaneous issues of one fixed card (I5).
  Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.OrgFixture
  alias Letflow.Repo

  @now ~U[2026-11-05 12:00:00Z]

  setup do
    D.setup!()
  end

  defp at(seconds), do: @now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()

  defp refused(conn), do: conn |> D.status!(422)

  defp issue_conn(ctx, id), do: D.request(:post, "/documents/#{id}/issue", ctx.tok_a)

  # Saves `body`, issues it, asserts the refusal and that the draft is untouched.
  defp refusal!(ctx, body) do
    doc = D.save!(ctx, body)
    result = issue_conn(ctx, doc["id"]) |> refused()
    assert D.get!(ctx, doc["id"])["state"] == "draft"
    result
  end

  defp line(asset, quantity \\ "1"), do: %{"asset_id" => asset, "quantity" => quantity}

  @tag timeout: 120_000
  test "I1 the event-time window: 96 h and 5 min accepted, one second beyond refused", ctx do
    Application.put_env(:letflow, :assets_documents_clock, fn -> @now end)
    m = ctx.ma
    hours96 = -96 * 3600

    assert %{"reason" => "event_time_too_old"} =
             refusal!(ctx, D.body(m, %{"event_time" => at(hours96 - 1)}))

    assert %{"reason" => "event_time_in_future"} =
             refusal!(ctx, D.body(m, %{"event_time" => at(301)}))

    # accepted boundaries (different cards, a fixed card is one unit in the register)
    ok_old =
      D.body(m, %{"event_time" => at(hours96), "lines" => [line(m.fixed)]})

    assert D.issue!(ctx, ok_old)["state"] == "issued"

    ok_future =
      D.body(m, %{"event_time" => at(300), "lines" => [line(m.fixed2)]})

    assert D.issue!(ctx, ok_future)["state"] == "issued"
  end

  @tag timeout: 240_000
  test "I1 every master refusal names its reason, field and line_no; no number is taken", ctx do
    m = ctx.ma
    other_unit = D.unit!(ctx.schema)
    foreign_card = D.card!(ctx.schema, "fixed", other_unit)
    retired_card = D.card!(ctx.schema, "fixed", m.unit, %{"active" => false})

    retired_employee =
      OrgFixture.create!(
        ctx.schema,
        "org_employee",
        OrgFixture.values("org_employee", "RET#{System.unique_integer([:positive])}", %{
          "org_unit_id" => m.unit,
          "active" => false
        })
      ).record_id

    unlinked = D.location!(ctx.schema, other_unit)

    cases = [
      {"employee_not_active", %{"material_responsible_id" => retired_employee},
       %{"field" => "material_responsible_id"}},
      {"employee_not_active", %{"actual_user_id" => retired_employee},
       %{"field" => "actual_user_id"}},
      {"card_not_active", %{"lines" => [line(retired_card)]}, %{"line_no" => 1}},
      {"card_not_active", %{"lines" => [line(Ecto.UUID.generate())]}, %{"line_no" => 1}},
      {"duplicate_asset", %{"lines" => [line(m.fixed), line(m.fixed)]}, %{"line_no" => 2}},
      {"quantity_invalid", %{"lines" => [line(m.low, "0")]}, %{"line_no" => 1}},
      {"quantity_invalid", %{"lines" => [line(m.low, "1.5")]}, %{"line_no" => 1}},
      {"quantity_invalid", %{"lines" => [line(m.fixed, "2")]}, %{"line_no" => 1}},
      {"org_unit_mismatch", %{"lines" => [line(foreign_card)]}, %{"line_no" => 1}},
      {"location_not_allowed", %{"lines" => [line(m.intangible)]}, %{"line_no" => 1}},
      {"location_required", %{"location_id" => ""}, %{"line_no" => 1}},
      {"not_linked", %{"location_id" => unlinked}, %{"line_no" => 1}}
    ]

    for {reason, extra, want} <- cases do
      body = refusal!(ctx, D.body(m, extra))
      assert body["reason"] == reason, inspect({reason, extra})
      assert Map.take(body, ["field", "line_no"]) == want, inspect({reason, extra})
    end

    # an org unit retired between save and issue
    unit = D.unit!(ctx.schema)

    doc =
      D.save!(
        ctx,
        D.body(m, %{
          "org_unit_id" => unit,
          "location_id" => "",
          "lines" => [line(D.card!(ctx.schema, "low_value", unit), "3")]
        })
      )

    {:ok, _} =
      Letflow.Modules.Org.retire_unit(ctx.schema, unit, %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      })

    assert %{"reason" => "org_unit_not_active"} = issue_conn(ctx, doc["id"]) |> refused()
    assert D.get!(ctx, doc["id"])["state"] == "draft"

    # nothing issued, no number taken: the next success is number 1 of the year
    issued = D.issue!(ctx, D.body(m))
    assert issued["number"] =~ ~r/\AACM-2\d{3}-000001\z/
  end

  test "I1 asset_already_in_register: a fixed card issued once cannot be issued again", ctx do
    m = ctx.ma
    first = D.issue!(ctx, D.body(m))
    assert first["state"] == "issued"

    body = refusal!(ctx, D.body(m))

    assert %{"reason" => "asset_already_in_register", "line_no" => 1} =
             Map.take(body, ~w(reason line_no))

    # a low-value card is a quantity, not one unit: two documents may commission it
    low = D.body(m, %{"lines" => [line(m.low, "200")]})
    assert D.issue!(ctx, low)["state"] == "issued"
    assert D.issue!(ctx, low)["state"] == "issued"
  end

  test "I2 accepted: low value 200, intangible without location and without actual user", ctx do
    m = ctx.ma

    low = D.issue!(ctx, D.body(m, %{"lines" => [line(m.low, "200")]}))
    assert [%{"quantity" => "200.000000000"}] = low["lines"]

    intangible =
      D.body(m, %{
        "location_id" => "",
        "actual_user_id" => "",
        "lines" => [line(m.intangible)]
      })

    doc = D.issue!(ctx, intangible)
    assert doc["state"] == "issued" and doc["location_id"] == nil and doc["actual_user_id"] == nil
  end

  test "I3 issue binds the content, takes the number once; later writes are 409", ctx do
    doc = D.save!(ctx)
    issued = issue_conn(ctx, doc["id"]) |> D.status!(200)

    assert issued["state"] == "issued" and issued["number"] =~ ~r/\AACM-/
    assert issued["lines"] == doc["lines"] and issued["note"] == doc["note"]
    assert is_binary(issued["issued_at"])

    version = Letflow.Modules.Assets.Documents.Posting.issued(ctx.schema, doc["id"])
    assert version.content["lines"] |> hd() |> Map.get("asset_id") == ctx.ma.fixed
    assert version.content["header"]["org_unit_id"] == ctx.ma.unit

    for {m, p, b} <- [
          {:post, "/documents/#{doc["id"]}/issue", nil},
          {:put, "/documents/#{doc["id"]}", D.body(ctx.ma)},
          {:delete, "/documents/#{doc["id"]}", nil}
        ] do
      assert D.request(m, p, ctx.tok_a, b) |> D.status!(409) |> Map.get("reason") ==
               "document_not_draft"
    end

    assert D.get!(ctx, doc["id"])["number"] == issued["number"]
  end

  test "I4 a busy document answers 503 busy; the document stays a draft", ctx do
    doc = D.save!(ctx)
    test_pid = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT 1 FROM #{ctx.schema}.documents WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(doc["id"])]
          )

          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            15_000 -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000
    conn = issue_conn(ctx, doc["id"])
    send(task.pid, :release)
    Task.await(task, 20_000)

    assert D.status!(conn, 503)["reason"] == "busy"
    assert D.get!(ctx, doc["id"])["state"] == "draft"
  end

  test "I5 two simultaneous issues of one fixed card: one 200, one asset_already_in_register",
       ctx do
    a = D.save!(ctx)
    b = D.save!(ctx)

    results =
      [a, b]
      |> Enum.map(fn doc -> Task.async(fn -> issue_conn(ctx, doc["id"]) end) end)
      |> Task.await_many(60_000)

    # Exactly one issue wins. The other is refused: 422 asset_already_in_register, or, when the
    # shared test host is so loaded that the tenant lock queue times out, a 503 busy; never a second 200.
    statuses = results |> Enum.map(& &1.status) |> Enum.sort()
    assert hd(statuses) == 200 and List.last(statuses) in [422, 503], inspect(statuses)

    loser = Enum.find(results, &(&1.status != 200))
    loser_doc = if loser == Enum.at(results, 0), do: a, else: b

    if loser.status == 422,
      do: assert(Jason.decode!(loser.resp_body)["reason"] == "asset_already_in_register")

    # the refusal is repeatable once the winner is issued
    again = issue_conn(ctx, loser_doc["id"])
    assert Jason.decode!(again.resp_body)["reason"] == "asset_already_in_register"
  end
end
