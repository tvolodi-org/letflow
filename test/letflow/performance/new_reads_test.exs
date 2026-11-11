defmodule Letflow.Performance.NewReadsTest do
  @moduledoc """
  GH T-1692 (performance check of the reads added since B2#10): the platform rollout list, the instance replay
  data of one instance with 1000 events, the users xlsx import of 200 rows and the notification list.

  `@moduletag :new_reads_perf`: excluded by default (`test/test_helper.exs`), run on demand with
  `MIX_TEST_PARTITION=<n> mix test --only new_reads_perf test/letflow/performance/new_reads_test.exs`.
  Local test stack only, never QA. Like `pilot_volume_test.exs` it asserts nothing about the limits: a figure
  over its limit is printed (OVER) and recorded in `docs/status/new-reads-perf-2026-11.md`. Every read goes
  through the full `Letflow.Router` with a real bearer token. One sequential test, because seeding is shared.

  The replay screen reads two things per instance, both paged at 200: the timeline
  (`GET /instances/:id/timeline`) and the NODE_ENTERED history (`GET /instances/:id/history?event_type=NODE_ENTERED`);
  both walks are timed (`reconstruct` is a POST repair route behind InstancesCancel, not a read of the screen).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.EventStore.Event
  alias Letflow.Identity.User
  alias Letflow.Platform.ModuleRollout.Outcome
  alias Letflow.Platform.ModuleRollout.Rollout
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TestSupport.InstanceFixture
  alias Letflow.UserNotifications

  @moduletag :new_reads_perf
  @moduletag timeout: 600_000

  @runs 5
  @rollouts 50
  @events 1000
  @page 200
  @import_rows 200
  @notifications 200

  # limits in ms (median); own assumptions, editable here and in the status note
  @limit_rollouts 500
  @limit_timeline_walk 2_000
  @limit_history_walk 2_000
  @limit_import_dry 5_000
  @limit_import_real 15_000
  @limit_notifications 300

  defp ms(fun) do
    {micros, result} = :timer.tc(fun)
    {micros / 1000, result}
  end

  defp median(values), do: values |> Enum.sort() |> then(&Enum.at(&1, div(length(&1), 2)))

  defp ok!(conn, what) do
    assert conn.status == 200, "#{what}: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"
    conn
  end

  defp request(method, path, token, slug, body \\ nil, content_type \\ nil) do
    import Plug.Conn

    conn =
      Plug.Test.conn(method, path, body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-tenant-slug", slug)

    conn = if content_type, do: put_req_header(conn, "content-type", content_type), else: conn
    Fixture.dispatch_api(conn)
  end

  # 1 warm-up, then @runs timed runs: {median, max}
  defp measure(label, fun) do
    ok!(fun.(), label)
    values = for _ <- 1..@runs, do: elem(ms(fn -> ok!(fun.(), label) end), 0)
    {median(values), Enum.max(values)}
  end

  # walks every page like the web hook does; returns the number of items read
  defp walk(path, token, slug, extra) do
    do_walk(path, token, slug, extra, nil, 0)
  end

  defp do_walk(path, token, slug, extra, cursor, n) do
    q = "page_size=#{@page}" <> extra <> if(cursor, do: "&cursor=" <> cursor, else: "")

    body =
      request(:get, path <> "?" <> q, token, slug)
      |> ok!(path)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    items = body["items"] || body["data"] || []
    next = body["next_cursor"]
    n = n + length(items)
    if next, do: do_walk(path, token, slug, extra, next, n), else: n
  end

  defp xlsx(rows) do
    {:ok, {_name, bin}} =
      Elixlsx.write_to_memory(%Workbook{sheets: [%Sheet{name: "users", rows: rows}]}, "u.xlsx")

    bin
  end

  @xlsx_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  test "P-measure: rollout list, replay reads, users import, notification list" do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    ids = [tenants.a.tenant_id, tenants.b.tenant_id, tenants.p.tenant_id]

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      rollout_ids = Repo.all(from(o in Outcome, where: o.tenant_id in ^ids, select: o.rollout_id))
      Repo.delete_all(from(o in Outcome, where: o.rollout_id in ^rollout_ids))
      Repo.delete_all(from(r in Rollout, where: r.id in ^rollout_ids))
    end)

    a = tenants.a
    p = tenants.p
    op = Fixture.mint_token!(p, ["PLATFORM_ADMIN"])
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])

    # ── seed: rollouts (the list cap) with one outcome per tenant ─────────────────────────
    for i <- 1..@rollouts do
      rollout =
        Repo.insert!(%Rollout{
          module_id: "t1692-#{i}-" <> Ecto.UUID.generate(),
          to_version: "1.0.#{i}",
          status: if(rem(i, 5) == 0, do: "halted", else: "completed"),
          halt_after: 3,
          consecutive_failures: 0,
          started_by: Ecto.UUID.generate(),
          started_at: NaiveDateTime.add(~N[2026-11-01 10:00:00], i * 60)
        })

      for {tid, k} <- Enum.with_index(ids) do
        Repo.insert!(%Outcome{
          rollout_id: rollout.id,
          tenant_id: tid,
          status: Enum.at(["upgraded", "failed", "deferred"], rem(i + k, 3)),
          plan_hash: String.duplicate("a", 64),
          attempted_at: ~N[2026-11-10 10:01:00],
          completed_at: ~N[2026-11-10 10:02:00]
        })
      end
    end

    # ── seed: one instance with 1000 events (NODE_ENTERED, as the engine writes them) ──────
    instance_id = InstanceFixture.real_instance!(a)
    prefix = a.schema_name

    start_seq =
      Repo.one(
        from(e in Event, where: e.instance_id == ^instance_id, select: max(e.sequence_number)),
        prefix: prefix
      )

    base = DateTime.utc_now()

    rows =
      for i <- 1..@events do
        %{
          event_id: Ecto.UUID.generate(),
          created_at: DateTime.add(base, i, :millisecond),
          instance_id: instance_id,
          event_type: "NODE_ENTERED",
          payload: %{"node_id" => "task", "node_type" => "HUMAN_TASK", "via_edge_id" => "e#{i}"},
          actor_id: Ecto.UUID.generate(),
          sequence_number: start_seq + i,
          idempotency_key: "t1692-#{instance_id}-#{i}",
          metadata: %{}
        }
      end

    rows |> Enum.chunk_every(250) |> Enum.each(&Repo.insert_all(Event, &1, prefix: prefix))

    # ── seed: notifications for the token's user ──────────────────────────────────────────
    user =
      Repo.one(from(u in User, where: like(u.username, "scope-caller-%"), limit: 1),
        prefix: prefix
      )

    for i <- 1..@notifications do
      UserNotifications.notify(
        prefix,
        a.tenant_id,
        user.id,
        "task_assigned",
        Ecto.UUID.generate(),
        "Task #{i}"
      )
    end

    # the user the token belongs to is the one just minted for `admin`; use its notifications
    slug = a.tenant.slug
    pslug = p.tenant.slug

    results = []

    {m, x} =
      measure("rollout list", fn ->
        request(:get, "/api/v1/platform-module-rollouts", op, pslug)
      end)

    results = [
      {"R1 rollout list (#{@rollouts} rollouts, 3 outcomes each)", m, x, @limit_rollouts}
      | results
    ]

    base_path = "/api/v1/instances/#{instance_id}"

    {tm, tx} =
      measure("timeline walk", fn ->
        n = walk(base_path <> "/timeline", admin, slug, "")
        assert n >= @events
        %{status: 200, resp_body: ""}
      end)

    results = [
      {"T1 timeline, all pages of #{@page} (#{@events} events)", tm, tx, @limit_timeline_walk}
      | results
    ]

    {hm, hx} =
      measure("history walk", fn ->
        n = walk(base_path <> "/history", admin, slug, "&event_type=NODE_ENTERED")
        assert n >= @events
        %{status: 200, resp_body: ""}
      end)

    results = [
      {"T2 NODE_ENTERED history, all pages of #{@page}", hm, hx, @limit_history_walk} | results
    ]

    shown = request(:get, "/api/v1/me/notifications?limit=100", admin, slug)
    assert length(Jason.decode!(shown.resp_body)["notifications"]) == 100

    {nm, nx} =
      measure("notifications", fn ->
        request(:get, "/api/v1/me/notifications?limit=100", admin, slug)
      end)

    results = [
      {"N1 notification list (#{@notifications} stored, limit 100)", nm, nx, @limit_notifications}
      | results
    ]

    # ── users import ──────────────────────────────────────────────────────────────────────
    header = ["username", "display_name", "email"]

    file =
      xlsx([
        header
        | for(n <- 1..@import_rows, do: ["p1692-#{n}", "Person #{n}", "p1692-#{n}@example.test"])
      ])

    imp = "/api/v1/identity/users/import"

    {dm, dx} =
      measure("import dry run", fn ->
        request(:post, imp <> "?dry_run=true", admin, slug, file, @xlsx_type)
      end)

    results = [
      {"U1 users import dry run, #{@import_rows} rows", dm, dx, @limit_import_dry} | results
    ]

    {first, conn} = ms(fn -> request(:post, imp, admin, slug, file, @xlsx_type) end)
    ok!(conn, "import real")

    assert Repo.aggregate(from(u in User, where: like(u.username, "p1692-%")), :count,
             prefix: prefix
           ) == @import_rows

    results = [
      {"U2 users import real run, #{@import_rows} rows created (one run)", first, first,
       @limit_import_real}
      | results
    ]

    {um, ux} =
      measure("import again", fn -> request(:post, imp, admin, slug, file, @xlsx_type) end)

    results = [
      {"U3 users import again, #{@import_rows} rows unchanged", um, ux, @limit_import_real}
      | results
    ]

    IO.puts("\nT-1692 new reads: median / max ms over #{@runs} runs (warm-up not counted)")

    for {label, med, max, limit} <- Enum.reverse(results) do
      flag = if med > limit, do: "OVER", else: "ok"

      IO.puts(
        "  #{String.pad_trailing(label, 70)} #{Float.round(med, 1)} / #{Float.round(max, 1)}  limit #{limit}  #{flag}"
      )
    end
  end
end
