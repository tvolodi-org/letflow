defmodule Letflow.Documents.HoldLockOrderTest do
  @moduledoc """
  REQ-536 / GH #3106, decision 0063 S5 and 0061 rule 5: forced-overlap tests for the hold path,
  which takes two row classes -- the `documents` row first, the audit chain row second
  (`Letflow.Documents.Hold`). Test A7f; design state/tasks/T-0393/design.md section 6, IDs L1..L4.

    * L1: two `set/5` calls on one document, barrier on the document row: exactly one wins;
    * L2: `release/5` against `set/5` of one document, barrier on the audit chain row;
    * L3: `set/5` of two documents, barrier on the audit chain row;
    * L4: a retention policy change against `set/5`, barrier on the audit chain row.

  Method: `Letflow.LockOrderHelpers` (sandbox `:auto` mode, hence `async: false`). Each case
  asserts that no deadlock or lock timeout reached the Repo telemetry handler and keeps the
  2 s `lock_timeout` margin of the neighbouring tests. Only the unforced interleaving beyond
  these barriers cannot be forced.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.Hold
  alias Letflow.Documents.Retention
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  @actor "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @attrs %{reason_code: "legal_matter", reason_note: "freeze"}
  @release %{reason_code: "case_closed", reason_note: "done"}

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("req536-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    schema = base.schema
    tenant_id = base.tenant.tenant_id
    key = insert_type!(schema, tenant_id)
    %{schema: schema, tenant_id: tenant_id, key: key}
  end

  defp doc(ctx), do: insert_document!(ctx.schema, ctx.tenant_id, ctx.key)

  defp actions(ctx, id) do
    Repo.query!(
      "SELECT action FROM #{table(ctx.schema, "audit_entries")} WHERE resource_type = 'document' AND resource_id = $1 ORDER BY timestamp, id",
      [id]
    ).rows
    |> Enum.map(&hd/1)
  end

  # The audit chain row of a tenant exists after its first audit entry: write one.
  defp seed_chain!(ctx) do
    z = doc(ctx)
    {:ok, _} = Hold.set(ctx.schema, z, :all, @attrs, @actor)
  end

  defp assert_margin(timing), do: assert(H.margin_ms(timing) >= 500)

  test "L1: two sets of one document serialize on the document row", ctx do
    x = doc(ctx)

    out =
      H.forced_overlap(
        ctx.schema,
        {:document, x},
        fn -> Hold.set(ctx.schema, x, :all, @attrs, @actor) end,
        fn -> Hold.set(ctx.schema, x, :all, @attrs, @actor) end
      )

    assert {:ok, %{on_hold: true}} = out.first
    assert {:error, :conflict} = out.second
    assert actions(ctx, x) == ["document.hold_set"]
    assert_margin(out.timing)
  end

  test "L2: release against set of one document, barrier on the audit chain", ctx do
    x = doc(ctx)
    {:ok, _} = Hold.set(ctx.schema, x, :all, @attrs, @actor)

    out =
      H.forced_overlap(
        ctx.schema,
        :audit_chain,
        fn -> Hold.release(ctx.schema, x, :all, @release, @actor) end,
        fn -> Hold.set(ctx.schema, x, :all, @attrs, @actor) end
      )

    # worker 2 queues on worker 1's document row, then both reach the audit row in turn
    assert {:ok, %{on_hold: false}} = out.first
    assert {:ok, %{on_hold: true}} = out.second
    assert actions(ctx, x) == ["document.hold_set", "document.hold_cleared", "document.hold_set"]
    assert_margin(out.timing)
  end

  test "L3: sets of two documents, barrier on the audit chain", ctx do
    x = doc(ctx)
    y = doc(ctx)
    seed_chain!(ctx)

    out =
      H.forced_overlap(
        ctx.schema,
        :audit_chain,
        fn -> Hold.set(ctx.schema, x, :all, @attrs, @actor) end,
        fn -> Hold.set(ctx.schema, y, :all, @attrs, @actor) end
      )

    assert {:ok, _} = out.first
    assert {:ok, _} = out.second
    assert actions(ctx, x) == ["document.hold_set"]
    assert actions(ctx, y) == ["document.hold_set"]
    assert_margin(out.timing)
  end

  test "L4: a policy change against a set, barrier on the audit chain", ctx do
    x = doc(ctx)
    seed_chain!(ctx)
    policy = %{retention_period_days: 30, retention_from: "issued", retention_action: "purge"}

    out =
      H.forced_overlap(
        ctx.schema,
        :audit_chain,
        fn -> Retention.change_policy(ctx.schema, ctx.key, policy, @actor, "policy_review") end,
        fn -> Hold.set(ctx.schema, x, :all, @attrs, @actor) end
      )

    assert {:ok, %{changed: true}} = out.first
    assert {:ok, %{on_hold: true}} = out.second
    assert_margin(out.timing)
  end
end
