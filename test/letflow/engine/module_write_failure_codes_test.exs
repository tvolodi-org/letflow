defmodule Letflow.Engine.ModuleWriteFailureCodesTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design section 8, section 11 rows "Codes" and "Handler runs inside
  the step Multi"): the failure mapping of a handler call during the completion transaction.

    * the handler said "not permitted", or tried a type outside its registered targets: ONE
      public refusal `write_not_permitted` (403), audit detail `handler_not_permitted`;
    * the handler said "invalid arguments", or a required argument resolved to nothing:
      `validation_failed` (422), audit detail `handler_invalid_arguments`;
    * the handler raised, THREW, EXITED, returned a non-Multi, smuggled in a step with a live
      repo, used a loose step name, or dropped a write's `:policy` step: an INTERNAL failure
      `{:entity_write_failed, index, :handler}` (500, no body detail), and no exception text
      reaches a log line.

  Every case: nothing committed, the task stays `pending`. The misbehaving handlers are the
  `FixtureLedgerRogue` negative controls (their pack ships one stamped definition per handler).

  `async: false`: the module installs and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.LedgerPostFixture, as: Lp

  defp refused_line(code, handler \\ "refuse_alpha"), do: Lp.line(handler, %{"code" => code})

  defp complete_http(ctx, credential \\ :oidc) do
    unless Repo.get_by(Letflow.Identity.TenantRole, [name: "REVIEWER"], prefix: ctx.schema) do
      :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.completer.id])
    end

    Plug.Test.conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, %{})
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.assign(:auth_context, %{
      user_id: ctx.completer.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TASK_WORKER", "REVIEWER"],
      credential: credential
    })
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  describe "REQ-901 typed handler refusals" do
    for code <- ["record_version_conflict", "master_inactive"] do
      @tag :req901
      test "authorised completion returns #{code}, rolls back and audits handler_refused" do
        code = unquote(code)
        ctx = Lp.case!("req901-mapping", [Lp.line("plain"), refused_line(code)])
        before = written(ctx)
        response = complete_http(ctx)

        assert response.status == 409
        assert Jason.decode!(response.resp_body) == %{"error" => code, "line_index" => 1}
        assert_nothing_committed(ctx, before)
        assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
        assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
        assert entry.after_state["detail"] == "handler_refused"
        assert entry.after_state["line_index"] == 1
      end

      @tag :req901
      test "TASK_WORKER cannot see #{code}: same bytes as not_permitted" do
        ctx =
          Lp.case!("req901-denied", [refused_line(unquote(code))], holder_roles: ["TASK_WORKER"])

        before = written(ctx)
        denied = complete_http(ctx)
        assert denied.status == 403
        assert_nothing_committed(ctx, before)
        other = Lp.more_task!(ctx, [refused_line("not_permitted")])
        baseline = complete_http(other)
        assert baseline.status == 403
        assert denied.resp_body == baseline.resp_body

        assert Jason.decode!(denied.resp_body) == %{
                 "error" => "write_not_permitted",
                 "line_index" => 0
               }

        assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
      end
    end

    for {code, handler} <- [
          {"something_else", "refuse_alpha"},
          {"master_inactive", "refuse_plain"}
        ] do
      @tag :req901
      test "closed contract: #{handler} returning #{code} is an internal failure" do
        ctx = Lp.case!("req901-shape", [refused_line(unquote(code), unquote(handler))])
        before = written(ctx)

        assert {:error, {:line, 20, :build}, :handler_shape, _} =
                 Lp.run_lines(ctx, [refused_line(unquote(code), unquote(handler))])

        assert {:error, {:entity_write_failed, 0, :handler}} = Lp.complete(ctx)
        assert complete_http(ctx).status == 500
        assert_nothing_committed(ctx, before)
        assert Fx.audit_rows(ctx.schema, "entity_write.refused") == []
      end
    end

    @tag :req901
    test "live authority denies revoked roles, unsupported credentials and another tenant's subject" do
      ctx = Lp.case!("req901-live", [refused_line("master_inactive")])
      line = refused_line("master_inactive")

      for credential <- [nil, :api_token, :basic] do
        assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
                 Lp.run_lines(ctx, [line], credential: credential)
      end

      foreign = Fx.tenant_case!("req901-foreign")
      subject = Letflow.Support.TokenMintFixture.role_holder!(foreign.schema, ["TENANT_ADMIN"])

      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
               Lp.run_lines(ctx, [line], subject: subject)

      Lp.revoke_roles!(ctx)
      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} = Lp.run_lines(ctx, [line])
      assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
      assert {0, 0, 0, 0} = Lp.ledger_counts(foreign.schema)
    end

    @tag :req901
    test "cross-tenant completion is indistinguishable from an unknown task" do
      ctx = Lp.case!("req901-owner", [refused_line("master_inactive")])
      other = Fx.tenant_case!("req901-prober")
      user = Letflow.Support.TokenMintFixture.role_holder!(other.schema, ["TASK_WORKER"])
      probe = %{ctx | tenant: other.tenant, schema: other.schema, completer: user}
      before = written(ctx)
      cross_tenant = complete_http(probe)
      unknown = complete_http(%{probe | task: %{ctx.task | id: Ecto.UUID.generate()}})

      assert cross_tenant.status == 404
      assert unknown.status == 404
      assert cross_tenant.resp_body == unknown.resp_body
      assert_nothing_committed(ctx, before)
      assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
      assert Fx.audit_rows(ctx.schema, "entity_write.refused") == []
    end

    @tag :req901
    test "a scoped subject without posting legs cannot obtain a typed code" do
      ctx = Lp.case!("req901-scoped", [refused_line("master_inactive")])
      grants = Letflow.Support.RoleScopeGrantsFixture
      group_id = grants.group_of!(ctx.schema, "TENANT_ADMIN")
      grants.make_group_scoped_only!(ctx.schema, group_id, "TENANT_ADMIN")

      assert {:error, {:line, 20, :build}, :handler_not_permitted, _} =
               Lp.run_lines(ctx, [refused_line("master_inactive")])

      assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
    end

    @tag :req901
    test "dispatch classifies the new form as invalid_arguments" do
      ctx = Lp.service_case!("req901-dispatch", [refused_line("master_inactive")])
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{})
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "handler_invalid_arguments"
      baseline = Lp.more_service!(ctx, [refused_line("invalid_arguments")])
      assert {:ok, :error_set} = Fx.apply_http(baseline, %{})
      assert [new, old] = Fx.dlq_entries(ctx.schema)
      assert new.error_detail["code"] == old.error_detail["code"]
      assert new.error_detail["code"] == "validation_failed"
      assert {0, 0, 0, 0} = Lp.ledger_counts(ctx.schema)
    end

    @tag :req901
    test "handler contract documents the closed form and authority gate" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Letflow.Entities.HandlerContext)
      assert doc =~ "{:error, {:refused, code}}"
      assert doc =~ "record_version_conflict"
      assert doc =~ "master_inactive"
      assert doc =~ "posts_ledger"
      assert doc =~ "Letflow.Ledger.Authority"
    end
  end

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      line_audit: length(Fx.audit_rows(ctx.schema, "entity_write.process_step")),
      instance_events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)
    }
  end

  defp assert_nothing_committed(ctx, before) do
    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
  end

  describe "refusals (a public code)" do
    for {handler, code, detail} <- [
          {"denies", :write_not_permitted, "handler_not_permitted"},
          {"writes_foreign_type", :write_not_permitted, "handler_not_permitted"},
          {"invalid", :validation_failed, "handler_invalid_arguments"}
        ] do
      test "rogue handler #{handler}: #{code}, detail #{detail}, nothing committed" do
        ctx = Mw.rogue_case!("gh2590-r4b-fc-#{unquote(handler)}", unquote(handler))
        before = written(ctx)

        assert {:error, {:entity_write_refused, 0, unquote(code)}} =
                 Fx.complete(ctx, %{})

        assert_nothing_committed(ctx, before)
        assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
        assert entry.after_state["detail"] == unquote(detail)
        assert entry.after_state["line_index"] == 0
      end
    end

    test "a required argument that resolves to nothing is validation_failed" do
      ctx = Mw.case!("gh2590-r4b-fc-missingarg", :module)
      before = written(ctx)

      # the node reads its `item` from variable `label`, which this completion does not supply
      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})

      assert_nothing_committed(ctx, before)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "handler_invalid_arguments"
    end

    test "a handler that rejects the resolved value is validation_failed" do
      ctx = Mw.case!("gh2590-r4b-fc-badvalue", :module)
      before = written(ctx)

      # `item` must be a string: the handler answers :invalid_arguments for an integer
      assert {:error, {:entity_write_refused, 0, :validation_failed}} =
               Fx.complete(ctx, %{"label" => 5})

      assert_nothing_committed(ctx, before)
    end

    test "a MIXED node whose handler fails rolls the declarative record back too" do
      ctx = Mw.case!("gh2590-r4b-fc-mixed", :mixed)
      before = written(ctx)

      # the declarative line (index 0) would succeed; the handler call (index 1) fails
      assert {:error, {:entity_write_refused, 1, :validation_failed}} = Fx.complete(ctx, %{})

      assert_nothing_committed(ctx, before)
      assert Fx.records(ctx.schema, "stock_move") == []
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["line_index"] == 1
    end

    test "the refused completion is repeatable and succeeds once the arguments are supplied" do
      ctx = Mw.case!("gh2590-r4b-fc-retry", :module)

      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})
      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert [_one] = Fx.records(ctx.schema, "fxl_ledger")
    end
  end

  describe "internal failures (a contract violation or a raise)" do
    for handler <- [
          "raises",
          "throws",
          "exits",
          "bad_return",
          "out_of_range_step",
          "loose_step",
          "run_after_create",
          "drop_policy"
        ] do
      test "rogue handler #{handler}: entity_write_failed :handler, nothing committed" do
        ctx = Mw.rogue_case!("gh2590-r4b-fi-#{unquote(handler)}", unquote(handler))
        before = written(ctx)

        log =
          capture_log(fn ->
            assert {:error, {:entity_write_failed, 0, :handler}} = Fx.complete(ctx, %{})
          end)

        assert_nothing_committed(ctx, before)

        # no exception text, no secret detail in the log line (INV-4)
        refute log =~ "secret detail"

        # an internal failure is not a client refusal: no refusal audit entry
        assert Fx.audit_rows(ctx.schema, "entity_write.refused") == []
      end
    end
  end
end
