defmodule Letflow.Ledger.PostingGuardTest do
  @moduledoc """
  REQ-764 / GH #3907 criteria 2, 3, 4 and 6 (decision 0073 "Amended by REQ-764"): the optional
  posting guard of a ledger registration, called by the platform in the plan step of
  `Letflow.Ledger.HandlerPost` under the shared hold lock; the refusal `posting_held`; the hold locks;
  the audit of a refused completion.

  Fixture: the `beta` registration of `Letflow.Modules.FixtureLedgerPost` declares the guard
  `Letflow.Modules.FixtureLedgerPost.PostingGuard` (alias `posting_held` -> `fxlp_held`); `alpha`
  declares none. Tests drive the real task completion (`Engine.complete_task/3`, and the real
  `Letflow.Routers.Tasks` for the wire). The tests of the hold locks run in Sandbox `:auto` mode on a
  committed tenant (second connections).
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Ledger
  alias Letflow.Ledger.Failure
  alias Letflow.LedgerFixture, as: LF
  alias Letflow.LedgerPostFixture, as: Fx
  alias Letflow.Modules.FixtureLedgerPost.PostingGuard

  @beta "fixture_ledger_post:beta"
  @item "item-zz"

  defp beta(posting), do: Fx.post_line("post_beta", posting)
  defp alpha(posting), do: Fx.post_line("post_alpha", posting)

  defp case!(slug, lines, opts \\ []) do
    ctx = Fx.case!(slug, lines, opts)
    PostingGuard.observe(ctx.schema, self())
    on_exit(fn -> PostingGuard.forget(ctx.schema) end)
    ctx
  end

  defp route_complete(ctx) do
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.completer.id])

    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, %{})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: ctx.completer.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN", "REVIEWER"],
      credential: :oidc
    })
    |> assign(:trace_id, "req764-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp task_status(ctx) do
    %{rows: [[status]]} =
      Repo.query!(~s|SELECT status FROM "#{ctx.schema}".tasks WHERE id = $1|, [
        Ecto.UUID.dump!(ctx.task.id)
      ])

    status
  end

  defp audits(schema, action) do
    %{rows: rows} =
      Repo.query!(~s|SELECT after_state FROM "#{schema}".audit_entries WHERE action = $1|, [
        action
      ])

    Enum.map(rows, fn [state] -> state end)
  end

  defp hold_key(prefix, ledger_id) do
    %{rows: [[class, obj]]} =
      Repo.query!(
        "SELECT ((h >> 32) & 4294967295)::bigint, (h & 4294967295)::bigint FROM (SELECT hashtextextended($1, 0) AS h) t",
        [prefix <> ":ledger_hold:" <> ledger_id]
      )

    [class, obj]
  end

  describe "C2 the call" do
    test "G1 G2 once per planned posting, inside the transaction, with the neutral summary" do
      posting =
        Fx.posting("receipt", @item, "5", %{
          "legs" => [
            %{"k" => [@item, ""], "quantity" => "5", "unit_ref" => "u1"},
            %{"k" => [@item, ""], "quantity" => "2", "unit_ref" => "u1"},
            %{"k" => ["item-aa", ""], "quantity" => "1", "unit_ref" => "u1"}
          ]
        })

      ctx = case!("req764-g1", [beta(posting)])
      assert {:ok, _} = Fx.complete(ctx)

      schema = ctx.schema

      assert_received {:guard_called, ^schema, summary, facts}
      refute_received {:guard_called, _, _, _}

      assert summary == %{
               ledger_id: @beta,
               cause: "receipt",
               document_type: "doc",
               document_id: "d1",
               keys: [%{"k1" => "item-aa", "k2" => ""}, %{"k1" => @item, "k2" => ""}]
             }

      assert Enum.sort(Map.keys(summary)) ==
               [:cause, :document_id, :document_type, :keys, :ledger_id]

      # inside the completion transaction, under the shared hold lock, before any ledger write
      assert facts.in_transaction
      assert hold_key(schema, @beta) in facts.shared_holds
      assert facts.entries == 0
      assert {1, 3, 2, 1} = Fx.ledger_counts(schema)
    end

    test "G3 a reversal's keys and document reference come from the reversed entry" do
      ctx = case!("req764-g3", [beta(Fx.posting("receipt", @item, "5"))])
      assert {:ok, _} = Fx.complete(ctx)
      assert_received {:guard_called, _, _, _}

      %{rows: [[entry_id]]} =
        Repo.query!(~s|SELECT id FROM "#{ctx.schema}".ledger_entry LIMIT 1|)

      reversal = %{
        "cause" => "reversal",
        "reverses_entry_id" => Ecto.UUID.load!(entry_id),
        "reason_code" => "r1"
      }

      ctx2 = Fx.more_task!(ctx, [beta(reversal)])
      assert {:ok, _} = Fx.complete(ctx2)

      schema = ctx.schema
      assert_received {:guard_called, ^schema, summary, _facts}

      assert summary == %{
               ledger_id: @beta,
               cause: "reversal",
               document_type: "doc",
               document_id: "d1",
               keys: [%{"k1" => @item, "k2" => ""}]
             }
    end

    test "G3b a reversal of an unknown entry gets empty keys and is refused as before" do
      ctx = case!("req764-g3b", [])

      reversal = %{
        "cause" => "reversal",
        "reverses_entry_id" => Ecto.UUID.generate(),
        "reason_code" => "r1"
      }

      ctx = Fx.more_task!(ctx, [beta(reversal)])

      assert {:error,
              {:entity_write_refused_detailed, 0, :validation_failed, _,
               %{reason: "movement_not_found"}}} =
               Fx.complete(ctx)

      schema = ctx.schema
      assert_received {:guard_called, ^schema, %{keys: []}, _facts}
    end

    test "G4 no call when the authority check refuses" do
      ctx = case!("req764-g4", [beta(Fx.posting("receipt", @item, "5"))])

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, credential: :api_token)

      refute_received {:guard_called, _, _, _}
    end

    test "G5 no call when a deferred refusal is released" do
      ctx = case!("req764-g5", [beta(Fx.posting("bogus_cause", @item, "5"))])
      assert {:error, _} = Fx.complete(ctx)
      refute_received {:guard_called, _, _, _}
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end

    test "G6 no call and no hold lock in a dry build (REQ-688 pre-step)" do
      ctx = case!("req764-g6", [])
      line = beta(Fx.posting("receipt", @item, "5"))

      {set, statements} =
        LF.record(fn ->
          Fx.prelock_set(ctx, [line], origin: {:dispatch, ctx.task.id}, consent: true)
        end)

      assert is_map(set)
      refute_received {:guard_called, _, _, _}
      refute Enum.any?(statements, fn {sql, _} -> sql =~ "advisory" end)
    end

    test "G7 a registration without a guard: no call and no hold lock" do
      ctx = case!("req764-g7", [alpha(Fx.posting("receipt", @item, "5"))])
      {result, statements} = LF.record(fn -> Fx.complete(ctx) end)
      assert {:ok, _} = result
      refute_received {:guard_called, _, _, _}
      refute Enum.any?(statements, fn {sql, _} -> sql =~ "pg_advisory" end)
    end

    test "G8 a held first posting stops the second: its guard is never called" do
      ctx =
        case!("req764-g8", [
          beta(Fx.posting("receipt", @item, "5")),
          alpha(Fx.posting("receipt", @item, "5"))
        ])

      PostingGuard.set(ctx.schema, {:held, "freeze.1"})
      assert {:error, {:entity_write_refused_detailed, 0, :posting_held, _, _}} = Fx.complete(ctx)
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end
  end

  describe "C3 the refusal" do
    test "H1 held: Multi reason, Failure.map, the 409 route, nothing written, task pending" do
      ctx = case!("req764-h1", [beta(Fx.posting("receipt", @item, "5"))])
      PostingGuard.set(ctx.schema, {:held, "freeze.1"})

      assert {:error, {:line, _, :ledger_post}, reason, _changes} =
               Fx.run_lines(ctx, [beta(Fx.posting("receipt", @item, "5"))])

      assert {:ledger_held, facts,
              {:ledger_refused, :posting_held, "fxlp_held", %{held_by: "freeze.1"}} = inner} =
               reason

      assert facts == %{
               module_id: "fixture_ledger_post",
               ledger_id: @beta,
               cause: "receipt",
               document_type: "doc",
               document_id: "d1",
               held_by: "freeze.1"
             }

      assert {:refused_detailed, 0, :posting_held, "fxlp_held", _detail, %{held_by: "freeze.1"}} =
               Failure.map(0, inner)

      conn = route_complete(ctx)
      assert conn.status == 409

      assert %{"error" => "fxlp_held", "line_index" => 0, "details" => %{"held_by" => "freeze.1"}} =
               body(conn)

      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
      assert task_status(ctx) in ["PENDING"]
    end

    test "H3 to H5 any other answer or a bad label is the closed failure, no text kept" do
      for {slug, mode} <- [
            {"h3", :other},
            {"h4", {:held, String.duplicate("a", 65)}},
            {"h5", {:held, "has space"}},
            {"h5b", {:held, ""}},
            {"h5c", {:held, :atom}}
          ] do
        ctx = case!("req764-" <> slug, [beta(Fx.posting("receipt", @item, "5"))])
        PostingGuard.set(ctx.schema, mode)

        assert {:error, {:entity_write_failed, 0, :ledger_post}} = Fx.complete(ctx)
        assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
      end
    end

    for {slug, mode} <- [{"h6", :raise}, {"h7", :throw}, {"h8", :exit}] do
      test "#{String.upcase(slug)} a guard that does #{mode} fails closed, nothing leaks" do
        ctx = case!("req764-#{unquote(slug)}", [beta(Fx.posting("receipt", @item, "5"))])
        PostingGuard.set(ctx.schema, unquote(mode))

        log =
          capture_log(fn ->
            conn = route_complete(ctx)
            assert conn.status == 500
            refute conn.resp_body =~ "secret guard text"
            refute conn.resp_body =~ "secret_guard_text"
          end)

        refute log =~ "secret guard text"
        refute log =~ "secret_guard_text"
        assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
        assert audits(ctx.schema, "ledger.posting_held") == []
      end
    end
  end

  describe "C7 the decision record" do
    test "decision 0073 has the section Amended by REQ-764" do
      text = File.read!("docs/migration/decisions/0073-domain-neutral-ledger-primitive.md")
      assert text =~ "## Amended by REQ-764"
      assert text =~ "posting_held"
      assert text =~ ":ledger_hold:"
    end
  end

  describe "C6 the audit" do
    test "A1 one ledger.posting_held entry, ids and labels only, no entity_write.refused" do
      ctx = case!("req764-a1", [beta(Fx.posting("receipt", @item, "5"))])
      PostingGuard.set(ctx.schema, {:held, "freeze.1"})

      assert {:error, {:entity_write_refused_detailed, 0, :posting_held, "fxlp_held", _}} =
               Fx.complete(ctx)

      assert [state] = audits(ctx.schema, "ledger.posting_held")

      assert state == %{
               "task_id" => ctx.task.id,
               "module_id" => "fixture_ledger_post",
               "ledger_id" => @beta,
               "cause" => "receipt",
               "document_type" => "doc",
               "document_id" => "d1",
               "held_by" => "freeze.1"
             }

      refute Jason.encode!(state) =~ @item
      refute Jason.encode!(state) =~ "u1"
      assert audits(ctx.schema, "entity_write.refused") == []
    end
  end

  describe "C4 and C6 on a committed tenant (second connections)" do
    setup do
      LF.setup_auto_mode!()
      :ok
    end

    defp committed_case(slug) do
      ctx = case!(slug, [beta(Fx.posting("receipt", @item, "5"))], committed: true)
      Repo.query!(~s|CREATE TABLE "#{ctx.schema}".fxlp_hold (label text)|)
      PostingGuard.set(ctx.schema, :table)
      ctx
    end

    test "L1 the shared hold lock is held during the guard call" do
      ctx = committed_case("req764-l1")
      PostingGuard.set(ctx.schema, :ok)
      assert {:ok, _} = Fx.complete(ctx)
      schema = ctx.schema
      assert_received {:guard_called, ^schema, _summary, facts}
      assert hold_key(schema, @beta) in facts.shared_holds
    end

    test "L2 hold_exclusive! raises outside a transaction and on a bad argument" do
      ctx = committed_case("req764-l2")

      assert_raise ArgumentError, fn -> Ledger.hold_exclusive!(ctx.schema, @beta) end

      assert {:ok, :ok} = Repo.transaction(fn -> Ledger.hold_exclusive!(ctx.schema, @beta) end)

      assert {:error, _} =
               Repo.transaction(fn ->
                 try do
                   Ledger.hold_exclusive!("public; drop", @beta)
                 rescue
                   e in ArgumentError -> Repo.rollback(e)
                 end
               end)

      assert {:error, _} =
               Repo.transaction(fn ->
                 try do
                   Ledger.hold_exclusive!(ctx.schema, "")
                 rescue
                   e in ArgumentError -> Repo.rollback(e)
                 end
               end)
    end

    defp waiting_shared_lock?(key) do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND mode = 'ShareLock' AND NOT granted AND classid::bigint = $1 AND objid::bigint = $2",
          key
        )

      n > 0
    end

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition not reached")
        true -> Process.sleep(50) && wait_until(fun, tries - 1)
      end
    end

    defp run_a(ctx, finish) do
      parent = self()

      Task.async(fn ->
        Repo.transaction(fn ->
          Ledger.hold_exclusive!(ctx.schema, @beta)
          Repo.query!(~s|INSERT INTO "#{ctx.schema}".fxlp_hold (label) VALUES ('freeze.9')|)
          send(parent, :a_ready)

          receive do
            :a_finish -> :ok
          after
            10_000 -> :ok
          end

          if finish == :rollback, do: Repo.rollback(:a_rolled_back)
          :ok
        end)
      end)
    end

    test "L3 A holds the exclusive lock and commits a row: B waits, reads it, is held (409)" do
      ctx = committed_case("req764-l3")
      a = run_a(ctx, :commit)
      assert_receive :a_ready, 5_000

      b = Task.async(fn -> Fx.complete(ctx) end)
      wait_until(fn -> waiting_shared_lock?(hold_key(ctx.schema, @beta)) end)
      send(a.pid, :a_finish)

      assert {:ok, :ok} = Task.await(a, 10_000)

      assert {:error, {:entity_write_refused_detailed, 0, :posting_held, "fxlp_held", d}} =
               Task.await(b, 10_000)

      assert d == %{held_by: "freeze.9"}
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end

    test "L4 A rolls back: B commits its posting" do
      ctx = committed_case("req764-l4")
      a = run_a(ctx, :rollback)
      assert_receive :a_ready, 5_000

      b = Task.async(fn -> Fx.complete(ctx) end)
      wait_until(fn -> waiting_shared_lock?(hold_key(ctx.schema, @beta)) end)
      send(a.pid, :a_finish)

      assert {:error, :a_rolled_back} = Task.await(a, 10_000)
      assert {:ok, _} = Task.await(b, 10_000)
      assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
    end

    test "A2 a failing audit write is logged by tag and leaves the 409 unchanged" do
      ctx = committed_case("req764-a2")
      PostingGuard.set(ctx.schema, {:held, "freeze.1"})
      schema = ctx.schema

      Repo.query!("""
      CREATE FUNCTION "#{schema}".req764_fail() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'req764 injected failure' USING ERRCODE = 'unique_violation';
      END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER req764_fail BEFORE INSERT ON "#{schema}".audit_entries
      FOR EACH ROW WHEN (NEW.action = 'ledger.posting_held')
      EXECUTE FUNCTION "#{schema}".req764_fail()
      """)

      log =
        capture_log(fn ->
          conn = route_complete(ctx)
          assert conn.status == 409
          assert %{"error" => "fxlp_held"} = body(conn)
        end)

      assert log =~ "ledger.posting_held"
      assert audits(schema, "ledger.posting_held") == []
      assert {0, 0, 0, 0} = Fx.ledger_counts(schema)
    end
  end
end
