defmodule Letflow.Engine.NotifyStepRunnerTest do
  @moduledoc """
  T-2810: the engine RUNS a notification step (a SERVICE_TASK with a `notify` attribute), through
  the real loop: `Letflow.Engine.create/2` arms the row and parks the instance,
  `Letflow.Engine.NotifyStepRunner` sends outside every transaction (the mail trap is the
  notifier double), and the instance continues by the definition's edges.

  | ID | What it proves |
  |---|---|
  | NS1 | a throwaway definition with a mail step: the instance waits on the node, the runner sends, the instance COMPLETES, the trap holds the mail |
  | NS2 | the file channel writes the file and the instance completes; no mail is sent |
  | NS3 | no recipient value: ERROR + EXECUTION_ERROR + a `notify_step` DLQ entry, nothing sent |
  | NS4 | a recipient domain off the allow-list: refused at dispatch, ERROR + DLQ, nothing sent |
  | NS5 | a send failure: ERROR + DLQ; the DLQ retry sends once and resumes the instance |
  | NS6 | a worker that died AFTER the send: the replay finds the delivery and sends nothing a second time |
  | NS7 | an edited definition (step removed; a second step added) runs as edited |
  | NS8 | the tenant's send cap: over the cap nothing is sent, ERROR + DLQ |
  | NS9 | no address, name or body in the row, the DLQ entry, or the EXECUTION_ERROR event |
  | NS10 | the shipped platform.register_tenant v1 notify node is read as a notify route |

  `async: false`: committed tenant writes, application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Dlq.Entry
  alias Letflow.Engine
  alias Letflow.Engine.NotifyStepRunner
  alias Letflow.Engine.ServiceTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Instances.StepRetry
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.Notifications.File
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.TenantFixture

  @notifier Letflow.LoginDiscovery.Notifier
  @address "someone.private@example.com"

  setup do
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    fx = PCF.tenant!("t2810-notify")
    TenantFixture.open_outbound_channel!(fx.schema_name, "email", ["example.com"])
    TenantFixture.open_outbound_channel!(fx.schema_name, "file")
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    {:ok, fx: fx}
  end

  defp mail_declaration do
    %{
      "template_key" => "tenant_registered",
      "recipient" => %{"var" => "admin_email"},
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"const" => "acme"},
        "registered_by" => %{"const" => "Letflow"}
      }
    }
  end

  defp file_declaration do
    %{
      "channel" => "file",
      "template_key" => "tenant_registered",
      "file_name" => "registration-notice",
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"const" => "acme"},
        "registered_by" => %{"const" => "Letflow"}
      }
    }
  end

  defp node(id, declaration) do
    %{"id" => id, "node_type" => "SERVICE_TASK", "attributes" => %{"notify" => declaration}}
  end

  # START -> notify steps in order -> END.
  defp graph(steps) do
    ids = Enum.map(steps, & &1["id"])
    chain = ["start"] ++ ids ++ ["end"]

    edges =
      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.map(fn {[a, b], i} -> %{"id" => "e#{i}", "source" => a, "target" => b} end)

    %{
      "nodes" =>
        [%{"id" => "start", "node_type" => "START"}] ++
          steps ++ [%{"id" => "end", "node_type" => "END"}],
      "edges" => edges
    }
  end

  defp activate!(fx, graph) do
    name = "t2810-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, definition} =
             Definitions.create(
               %{name: name, version: "1.0.0", graph: graph, created_by: Ecto.UUID.generate()},
               prefix: fx.schema_name
             )

    assert {:ok, _count} =
             Definitions.register_variable_schemas(
               definition.id,
               [
                 %{variable_key: "admin_email", json_schema: %{"type" => "string"}},
                 %{variable_key: "tenant_name", json_schema: %{"type" => "string"}}
               ],
               prefix: fx.schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: fx.schema_name)

    activated
  end

  defp start!(fx, definition, variables \\ %{}) do
    vars = Map.merge(%{"admin_email" => @address, "tenant_name" => "Acme"}, variables)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: vars,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "t2810-#{Ecto.UUID.generate()}"
               },
               prefix: fx.schema_name
             )

    result.instance_id
  end

  defp status(fx, id),
    do: Repo.get_by!(InstanceProjection, [instance_id: id], prefix: fx.schema_name).status

  defp rows(fx, id),
    do: Repo.all(from(d in StepDispatch, where: d.instance_id == ^id), prefix: fx.schema_name)

  defp run(fx), do: NotifyStepRunner.run_due(fx.schema_name)

  defp dlq(fx, id),
    do: Repo.all(from(e in Entry, where: e.instance_id == ^id), prefix: fx.schema_name)

  defp mails do
    receive do
      {:deliver_message, m} -> [m | mails()]
    after
      200 -> []
    end
  end

  test "NS1 the mail step runs in the loop: waits, sends, completes", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    id = start!(fx, definition)

    # Entered, parked, nothing sent yet.
    assert status(fx, id) == :active
    assert [%StepDispatch{status: :pending, function_name: "notify.send"}] = rows(fx, id)
    refute_receive {:deliver_message, _}, 100

    assert %{claimed: 1} = run(fx)
    assert status(fx, id) == :completed
    assert [m] = mails()
    assert m.to == @address
    assert [%StepDispatch{status: :advanced}] = rows(fx, id)

    # A second cycle moves nothing and sends nothing.
    run(fx)
    assert mails() == []
  end

  test "NS2 the file channel writes the file and completes", %{fx: fx} do
    definition = activate!(fx, graph([node("note", file_declaration())]))
    id = start!(fx, definition)
    run(fx)

    assert status(fx, id) == :completed
    assert [file] = Repo.all(File, prefix: fx.schema_name)
    assert file.bytes =~ "Acme"
    assert mails() == []
  end

  test "NS3 no recipient value: ERROR + notify_step DLQ entry, nothing sent", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    id = start!(fx, definition, %{"admin_email" => 42})
    run(fx)

    assert status(fx, id) == :error
    assert [%StepDispatch{status: :given_up, last_failure_kind: kind}] = rows(fx, id)
    assert kind == "notify_recipient_missing"
    assert [%Entry{entry_type: "notify_step"}] = dlq(fx, id)
    assert mails() == []
  end

  test "NS4 a destination off the allow-list is refused at dispatch", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    id = start!(fx, definition, %{"admin_email" => "x@elsewhere.example"})
    run(fx)

    assert status(fx, id) == :error
    assert [%StepDispatch{last_failure_kind: "notify_destination_not_allowed"}] = rows(fx, id)
    assert mails() == []
  end

  test "NS5 a send failure is ERROR + DLQ; the retry sends once and resumes", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    Double.set_behaviour(:error)
    id = start!(fx, definition)
    run(fx)

    assert status(fx, id) == :error
    assert [%Entry{entry_type: "notify_step"} = entry] = dlq(fx, id)

    Double.set_behaviour(:ok)
    assert {:ok, %{status: "sent"}} = StepRetry.retry_entry(entry, prefix: fx.schema_name)
    assert status(fx, id) == :completed

    # A second retry changes nothing and sends nothing.
    sent_before = length(mails())
    assert {:ok, %{status: "already_done"}} = StepRetry.retry_entry(entry, prefix: fx.schema_name)
    assert sent_before >= 1
    assert mails() == []
  end

  test "NS6 a worker that died after the send: the replay sends nothing again", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    id = start!(fx, definition)

    # The first worker sent (the delivery row exists) and died holding the row.
    assert {:ok, "sent", nil} =
             Dispatcher.run(
               mail_declaration(),
               %{"admin_email" => @address, "tenant_name" => "Acme"},
               prefix: fx.schema_name,
               trigger_ref: id,
               labels: %{}
             )

    assert [_] = mails()
    [row] = rows(fx, id)
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^row.id),
      [set: [status: :running, attempt_index: 1, next_attempt_at: past]],
      prefix: fx.schema_name
    )

    run(fx)
    assert mails() == []
    assert status(fx, id) == :completed
    assert [%StepDispatch{status: :advanced, attempt_index: 2}] = rows(fx, id)
  end

  test "NS7 an edited definition runs as edited", %{fx: fx} do
    removed = activate!(fx, graph([]))
    id = start!(fx, removed)
    # No notification step at all: the instance runs straight through.
    assert status(fx, id) == :completed
    assert rows(fx, id) == []
    assert mails() == []

    two =
      activate!(fx, graph([node("note", file_declaration()), node("notify", mail_declaration())]))

    id2 = start!(fx, two)
    run(fx)
    assert status(fx, id2) in [:active, :completed]
    run(fx)
    assert status(fx, id2) == :completed
    assert [_] = Repo.all(File, prefix: fx.schema_name)
    assert [_] = mails()
    assert Enum.map(rows(fx, id2), & &1.node_id) |> Enum.sort() == ["note", "notify"]
  end

  test "NS8 over the tenant's cap nothing is sent: ERROR + DLQ", %{fx: fx} do
    {:ok, _} =
      Repo.query("UPDATE tenants SET settings = $1::jsonb WHERE id = $2", [
        %{"notifications.outbound_cap_per_hour" => 1},
        Ecto.UUID.dump!(fx.tenant_id)
      ])

    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    first = start!(fx, definition)
    second = start!(fx, definition)
    run(fx)

    assert [first, second] |> Enum.map(&status(fx, &1)) |> Enum.sort() == [:completed, :error]
    assert [_one] = mails()
    errored = Enum.find([first, second], &(status(fx, &1) == :error))
    assert [%StepDispatch{last_failure_kind: "notify_skipped"}] = rows(fx, errored)
    assert [%Entry{entry_type: "notify_step"}] = dlq(fx, errored)
  end

  test "NS9 no personal value in the step row or the DLQ entry", %{fx: fx} do
    definition = activate!(fx, graph([node("notify", mail_declaration())]))
    Double.set_behaviour(:error)
    id = start!(fx, definition)
    run(fx)

    dump = inspect(rows(fx, id)) <> inspect(dlq(fx, id))
    refute dump =~ @address
    refute dump =~ "someone.private"
    refute dump =~ "Acme"
  end

  test "NS10 the shipped registration definition's notify node parses as a notify route" do
    graph = Letflow.PlatformProcesses.Definition.graph()
    {:ok, g} = Letflow.Definitions.Graph.from_map(graph)
    node = Enum.find(g.nodes, &(&1.id == "notify"))

    assert {:ok, %ServiceTask.Config{route_kind: :notify}} =
             ServiceTask.parse_config_from_node_attributes(node)
  end
end
