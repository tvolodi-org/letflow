defmodule Letflow.Routers.TenantScopeEnforcementRefusalKindsTest do
  @moduledoc """
  GH #2890 (REQ-519 2f-b TS-1): the refusal kinds of `Letflow.ScopeEnforcement.flip/4` are a
  closed set (`ScopeEnforcement.refusal_kinds/0`), and every kind has its own router answer in
  `Letflow.Routers.TenantScopeEnforcement.flip_response/2`. The catch-all of that function (an
  unrecognised tag is a detail-free 500, INV-8, pinned by `OnFlipGuardsTest`) is a fallback, not
  a mapping, so this test checks that no kind falls through to it:

    * the table of expected HTTP statuses has exactly the kinds of `refusal_kinds/0`, so a new
      kind added to the list without a row here fails;
    * every kind answers its expected status, and a server-fault kind logs its own reason tag
      (a kind without its own clause logs `reason=unknown` and fails);
    * the sample of each kind is built by a `case` without a catch-all, so a kind added to the
      list without a sample fails too.

  `async: false`: the `on_precondition_failed` sample is a real `OnGate` report of a fixture tenant.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Letflow.Routers.TenantScopeEnforcement
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.Support.OnGateFixture, as: F

  # kind => HTTP status the router answers (422 invalid input, 409 refusal, 500 server fault).
  @expected_status %{
    invalid_mode: 422,
    reason_required: 422,
    invalid_reason: 422,
    shadow_required: 409,
    precondition_failed: 409,
    on_precondition_failed: 409,
    tenant_not_found: 500,
    tenant_prefix_mismatch: 500,
    audit_failed: 500,
    transaction_failed: 500
  }

  # The kinds the router answers as a server fault: each logs its own reason tag (SEC C-5).
  @server_fault_kinds [
    :tenant_not_found,
    :tenant_prefix_mismatch,
    :audit_failed,
    :transaction_failed
  ]
  @fault_line "scope_enforcement_flip_failed"

  setup do
    fx = F.shadow_tenant!("refusal-kinds")
    {report, _failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
    %{report: report}
  end

  test "the expected-status table has exactly the kinds of refusal_kinds/0" do
    assert Enum.sort(Map.keys(@expected_status)) == Enum.sort(ScopeEnforcement.refusal_kinds())
  end

  test "every refusal kind reaches its own router clause, never the unknown fallback", ctx do
    for kind <- ScopeEnforcement.refusal_kinds() do
      {conn, log} =
        with_log(fn ->
          TenantScopeEnforcement.flip_response({:error, sample(kind, ctx.report)}, fresh_conn())
        end)

      assert conn.status == @expected_status[kind],
             "refusal kind #{inspect(kind)} answered #{conn.status}, expected " <>
               "#{@expected_status[kind]}"

      flip_failed = Enum.filter(String.split(log, "\n"), &String.contains?(&1, @fault_line))

      if kind in @server_fault_kinds do
        # The fallback logs `reason=unknown`; a kind without its own clause shows up there.
        assert [line] = flip_failed
        assert line =~ "reason=#{kind} ", "refusal kind #{inspect(kind)} logged: #{line}"
      else
        assert flip_failed == [],
               "refusal kind #{inspect(kind)} is a refusal, not a server fault: #{inspect(flip_failed)}"
      end
    end
  end

  # One representative error term per kind, the shape `flip/4` returns. No catch-all: a new kind
  # without a clause here is a CaseClauseError.
  defp sample(:invalid_mode, _report), do: :invalid_mode
  defp sample(:reason_required, _report), do: :reason_required
  defp sample(:invalid_reason, _report), do: :invalid_reason
  defp sample(:tenant_not_found, _report), do: :tenant_not_found
  defp sample(:tenant_prefix_mismatch, _report), do: :tenant_prefix_mismatch
  defp sample(:shadow_required, _report), do: :shadow_required

  defp sample(:precondition_failed, _report) do
    {:precondition_failed, [:bindings_without_row],
     %{bindings_without_row: 1, org_consistency: :ok, tokens_exceeding_owner: 0}}
  end

  defp sample(:on_precondition_failed, report),
    do: {:on_precondition_failed, [:zero_tenant_wide_admins], report}

  defp sample(:audit_failed, _report), do: {:audit_failed, :boom}
  defp sample(:transaction_failed, _report), do: {:transaction_failed, %RuntimeError{}}

  defp fresh_conn, do: conn(:put, "/tenant/scope-enforcement")
end
