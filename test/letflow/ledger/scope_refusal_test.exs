defmodule Letflow.Ledger.ScopeRefusalTest do
  @moduledoc """
  REQ-685 criterion 4 (T-SEC-2): a principal whose `Scope.allowed_set/2` for the post atom is not
  `{:ok, :all}` is refused with `scoped_principal_unsupported` (OQ-21 default; scoped posting is
  slice L6), with the same body for an invalid command as for a valid one.

  REQ-830 (slice L6 part 1, decision 0073 OQ-13): the `gamma` registration of the fixture module
  names a scope slot (`k2`); a scoped principal posts only when EVERY leg's scope slot value is one
  of its units, for a reversal over the reversed entry's legs; anything else is `scope_denied`.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.LedgerPostFixture, as: Fx
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

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

  # ---- REQ-830 ----

  defp unit!(schema, parent \\ nil) do
    id = Ecto.UUID.generate()
    {:ok, _node} = ScopeNodePaths.write({:insert, id, parent}, schema)
    id
  end

  defp leg({unit, qty}), do: %{"k" => ["a", unit], "quantity" => qty, "unit_ref" => "u1"}

  defp gamma(cause, legs, extra \\ %{}) do
    posting = %{
      "cause" => cause,
      "document_type" => "doc",
      "document_id" => "d1",
      "legs" => Enum.map(legs, &leg/1)
    }

    Fx.post_line("post_gamma", Map.merge(posting, extra))
  end

  defp run(ctx, line), do: Fx.run_lines(ctx, [line], origin: {:task, Ecto.UUID.generate()})

  defp scope_to!(ctx, units) do
    group_id = RSG.group_of!(ctx.schema, "TENANT_ADMIN")
    RSG.raw_delete_rows!(ctx.schema, group_id, "TENANT_ADMIN")
    for u <- units, do: RSG.raw_scoped_row!(ctx.schema, group_id, "TENANT_ADMIN", u)
    :ok
  end

  defp entry_id!(schema, unit) do
    %{rows: [[id]]} =
      Repo.query!(
        ~s|SELECT e.id FROM "#{schema}".ledger_entry e JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id WHERE l.k2 = $1 LIMIT 1|,
        [unit]
      )

    Ecto.UUID.load!(id)
  end

  defp entries(schema), do: elem(Fx.ledger_counts(schema), 0)

  describe "REQ-830 scoped posting" do
    test "L6-a a grant on unit U, a receipt on U: written" do
      ctx = Fx.case!("req830-a", [])
      u = unit!(ctx.schema)
      scope_to!(ctx, [u])
      assert {:ok, _} = run(ctx, gamma("receipt", [{u, "5"}]))
      assert entries(ctx.schema) == 1
    end

    test "L6-b a grant on a parent P, a receipt on its child C: written" do
      ctx = Fx.case!("req830-b", [])
      p = unit!(ctx.schema)
      c = unit!(ctx.schema, p)
      scope_to!(ctx, [p])
      assert {:ok, _} = run(ctx, gamma("receipt", [{c, "5"}]))
      assert entries(ctx.schema) == 1
    end

    test "L6-c a receipt on a unit outside the grant is refused; same reason for a bad cause" do
      ctx = Fx.case!("req830-c", [])
      u = unit!(ctx.schema)
      h = unit!(ctx.schema)
      scope_to!(ctx, [u])
      denied = {:ledger_denied, :scope_denied}
      assert reason(run(ctx, gamma("receipt", [{h, "5"}]))) == denied
      assert reason(run(ctx, gamma("bogus", [{h, "5"}]))) == denied
      assert reason(run(ctx, gamma("receipt", [{"", "5"}]))) == denied
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end

    test "L6-d a transfer with a hidden side is refused both ways; both sides granted is written" do
      ctx = Fx.case!("req830-d", [])
      u = unit!(ctx.schema)
      u2 = unit!(ctx.schema)
      h = unit!(ctx.schema)
      assert {:ok, _} = run(ctx, gamma("receipt", [{u, "5"}]))
      scope_to!(ctx, [u, u2])
      denied = {:ledger_denied, :scope_denied}
      assert reason(run(ctx, gamma("transfer", [{u, "-3"}, {h, "3"}]))) == denied
      assert reason(run(ctx, gamma("transfer", [{h, "-3"}, {u, "3"}]))) == denied
      assert entries(ctx.schema) == 1
      assert {:ok, _} = run(ctx, gamma("transfer", [{u, "-3"}, {u2, "3"}]))
      assert entries(ctx.schema) == 2
    end

    test "L6-e a reversal follows the units of the reversed entry" do
      ctx = Fx.case!("req830-e", [])
      u = unit!(ctx.schema)
      h = unit!(ctx.schema)
      assert {:ok, _} = run(ctx, gamma("receipt", [{h, "5"}]))
      assert {:ok, _} = run(ctx, gamma("receipt", [{u, "5"}]))
      scope_to!(ctx, [u])

      reversal = fn unit ->
        Fx.post_line("post_gamma", %{
          "cause" => "reversal",
          "reverses_entry_id" => entry_id!(ctx.schema, unit),
          "reason_code" => "r1"
        })
      end

      assert reason(run(ctx, reversal.(h))) == {:ledger_denied, :scope_denied}
      assert entries(ctx.schema) == 2
      assert {:ok, _} = run(ctx, reversal.(u))
      assert entries(ctx.schema) == 3

      unknown =
        Fx.post_line("post_gamma", %{
          "cause" => "reversal",
          "reverses_entry_id" => Ecto.UUID.generate(),
          "reason_code" => "r1"
        })

      assert reason(run(ctx, unknown)) == {:ledger_denied, :scope_denied}
    end

    test "L6-f a scoped principal on a registration without a scope slot is unsupported" do
      ctx = Fx.case!("req830-f", [])
      u = unit!(ctx.schema)
      scope_to!(ctx, [u])

      assert reason(run(ctx, line())) == {:ledger_denied, :scoped_principal_unsupported}
    end

    test "L6-g a tenant-wide admin posts on any unit" do
      ctx = Fx.case!("req830-g", [])
      u = unit!(ctx.schema)
      h = unit!(ctx.schema)
      assert {:ok, _} = run(ctx, gamma("receipt", [{h, "5"}]))
      assert {:ok, _} = run(ctx, gamma("receipt", [{u, "5"}]))
      assert entries(ctx.schema) == 2
    end

    test "L6-h a grant that names no live unit is refused" do
      ctx = Fx.case!("req830-h", [])
      u = unit!(ctx.schema)
      {:ok, _} = ScopeNodePaths.write({:retire, u}, ctx.schema)
      scope_to!(ctx, [u])
      assert reason(run(ctx, gamma("receipt", [{u, "5"}]))) == {:ledger_denied, :scope_denied}
      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
    end
  end

  describe "REQ-830 cross tenant (INV-1, INV-10)" do
    setup do
      Letflow.LedgerFixture.setup_auto_mode!()
      :ok
    end

    test "L6-x a unit id of tenant A in a posting of tenant B is refused" do
      ctx = Fx.case!("req830-xb", [], committed: true)
      a = Letflow.EntityWritesFixture.committed_tenant_case!("req830-xa")
      on_exit(fn -> Letflow.EntityWritesFixture.drop_committed_tenant!(a.tenant.tenant_id) end)
      a_unit = unit!(a.schema)
      b_unit = unit!(ctx.schema)
      scope_to!(ctx, [b_unit])
      Letflow.LedgerFixture.ensure_storage!(a.schema, Fx.gamma())
      before_a = Fx.ledger_counts(a.schema)

      assert reason(run(ctx, gamma("receipt", [{a_unit, "5"}]))) ==
               {:ledger_denied, :scope_denied}

      assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
      assert Fx.ledger_counts(a.schema) == before_a
    end
  end
end
