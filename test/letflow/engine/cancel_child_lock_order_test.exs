defmodule Letflow.Engine.CancelChildLockOrderTest do
  @moduledoc """
  GH #2708 / PR-3 of the lock-order family (design `lib/letflow/design/gh2704-lock-order-family.md`
  section 4.3 and 10b; decision 0061): a direct `cancel_instance/3` of a sub-process CHILD takes the
  ancestor group (parent projection, then the parent's waiting token, `FOR KEY SHARE`) before its
  first write, because the second UPDATE of the child's projection row takes foreign-key locks on
  the parent token and the parent projection.

  MECHANISM (measured by GH #2709's probe X0, see `ExecutionErrorLockOrderTest`): the foreign-key
  check of an UPDATE of a referencing row runs only when the old row version was written by the
  SAME transaction. C0 shows that the cancel is exactly such a transaction: the INSTANCE_CANCELLED
  append bumps `last_event_seq` (UPDATE one) and the projection then goes to `:cancelled` (UPDATE
  two). The second UPDATE queues `KEY SHARE` on the parent token and the parent projection in an
  order fixed per tenant schema; where the token comes first, a parent cancel (`P_p` then `T_p`)
  and the child cancel (`T_p` then `P_p`) form an AB-BA.

    * C0: the precondition probe (the cancel UPDATEs the child's projection twice; the second
      UPDATE of one transaction refuses NOWAIT locks on both parent rows);
    * C1: statement order (the group precedes the event insert and every projection UPDATE; a
      top-level cancel takes no group lock);
    * C2: forced AB-BA against `cancel_instance(parent)` in a schema whose FK order is token first
      (the test re-creates the two foreign keys in that order and asserts it): RED without the
      group lock (40P01 through the telemetry handler);
    * C3: the same overlap in a schema whose FK order is projection first (cycle unreachable);
    * C4: fixture sanity and existing semantics (a cancelled child leaves the parent token
      `:waiting` and the parent `:active`; the parent cancel does not go child-ward).

  Forced-overlap method: `Letflow.LockOrderHelpers`. Sandbox `:auto` mode, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)
    :ok
  end

  defp tenant(_context) do
    base = Fx.committed_tenant_case!("gh2708-cc")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  defp token_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "tokens")
    %{base: base}
  end

  defp projection_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "instance_projections")
    %{base: base}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START -> h1 (HUMAN) -> END
  defp plain_child do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h1"), edge("e2", "h1", "end")]
    }
  end

  defp parent_graph(child_def) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
    }
  end

  defp activate!(base, graph), do: Fx.legacy_activate!(base.schema, base.user, graph, [])

  defp start_instance!(base, definition) do
    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("cc-start")
        },
        prefix: base.schema
      )

    id
  end

  defp pair!(base) do
    c_def = activate!(base, plain_child())
    parent = activate!(base, parent_graph(c_def))
    parent_id = start_instance!(base, parent)

    child_id =
      Repo.one!(
        from(p in InstanceProjection,
          where: p.parent_instance_id == ^parent_id and p.definition_id == ^c_def.id,
          select: p.instance_id
        ),
        prefix: base.schema
      )

    {parent_id, child_id}
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("cc-cancel")},
        prefix: base.schema
      )
    end
  end

  defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&H.normalize/1)

  # ---- C0 ---------------------------------------------------------------------------------------

  describe "C0: precondition probe (does the cancel UPDATE the child's projection twice?)" do
    setup :tenant

    test "the cancel updates the child's projection row twice in one transaction", %{base: base} do
      {parent_id, child_id} = pair!(base)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, child_id))
      assert {:ok, _} = result

      updates =
        Enum.filter(queries, fn q ->
          q.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/ and child_id in params(q)
        end)

      # UPDATE one: the INSTANCE_CANCELLED append bumps last_event_seq. UPDATE two: the status
      # goes to :cancelled. The second one has an old row version written by this transaction,
      # which is what makes Postgres run the two parent FK checks (X0 of GH #2709).
      assert length(updates) >= 2, inspect(Enum.map(queries, & &1.query), limit: :infinity)

      # and in the committed end state the parent rows were really untouched by the cancel
      assert Fx.projection!(base.schema, parent_id).status == :active
    end
  end

  # ---- C1 ---------------------------------------------------------------------------------------

  describe "C1: statement order of a child cancel" do
    setup :tenant

    test "the parent projection and the waiting token are locked before any write", %{base: base} do
      {parent_id, child_id} = pair!(base)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, child_id))
      assert {:ok, _} = result

      parent_projection =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR KEY SHARE" and
            parent_id in params(q)
        end)

      waiting_token =
        Enum.find_index(queries, fn q ->
          q.query =~ "tokens" and q.query =~ "FOR KEY SHARE" and q.query =~ "waiting_child"
        end)

      event_insert = Enum.find_index(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."events"/))

      first_projection_update =
        Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/))

      audit_row = Enum.find_index(queries, &(&1.query =~ "audit_chain_locks"))

      positions = [parent_projection, waiting_token, event_insert, first_projection_update]

      assert Enum.all?(positions, &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert parent_projection < waiting_token
      assert waiting_token < event_insert
      assert waiting_token < first_projection_update

      # the group is taken after the child's own projection lock (L3) and before the audit row (L7)
      own_projection =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and
            child_id in params(q)
        end)

      assert is_integer(own_projection) and own_projection < parent_projection
      assert is_integer(audit_row) and waiting_token < audit_row

      # the mode is KEY SHARE (a cancel never completes the child): no FOR UPDATE on the parent
      refute Enum.any?(queries, fn q ->
               q.query =~ "FOR UPDATE" and parent_id in params(q)
             end)
    end

    test "a top-level cancel takes no group lock", %{base: base} do
      top_id = start_instance!(base, activate!(base, plain_child()))

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, top_id))
      assert {:ok, _} = result
      refute Enum.any?(queries, &(&1.query =~ "FOR KEY SHARE"))
    end

    test "an ineligible cancel (already cancelled child) takes no group lock", %{base: base} do
      {_parent_id, child_id} = pair!(base)
      assert {:ok, _} = cancel_fn(base, child_id).()

      {second, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, child_id))
      assert {:error, {:instance_already_terminal, :cancelled}} = second
      refute Enum.any?(queries, &(&1.query =~ "FOR KEY SHARE"))
    end
  end

  # ---- C2 / C3: forced AB-BA against cancel(parent) ---------------------------------------------

  # `Z` holds the parent projection, `cancel_instance(parent)` parks first on it,
  # `cancel_instance(child)` arrives second, `Z` is released.
  defp overlap!(base) do
    {parent_id, child_id} = pair!(base)

    overlap =
      H.forced_overlap(
        base.schema,
        {:projection, parent_id},
        cancel_fn(base, parent_id),
        cancel_fn(base, child_id)
      )

    assert {:ok, _} = overlap.first
    assert {:ok, _} = overlap.second, inspect(overlap.second)

    assert Fx.projection!(base.schema, parent_id).status == :cancelled
    assert Fx.projection!(base.schema, child_id).status == :cancelled
    assert [_one] = Fx.instance_events(base.schema, child_id, "INSTANCE_CANCELLED")
    assert [_one] = Fx.instance_events(base.schema, parent_id, "INSTANCE_CANCELLED")

    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)})"

    overlap
  end

  describe "C2: FK order token first (cancel(parent) P_p then T_p inverts the child's FK locks)" do
    setup :token_first

    test "cancel_instance(child) against cancel_instance(parent)", %{base: base} do
      overlap!(base)
    end
  end

  describe "C3: FK order projection first (the cycle is unreachable, green before and after)" do
    setup :projection_first

    test "cancel_instance(child) against cancel_instance(parent)", %{base: base} do
      overlap!(base)
    end
  end

  # ---- C4 ---------------------------------------------------------------------------------------

  describe "C4: existing semantics, documented" do
    setup :tenant

    test "a cancelled child leaves the parent active with its token waiting", %{base: base} do
      {parent_id, child_id} = pair!(base)
      assert {:ok, _} = cancel_fn(base, child_id).()

      assert Fx.projection!(base.schema, child_id).status == :cancelled
      assert Fx.projection!(base.schema, parent_id).status == :active
      assert [] = Fx.instance_events(base.schema, parent_id, "SUB_PROCESS_COMPLETED")

      waiting =
        Repo.all(
          from(t in Letflow.Engine.TokenRecord,
            where: t.waiting_child_instance_id == ^child_id and t.status == :waiting
          ),
          prefix: base.schema
        )

      assert [_one] = waiting
    end

    test "cancelling the parent does not go child-ward", %{base: base} do
      {parent_id, child_id} = pair!(base)
      assert {:ok, _} = cancel_fn(base, parent_id).()

      assert Fx.projection!(base.schema, parent_id).status == :cancelled
      assert Fx.projection!(base.schema, child_id).status == :active
    end
  end
end
