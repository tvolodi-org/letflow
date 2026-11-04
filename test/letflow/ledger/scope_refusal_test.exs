defmodule Letflow.Ledger.ScopeRefusalTest do
  @moduledoc """
  REQ-685 criterion 4 (T-SEC-2): a principal whose `Scope.allowed_set/2` for the post atom is not
  `{:ok, :all}` is refused with `scoped_principal_unsupported` (OQ-21 default; scoped posting is
  slice L6), with the same body for an invalid command as for a valid one.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.LedgerPostFixture, as: Fx
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  defp line(extra \\ %{}),
    do: Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5", extra))

  defp reason({:error, {:line, _, :ledger_post}, reason, _changes}), do: reason

  test "T-SEC-2a a grant of TENANT_ADMIN scoped to a node (on the group) is refused" do
    ctx = Fx.case!("req685-sc2a", [line()])
    group_id = RSG.group_of!(ctx.schema, "TENANT_ADMIN")
    RSG.make_group_scoped_only!(ctx.schema, group_id, "TENANT_ADMIN")

    valid = reason(Fx.run_lines(ctx, [line()]))
    assert valid == {:ledger_denied, :scoped_principal_unsupported}
    assert reason(Fx.run_lines(ctx, [line(%{"cause" => "bogus"})])) == valid
    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-2b a grant scoped to a node on the user is refused" do
    ctx = Fx.case!("req685-sc2b", [line()])
    group_id = RSG.group_of!(ctx.schema, "TENANT_ADMIN")
    RSG.raw_delete_rows!(ctx.schema, group_id, "TENANT_ADMIN")
    RSG.raw_user_row!(ctx.schema, ctx.completer.id, "TENANT_ADMIN", RSG.node!(ctx.schema))

    valid = reason(Fx.run_lines(ctx, [line()]))
    assert valid == {:ledger_denied, :scoped_principal_unsupported}
    assert reason(Fx.run_lines(ctx, [line(%{"legs" => "nope"})])) == valid
  end
end
