defmodule Letflow.Engine.LedgerFailureMappingTest do
  @moduledoc """
  REQ-686 criteria 1 to 3 (slice L3c, note 12.2): a typed ledger refusal of a HUMAN_TASK completion
  reaches the wire as its core status, the wire code (the module's alias when it has one), the
  declared line index and the `details` map; a contract failure stays the closed 500; the audit
  entry of a refusal carries the NEUTRAL core code and no detail value.

  The HTTP tests dispatch into the real `Letflow.Routers.Tasks` with an auth context that carries the
  credential kind (the router passes it on to the engine). Fixture: `Letflow.LedgerPostFixture`.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Ledger.Failure
  alias Letflow.LedgerPostFixture, as: Fx

  defp complete(ctx, credential \\ :oidc) do
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.completer.id])

    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, %{})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: ctx.completer.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN", "REVIEWER"],
      credential: credential
    })
    |> assign(:trace_id, "req686-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp beta(posting, extra \\ %{}),
    do: Fx.post_line("post_beta", posting, extra)

  defp alpha(posting, extra \\ %{}),
    do: Fx.post_line("post_alpha", posting, extra)

  defp refusal_audits(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT after_state::text FROM "#{schema}".audit_entries WHERE action = 'entity_write.refused'|
      )

    Enum.map(rows, fn [text] -> text end)
  end

  describe "T-ERR-1 typed refusals" do
    test "insufficient_balance is 409 with the legs, the slot list and available (reader)" do
      ctx = Fx.case!("req686-e1a", [beta(Fx.posting("issue", "b", "-3"))])
      conn = complete(ctx)

      assert conn.status == 409
      assert %{"error" => "insufficient_balance", "line_index" => 0, "details" => d} = body(conn)

      assert [
               %{
                 "leg_no" => 1,
                 "k" => ["b", ""],
                 "requested" => "3.000000000",
                 "available" => "0.000000000"
               }
             ] =
               d["legs"]

      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end

    test "balance_bound_exceeded is 409" do
      uuid = Ecto.UUID.generate()

      posting = %{
        "cause" => "receipt",
        "document_type" => "doc",
        "document_id" => "d1",
        "legs" => [%{"k" => ["a", uuid], "quantity" => "2", "unit_ref" => "u1"}]
      }

      ctx = Fx.case!("req686-e1b", [beta(posting)])
      conn = complete(ctx)

      assert conn.status == 409
      assert %{"error" => "balance_bound_exceeded", "details" => %{"legs" => [_]}} = body(conn)
    end

    test "unit_mismatch is 409 against a balance of another unit" do
      other = %{
        "cause" => "receipt",
        "document_type" => "doc",
        "document_id" => "d1",
        "legs" => [%{"k" => ["b", ""], "quantity" => "1", "unit_ref" => "u2"}]
      }

      ctx = Fx.case!("req686-e1c", [beta(other)])
      seed = beta(Fx.posting("receipt", "b", "5", %{"client_op_id" => "seed"}))
      assert {:ok, _} = Fx.run_lines(ctx, [seed], origin: {:task, Ecto.UUID.generate()})

      conn = complete(ctx)
      assert conn.status == 409
      assert %{"error" => "unit_mismatch", "details" => %{"leg_no" => 1}} = body(conn)
    end

    test "invalid_posting is 422 with the closed detail shape" do
      posting = Fx.posting("receipt", "b", "not-a-number")
      ctx = Fx.case!("req686-e1d", [beta(posting)])
      conn = complete(ctx)

      assert conn.status == 422
      assert %{"error" => "invalid_posting", "details" => d} = body(conn)
      assert d["leg_no"] == 1
      assert is_binary(d["reason"])
    end

    test "a contract failure is the closed 500 with no details" do
      ctx =
        Fx.case!("req686-e1e", [
          beta(Fx.posting("receipt", "b", "5")),
          Fx.line("post_alpha", %{
            "posting" => Fx.posting("receipt", "a", "5"),
            "twice" => true,
            "skip_note" => true
          })
        ])

      conn = complete(ctx)
      assert conn.status == 500
      refute conn.resp_body =~ "details"
      refute conn.resp_body =~ "too_many"
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end

    test "an API token is refused write_not_permitted, nothing written, no details" do
      ctx = Fx.case!("req686-e1f", [beta(Fx.posting("issue", "b", "-3"))])
      conn = complete(ctx, :api_token)

      assert conn.status == 403
      assert body(conn) == %{"error" => "write_not_permitted", "line_index" => 0}
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end
  end

  describe "T-ERR-2 Failure.map and goldens" do
    test "the pure mapping table" do
      refusal = {:ledger_refused, :insufficient_balance, "short", %{legs: []}}

      assert Failure.map(3, refusal) ==
               {:refused_detailed, 3, :insufficient_balance, "short", :insufficient_balance,
                %{legs: []}}

      assert Failure.map(1, {:ledger_refused, :validation_failed, "validation_failed", %{}}) ==
               {:refused_detailed, 1, :validation_failed, "validation_failed", :validation_failed,
                %{}}

      assert Failure.map(2, {:ledger_contract, :ledger_too_many_postings}) ==
               {:failed, 2, :ledger_marker}

      assert Failure.map(2, {:ledger_refused, :made_up_code, "x", %{}}) ==
               {:failed, 2, :ledger_post}

      assert Failure.map(0, :anything) == {:failed, 0, :ledger_post}
    end

    test "bodies of the existing refusal codes are unchanged" do
      for {code, status} <- [
            write_not_permitted: 403,
            record_version_conflict: 409,
            entity_write_contention: 503,
            trigger_backlog_full: 503,
            validation_failed: 422,
            entity_append_only: 422
          ] do
        conn = Letflow.Api.Response.entity_write_refused(conn(:get, "/"), code, 2)
        assert conn.status == status

        assert Jason.decode!(conn.resp_body) == %{
                 "error" => Atom.to_string(code),
                 "line_index" => 2
               }
      end
    end
  end

  describe "T-ERR-3 no value leaks" do
    test "no quantity or slot value reaches the audit entry or the log of a refusal" do
      marker = "zq9marker"
      ctx = Fx.case!("req686-e3", [beta(Fx.posting("issue", marker, "-37"))])

      log = capture_log([level: :info], fn -> assert complete(ctx).status == 409 end)

      refute log =~ marker
      refute log =~ "37"
      audits = refusal_audits(ctx.schema)
      assert [one] = audits
      refute one =~ marker
      assert one =~ "insufficient_balance"
    end
  end

  describe "T-ERR-4 / T-ERR-5 status and alias" do
    test "the wire code is the alias, the status and the audit follow the core code" do
      ctx = Fx.case!("req686-e4", [alpha(Fx.posting("issue", "a", "-3"))])
      log = capture_log([level: :info], fn -> send(self(), {:conn, complete(ctx)}) end)
      assert_received {:conn, conn}

      assert conn.status == 409
      assert %{"error" => "fxlp_short", "line_index" => 0, "details" => d} = body(conn)
      # k stays a list with one entry per registered slot, in registered order
      assert [%{"k" => ["a", ""]}] = d["legs"]

      assert [audit] = refusal_audits(ctx.schema)
      assert audit =~ "insufficient_balance"
      refute audit =~ "fxlp_short"
      refute log =~ "fxlp_short"
    end

    test "an unaliased registration answers the neutral code" do
      ctx = Fx.case!("req686-e4b", [beta(Fx.posting("issue", "b", "-3"))])
      assert %{"error" => "insufficient_balance"} = body(complete(ctx))
    end
  end
end
