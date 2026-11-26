defmodule Letflow.Instances.StepLogSecretTest do
  @moduledoc """
  The NO-SECRET test of the step log (pilot gap G6; owner items 4 and 7: "no
  secrets in the log").

  A step runs with secrets in play: the pilot's `tenant.bind_realm` step
  carries a realm credential, a notification step carries a mail body, and an
  outbound step carries a token. None of them may reach:

    * the STEP LOG -- the log names the node, the function and the outcome,
      never a value;
    * the TIMELINE ANSWER -- the HTTP answer of
      `GET /api/v1/instances/:id/timeline`, the event items and the step rows
      together;
    * the DLQ PAYLOAD -- the row an exhausted step lands, which used to store
      the attempted request with its body and its headers.

  The canaries are read back from the DATABASE and from the HTTP answer, not
  from the code's own return value.

  `async: false`: the tenant fixture provisions a schema and replays the
  tenant migrations.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.EventStore.Event
  alias Letflow.Instances.StepLog
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Instances.init([])

  # The three secrets of the pilot, as canaries.
  @realm_credential "REALM-CREDENTIAL-CANARY-7f3a"
  @mail_body "MAIL-BODY-CANARY-91bc"
  @token "TOKEN-CANARY-4d2e"

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "g6-secret")}
  end

  test "the step log carries neither the realm credential nor the mail body of its dispatch row",
       %{tenant: tenant} do
    instance_id = Ecto.UUID.generate()

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "call",
        "node_type" => "SERVICE_TASK",
        "via_edge_id" => "e1"
      },
      1
    )

    insert_platform_dispatch!(
      tenant,
      instance_id,
      "call",
      "tenant.bind_realm",
      %{
        "realm_id" => @realm_credential,
        "client_secret" => @token
      },
      %{"tenant_id" => "b8f2-tenant"}
    )

    assert {:ok, [step]} = StepLog.steps(instance_id, prefix: tenant.schema_name)

    rendered = inspect(step)

    refute rendered =~ @realm_credential
    refute rendered =~ @token
    refute rendered =~ @mail_body

    # The step still names the function it ran: the log is not empty, it is
    # a log of NAMES.
    assert step.step == "tenant.bind_realm"
  end

  test "the timeline answer carries no secret of a step: no realm credential, no token, no mail body",
       %{tenant: tenant} do
    instance_id = start_instance!(tenant.schema_name)

    insert_event!(
      tenant.schema_name,
      instance_id,
      "NODE_ENTERED",
      %{
        "node_id" => "call",
        "node_type" => "SERVICE_TASK",
        "via_edge_id" => "e1"
      },
      100
    )

    insert_event!(
      tenant.schema_name,
      instance_id,
      "SERVICE_TASK_COMPLETED",
      %{
        "node_id" => "call",
        "dispatch_id" => Ecto.UUID.generate(),
        "decoded_body" => @mail_body
      },
      101
    )

    insert_platform_dispatch!(
      tenant,
      instance_id,
      "call",
      "tenant.bind_realm",
      %{
        "realm_id" => @realm_credential,
        "client_secret" => @token
      },
      %{"tenant_id" => "b8f2-tenant"}
    )

    body = timeline_body(tenant, instance_id)
    {raw, decoded} = body

    refute raw =~ @realm_credential
    refute raw =~ @token
    refute raw =~ @mail_body

    # The step log IS in the answer -- the assertion above is about the
    # values, not about an empty answer.
    assert %{"steps" => steps} = decoded
    step = Enum.find(steps, &(&1["node_id"] == "call"))
    assert step["step"] == "tenant.bind_realm"
  end

  test "the DLQ payload of an exhausted step carries no secret: no body, no headers, no query", %{
    tenant: tenant
  } do
    instance_id = start_instance!(tenant.schema_name)

    context = %{
      instance_id: instance_id,
      node_id: "call",
      actor_id: Ecto.UUID.generate(),
      idempotency_key: "g6-secret-#{System.unique_integer([:positive, :monotonic])}",
      variables: %{},
      last_failure_kind: :timeout,
      attempt_index: 3,
      retry_limit: 3,
      attempted_request: %{
        method: "POST",
        url: "https://mail.example.test/send?token=#{@token}",
        body: @mail_body,
        headers: %{"authorization" => "Bearer #{@token}"}
      }
    }

    assert {:ok, _result} =
             Engine.land_service_task_exhaustion(context, prefix: tenant.schema_name)

    assert [entry] =
             Dlq.Entry
             |> where([d], d.instance_id == ^instance_id)
             |> Repo.all(prefix: tenant.schema_name)

    rendered = inspect(entry.source_payload)

    refute rendered =~ @token
    refute rendered =~ @mail_body
    refute rendered =~ @realm_credential

    # What it DOES say: the method and the ORIGIN of the destination. The
    # path and the query are gone.
    assert entry.source_payload["method"] == "POST"
    assert entry.source_payload["url"] == "https://mail.example.test"

    # The node the failed step belongs to is on the row, so the operator
    # finds the step without reading a payload.
    assert entry.reference_id == "call"
  end

  test "the DLQ payload of an exhausted step survives a URL it cannot parse and a URL over the byte cap",
       %{tenant: tenant} do
    # A URL that is not valid UTF-8 and a URL over the byte cap: neither may
    # raise (INV-8) and neither may be stored (SF-01). One instance each:
    # the landing sets the instance to ERROR, so a second landing on the
    # same instance would fail for that reason.
    urls = [
      "https://example.test/" <> String.duplicate("x", 600),
      <<"https://example.test/", 255>>
    ]

    for url <- urls do
      instance_id = start_instance!(tenant.schema_name)

      context = %{
        instance_id: instance_id,
        node_id: "call",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "g6-secret-#{System.unique_integer([:positive, :monotonic])}",
        variables: %{},
        last_failure_kind: :timeout,
        attempt_index: 3,
        retry_limit: 3,
        attempted_request: %{method: "POST", url: url, body: nil, headers: %{}}
      }

      assert {:ok, _result} =
               Engine.land_service_task_exhaustion(context, prefix: tenant.schema_name)

      assert [entry] =
               Dlq.Entry
               |> where([d], d.instance_id == ^instance_id)
               |> Repo.all(prefix: tenant.schema_name)

      assert entry.source_payload["url"] == "redacted"
    end
  end

  defp timeline_body(tenant, instance_id) do
    conn =
      conn(:get, "/#{instance_id}/timeline")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant.tenant_id,
        roles: ["PROCESS_OPERATOR"]
      })
      |> assign(:trace_id, "g6-secret-trace")
      |> Letflow.Routers.Instances.call(@opts)

    assert conn.status == 200
    {conn.resp_body, Jason.decode!(conn.resp_body)}
  end

  defp start_instance!(schema_name) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }

    {:ok, definition} =
      Definitions.create(
        %{
          name: "g6-secret-def-#{System.unique_integer([:positive, :monotonic])}",
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema_name
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema_name)

    {:ok, created} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "g6-secret-start-#{System.unique_integer([:positive, :monotonic])}"
        },
        prefix: schema_name
      )

    created.instance_id
  end

  defp insert_event!(schema, instance_id, event_type, payload, sequence_number) do
    attrs = %{
      event_id: Ecto.UUID.generate(),
      instance_id: instance_id,
      event_type: event_type,
      payload: payload,
      metadata: %{},
      actor_id: Letflow.EventStore.platform_actor_id(),
      sequence_number: sequence_number,
      idempotency_key: "g6-secret-#{System.unique_integer([:positive, :monotonic])}",
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    {:ok, event} =
      %Event{}
      |> Event.insert_changeset(attrs)
      |> Repo.insert(prefix: schema)

    event
  end

  defp insert_platform_dispatch!(tenant, instance_id, node_id, function_name, inputs, outputs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      instance_id: instance_id,
      definition_id: Ecto.UUID.generate(),
      node_id: node_id,
      function_name: function_name,
      call_key: "g6-secret-#{System.unique_integer([:positive, :monotonic])}",
      input_fingerprint: "fingerprint",
      inputs: inputs,
      status: :pending,
      attempt_index: 1,
      next_attempt_at: now,
      created_at: now
    }

    {:ok, dispatch} =
      %StepDispatch{}
      |> StepDispatch.arm_changeset(attrs)
      |> Repo.insert(prefix: tenant.schema_name)

    # The outputs are a TERMINAL write of the row, the same write that
    # records the result of the call.
    {:ok, dispatch} =
      dispatch
      |> StepDispatch.terminal_changeset(%{
        status: :advanced,
        outputs: outputs,
        dispatched_at: now
      })
      |> Repo.update(prefix: tenant.schema_name)

    dispatch
  end
end
