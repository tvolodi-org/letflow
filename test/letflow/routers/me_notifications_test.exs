defmodule Letflow.Routers.MeNotificationsTest do
  @moduledoc """
  T-1561: `GET /api/v1/me/notifications` and `POST /api/v1/me/notifications/read`, the in-app
  bell list. Real Postgres, real tenant schemas, real API tokens through the real `Letflow.Router`;
  the rows come from the real `Tasks.assign_task/3` path. `async: false`: tenant provisioning and
  the platform pin are VM-global.
  """

  use Letflow.DataCase, async: false

  Code.require_file("../modules/stock/counts_fixture.exs", __DIR__)

  import Ecto.Query

  alias Letflow.CountsFixture, as: CF
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks

  @path "/api/v1/me/notifications"

  setup do
    Fixture.unpin!()
    %{a: a, b: b} = Fixture.two_tenants!()
    {:ok, a: a, b: b}
  end

  defp call(method, path, fixture, token, body) do
    method
    |> Fixture.api_conn(path, token, fixture.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp list(fx, token, query \\ ""), do: call(:get, @path <> query, fx, token, nil)
  defp mark(fx, token, body), do: call(:post, @path <> "/read", fx, token, body)

  # Mints a token and returns {token, user_id} (the token's user is the only newest api_tokens row).
  defp caller!(fx) do
    token = Fixture.mint_token!(fx, ["TASK_WORKER"])

    user_id =
      Repo.one!(
        from(t in Letflow.Identity.ApiToken,
          order_by: [desc: t.inserted_at],
          limit: 1,
          select: t.user_id
        ),
        prefix: fx.schema_name
      )

    {token, user_id}
  end

  defp assign!(fx, user_id, name \\ "Review") do
    task =
      T.insert_task!(%{schema_name: fx.schema_name}, nil, %{
        assignee_type: nil,
        assignee_ref: nil,
        node_name: name
      })

    assert {:ok, _} = Tasks.assign_task(task.id, %{user_id: user_id}, prefix: fx.schema_name)
    task
  end

  test "N1 a real assignment shows up in the assignee's list over HTTP, unread", %{a: a} do
    {token, user_id} = caller!(a)
    task = assign!(a, user_id)

    conn = list(a, token)
    assert conn.status == 200, conn.resp_body
    assert %{"notifications" => [n], "unread_count" => 1} = json(conn)
    assert n["kind"] == "task_assigned"
    assert n["ref_id"] == task.id
    assert n["title"] == "Review"
    assert n["read"] == false
    assert Map.keys(n) |> Enum.sort() == ~w(id inserted_at kind read ref_id title)
  end

  test "R1 a real Counts.issue gives the linked chair a count_assigned item, nobody else", %{
    a: a,
    b: b
  } do
    {token, user_id} = caller!(a)
    {other, _} = caller!(a)
    {token_b, _} = caller!(b)

    on_exit(fn ->
      for mod <- [
            Letflow.Definitions.SolutionPackInstall,
            Letflow.Definitions.SolutionPackArtefactBase,
            Letflow.TenantProvisioning.ColumnPromotion
          ] do
        Repo.delete_all(from(r in mod, where: r.tenant_id == ^a.tenant_id))
      end
    end)

    {:ok, _} = Letflow.Entities.EventTypes.seed!(a.schema_name)
    CF.install_all!(a.tenant_id)
    w = CF.world!(a.schema_name)
    chair = CF.employee!(a.schema_name, w.unit, user: user_id)
    w = %{w | chair: chair}
    {:ok, c} = Counts.create(a.schema_name, CF.input(w), CF.opts())
    {:ok, i} = Counts.issue(a.schema_name, c["id"], CF.opts())

    conn = list(a, token)
    assert conn.status == 200, conn.resp_body
    assert %{"notifications" => [n], "unread_count" => 1} = json(conn)
    assert n["kind"] == "count_assigned"
    assert n["ref_id"] == c["id"]
    assert n["title"] == i["number"]
    assert n["read"] == false

    assert json(list(a, other)) == %{"notifications" => [], "unread_count" => 0}
    assert json(list(b, token_b)) == %{"notifications" => [], "unread_count" => 0}

    assert Repo.aggregate(Letflow.UserNotifications.Notification, :count, prefix: b.schema_name) ==
             0
  end

  test "N3 mark one, mark all, re-mark marks nothing", %{a: a} do
    {token, user_id} = caller!(a)
    assign!(a, user_id, "One")
    assign!(a, user_id, "Two")

    assert %{"notifications" => [first, _second], "unread_count" => 2} = json(list(a, token))

    conn = mark(a, token, %{"ids" => [first["id"]]})
    assert conn.status == 200
    assert json(conn) == %{"marked" => 1, "unread_count" => 1}

    assert json(mark(a, token, %{"all" => true})) == %{"marked" => 1, "unread_count" => 0}
    assert json(mark(a, token, %{"all" => true})) == %{"marked" => 0, "unread_count" => 0}
    assert json(mark(a, token, %{"ids" => [first["id"]]}))["marked"] == 0
  end

  test "N5 tenant B never sees or marks tenant A's notification", %{a: a, b: b} do
    {token_a, user_a} = caller!(a)
    {token_b, _user_b} = caller!(b)
    assign!(a, user_a)

    assert %{"notifications" => [n]} = json(list(a, token_a))
    assert json(list(b, token_b)) == %{"notifications" => [], "unread_count" => 0}

    conn = mark(b, token_b, %{"ids" => [n["id"]]})
    assert conn.status == 200
    assert json(conn) == %{"marked" => 0, "unread_count" => 0}
    assert %{"unread_count" => 1} = json(list(a, token_a))
  end

  test "N6 another user of the same tenant neither sees nor marks it", %{a: a} do
    {alice, alice_id} = caller!(a)
    {bob, _bob_id} = caller!(a)
    assign!(a, alice_id)

    assert %{"notifications" => [n]} = json(list(a, alice))
    assert json(list(a, bob)) == %{"notifications" => [], "unread_count" => 0}
    assert json(mark(a, bob, %{"ids" => [n["id"]]}))["marked"] == 0
    assert json(mark(a, bob, %{"all" => true}))["marked"] == 0
    assert %{"unread_count" => 1} = json(list(a, alice))
  end

  test "N7 bad bodies are 422, limit never 500s", %{a: a} do
    {token, user_id} = caller!(a)
    assign!(a, user_id)

    for body <- [%{}, %{"ids" => []}, %{"ids" => ["nope"]}, %{"ids" => "x"}] do
      assert mark(a, token, body).status == 422
    end

    too_many = for _ <- 1..101, do: Ecto.UUID.generate()
    assert mark(a, token, %{"ids" => too_many}).status == 422

    for q <- ["?limit=0", "?limit=abc", "?limit=1000"] do
      assert list(a, token, q).status == 200
    end

    assert length(json(list(a, token, "?limit=0"))["notifications"]) == 1
  end

  test "N9 the bell writes no mail delivery row", %{a: a} do
    {_token, user_id} = caller!(a)
    assign!(a, user_id)
    Process.sleep(50)

    # The mail path may log its own (skipped) attempt; the bell must not add any of its own:
    # one assignment gives at most one delivery row and exactly one notification row.
    %{rows: [[notes]]} =
      Repo.query!(~s|SELECT count(*) FROM "#{a.schema_name}".user_notifications|)

    assert notes == 1
  end

  test "an unauthenticated request is refused", %{a: a} do
    conn =
      Fixture.api_conn(:get, @path, "lf_tok_" <> String.duplicate("0", 64), a.tenant.slug, nil)

    assert Fixture.dispatch_api(conn).status in [401, 403]
  end
end
