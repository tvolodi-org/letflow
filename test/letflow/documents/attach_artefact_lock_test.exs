defmodule Letflow.Documents.AttachArtefactLockTest do
  @moduledoc """
  REQ-623 / GH #3474 criteria 1 and 4 (decision 0075 R1, R2): the render runs with no lock and no
  transaction, and the second transaction waits on the version row. Design tests L1, L2, T2, R2.

  Method: `Letflow.LockOrderHelpers` (sandbox `:auto` mode, hence `async: false`). A renderer
  cannot assert (a raise is rescued as `:render_failed`), so it sends what it saw to the test.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Documents
  alias Letflow.Documents.TestRenderer
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Test.SandboxAutoMode

  @actor "99999999-9999-4999-8999-999999999999"
  @tables ~w(document_sequences documents document_versions audit_entries audit_chain_locks)

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("req623-lock")
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
          declared_fields: %{"_free" => ["a"]},
          sensitivity: %{"a" => :public},
          template_ref: TestRenderer.ref()
        },
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    TestRenderer.install!()

    {:ok, %{document: d}} =
      Documents.create_draft(
        schema,
        %{type_key: "purchase_request", issuing_org_unit_id: unit, content: %{"a" => 1}},
        @actor
      )

    {:ok, _} = Documents.issue(schema, %{document_id: d.id, actor_id: @actor})
    %{schema: schema, doc: d.id}
  end

  defp attach(ctx),
    do:
      Documents.attach_artefact(ctx.schema, %{
        document_id: ctx.doc,
        version_no: 1,
        actor_id: @actor
      })

  # Relations of the tenant's schema on which some backend holds a granted lock.
  defp held_locks(schema) do
    Repo.query!(
      """
      SELECT DISTINCT c.relname FROM pg_locks l
        JOIN pg_class c ON c.oid = l.relation JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = $1 AND l.granted AND c.relname = ANY($2)
       ORDER BY 1
      """,
      [schema, @tables]
    ).rows
    |> List.flatten()
  end

  test "L1: while the renderer runs no table of the numbering path is locked and no transaction is open",
       ctx do
    test_pid = self()

    TestRenderer.set_fun(fn _, _, _ ->
      send(test_pid, {:seen, held_locks(ctx.schema), Repo.in_transaction?()})
      {:ok, "%PDF", "v"}
    end)

    assert {:ok, %{version: %{artefact_hash: hash}}} = attach(ctx)
    assert is_binary(hash)
    assert_received {:seen, [], false}
  end

  test "L2: the lock probe sees a held row lock (L1 is not vacuous)", ctx do
    Repo.checkout(fn ->
      Repo.query!("BEGIN")

      Repo.query!(~s[SELECT 1 FROM "#{ctx.schema}"."document_sequences" FOR UPDATE])

      locks = held_locks(ctx.schema)
      Repo.query!("ROLLBACK")
      assert "document_sequences" in locks
    end)
  end

  test "T2: the second transaction waits for the version row and then attaches", ctx do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            ~s[SELECT 1 FROM "#{ctx.schema}"."document_versions" WHERE document_id = $1 FOR UPDATE],
            [Ecto.UUID.dump!(ctx.doc)]
          )

          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_pid, {:held_backend, backend})

          receive do
            :release -> :ok
          after
            H.await_ms() -> :ok
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive {:held_backend, barrier}, 10_000

    {task, pid} = H.start_worker(fn -> attach(ctx) end)
    H.wait_for_blocked([pid], 1)
    H.await_blocked_by(pid, [barrier])
    send(holder.pid, :release)
    Task.await(holder, H.await_ms())

    assert {{:ok, %{version: %{artefact_hash: hash}}}, _} = Task.await(task, H.await_ms())
    assert is_binary(hash)
    refute_receive {:deadlock_detected, _error}, 0
  end

  test "R2: two concurrent attaches both succeed and write one artefact and one audit entry",
       ctx do
    test_pid = self()

    TestRenderer.set_fun(fn _, _, _ ->
      send(test_pid, {:in_render, self()})

      receive do
        :go -> {:ok, "%PDF", "v"}
      after
        10_000 -> {:error, :timeout}
      end
    end)

    {t1, _} = H.start_worker(fn -> attach(ctx) end)
    {t2, _} = H.start_worker(fn -> attach(ctx) end)
    assert_receive {:in_render, p1}, 10_000
    assert_receive {:in_render, p2}, 10_000
    send(p1, :go)
    send(p2, :go)

    assert {{:ok, %{version: %{artefact_hash: h1}}}, _} = Task.await(t1, H.await_ms())
    assert {{:ok, %{version: %{artefact_hash: h2}}}, _} = Task.await(t2, H.await_ms())
    assert h1 == h2

    assert Repo.query!(
             ~s[SELECT count(*)::int FROM "#{ctx.schema}"."audit_entries" WHERE action = 'document.artefact_attached']
           ).rows == [[1]]

    assert Repo.query!(~s[SELECT count(*)::int FROM "#{ctx.schema}"."repository_artifacts"]).rows ==
             [[1]]
  end
end
