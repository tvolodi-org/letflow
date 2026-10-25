defmodule Letflow.Documents.IssueLockOrderTest do
  @moduledoc """
  REQ-543 / GH #3163 criterion 1, decision 0056 D2 and T11: forced-overlap tests of
  `Letflow.Documents.issue/2` on the `document_sequences` row. Design: state/tasks/T-0635/design.md.

    * N4: a holder keeps the sequence row; two workers issue two documents of one scope; both
      block, the holder is released, the numbers are exactly n+1 and n+2;
    * B1: the holder keeps the row past the 2 s lock timeout; `issue/2` returns `{:error, :busy}`,
      nothing is allocated and the next issue gets the next consecutive number.

  Method: `Letflow.LockOrderHelpers` (sandbox `:auto` mode, hence `async: false`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Documents
  alias Letflow.Documents.Canonical
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Test.SandboxAutoMode

  @actor "99999999-9999-4999-8999-999999999999"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("req543-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    schema = base.schema

    {:ok, _} =
      Documents.register_type(
        schema,
        %{
          key: "purchase_request",
          owner_module: "procurement",
          numbering_scope: :none,
          number_prefix: "PR",
          number_pad: 4,
          legal_entity_required: false,
          declared_fields: %{}
        },
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    %{schema: schema, unit: unit}
  end

  defp draft!(ctx) do
    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "purchase_request", issuing_org_unit_id: ctx.unit, content: %{"a" => 1}},
        @actor
      )

    d.id
  end

  defp issue(ctx, id), do: Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})

  defp counter(ctx) do
    Repo.query!(
      ~s[SELECT counter FROM "#{ctx.schema}"."document_sequences" WHERE type_key = 'purchase_request']
    ).rows
    |> List.flatten()
  end

  # Holds the one sequence row of the scope FOR UPDATE on a third connection, like `H.hold_row/2`.
  defp hold_sequence(ctx) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.checkout(fn ->
          Repo.query!("BEGIN")

          %{rows: rows} =
            Repo.query!(
              ~s[SELECT pg_backend_pid() FROM "#{ctx.schema}"."document_sequences" WHERE type_key = 'purchase_request' AND legal_entity_key = $1 FOR UPDATE],
              [Canonical.legal_entity_sentinel()]
            )

          [[backend]] = rows
          send(test_pid, {:held_backend, backend})

          receive do
            :release -> Repo.query!("ROLLBACK")
          after
            10_000 -> Repo.query!("ROLLBACK")
          end
        end)
      end)

    assert_receive {:held_backend, backend}, 10_000
    {holder, backend}
  end

  defp release(holder) do
    send(holder.pid, :release)
    Task.await(holder, H.await_ms())
  end

  # The sequence row exists after the first issue; the barrier then holds it.
  defp seed!(ctx), do: {:ok, %{document: %{number: 1}}} = issue(ctx, draft!(ctx))

  test "N4: two concurrent issues in one scope give consecutive numbers", ctx do
    seed!(ctx)
    a = draft!(ctx)
    b = draft!(ctx)
    {holder, barrier} = hold_sequence(ctx)

    {t1, pid1} = H.start_worker(fn -> issue(ctx, a) end)
    H.wait_for_blocked([pid1], 1)
    H.await_blocked_by(pid1, [barrier])
    {t2, pid2} = H.start_worker(fn -> issue(ctx, b) end)
    H.wait_for_blocked([pid1, pid2], 2)
    release(holder)

    assert {{:ok, %{document: %{number: n1}}}, _} = Task.await(t1, H.await_ms())
    assert {{:ok, %{document: %{number: n2}}}, _} = Task.await(t2, H.await_ms())
    assert Enum.sort([n1, n2]) == [2, 3]
    assert counter(ctx) == [3]
    refute_receive {:deadlock_detected, _error}, 0
  end

  test "B1: past the lock timeout issue/2 returns :busy and allocates nothing", ctx do
    seed!(ctx)
    a = draft!(ctx)
    {holder, _barrier} = hold_sequence(ctx)

    result = try_issue(ctx, a)
    release(holder)

    assert {:error, :busy} = result
    assert counter(ctx) == [1]

    assert Repo.query!(
             ~s[SELECT status FROM "#{ctx.schema}"."document_versions" WHERE document_id = $1],
             [Ecto.UUID.dump!(a)]
           ).rows == [["draft"]]

    assert {:ok, %{document: %{number: 2}}} = issue(ctx, a)
  end

  defp try_issue(ctx, id) do
    {task, _pid} = H.start_worker(fn -> issue(ctx, id) end)
    {result, _at} = Task.await(task, H.await_ms())
    result
  end

  test "B1b: both SET LOCAL timeouts come before the first lock in issue/2" do
    src = File.read!("lib/letflow/documents.ex")
    [_, rest] = String.split(src, "  def issue(prefix", parts: 2)
    {lock_t, _} = :binary.match(rest, "SET LOCAL lock_timeout")
    {stmt_t, _} = :binary.match(rest, "SET LOCAL statement_timeout")
    {first_lock, _} = :binary.match(rest, "lock_document!(prefix, document_id)")
    assert lock_t < first_lock and stmt_t < first_lock
  end
end
