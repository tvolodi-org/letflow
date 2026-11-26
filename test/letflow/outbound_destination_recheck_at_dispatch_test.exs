defmodule Letflow.OutboundDestinationRecheckAtDispatchTest do
  @moduledoc """
  T-2597 (pilot gap G14; decision record G2, S7 -- "List widened after
  activation"): the per-tenant OUTBOUND ALLOW-LIST is read AGAIN at dispatch,
  not only at activation.

  A destination that was removed after the version was switched on stops the
  step that would have used it: the list is the door, and the door can be
  closed while a definition is running.

  Test ids S7-a..S7-c.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.OutboundDestinations
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.WebhookTestServer

  setup do
    tenant = Fx.tenant!("t2597-recheck")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "recheck-admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin, prefix: tenant.schema_name}
  end

  defp declaration do
    %{
      "template_key" => "tenant_registered",
      "recipient" => %{"var" => "admin_email"},
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"const" => "acme"}
      }
    }
  end

  defp schemas do
    [
      %{variable_key: "admin_email", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_name", json_schema: %{"type" => "string"}}
    ]
  end

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "step",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"notify" => declaration()}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "step"},
        %{"id" => "e2", "source" => "step", "target" => "end"}
      ]
    }
  end

  defp variables do
    %{"admin_email" => "admin@example.com", "tenant_name" => "Acme"}
  end

  defp allow(ctx, channel, destination) do
    {:ok, _entry} =
      OutboundDestinations.add(
        ctx.prefix,
        ctx.admin.id,
        channel,
        destination
      )

    :ok
  end

  defp activate(ctx, definition) do
    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    Definitions.activate(definition.id, prefix: ctx.prefix, activator: activator)
  end

  defp dispatch(ctx) do
    Dispatcher.run(
      declaration(),
      variables(),
      prefix: ctx.prefix,
      trigger_ref: Ecto.UUID.generate(),
      labels: %{}
    )
  end

  test "S7-a a destination removed AFTER the activation stops the step at dispatch", ctx do
    allow(ctx, "email", nil)
    allow(ctx, "email", "example.com")

    draft = Fx.definition_with_schemas!(ctx.prefix, graph(), "t2597-recheck", schemas())
    assert {:ok, _definition} = activate(ctx, draft)

    # The door is closed while the definition runs.
    assert {:ok, :removed} =
             OutboundDestinations.remove(
               ctx.prefix,
               ctx.admin.id,
               "email",
               "example.com"
             )

    assert {:error, :notify_destination_not_allowed} = dispatch(ctx)
  end

  test "S7-b the CHANNEL removed after the activation stops the step at dispatch", ctx do
    allow(ctx, "email", nil)
    allow(ctx, "email", "example.com")

    draft = Fx.definition_with_schemas!(ctx.prefix, graph(), "t2597-recheck", schemas())
    assert {:ok, _definition} = activate(ctx, draft)

    assert {:ok, :removed} =
             OutboundDestinations.remove(
               ctx.prefix,
               ctx.admin.id,
               "email",
               nil
             )

    assert {:error, :notify_destination_not_allowed} = dispatch(ctx)
  end

  test "S7-c a destination that was never on the list stops the step at dispatch", ctx do
    allow(ctx, "email", nil)

    draft = Fx.definition_with_schemas!(ctx.prefix, graph(), "t2597-recheck", schemas())
    assert {:ok, _definition} = activate(ctx, draft)

    assert {:error, :notify_destination_not_allowed} = dispatch(ctx)
  end

  # ── the HTTP channel: the HOST of an inline HTTP step ────────────────────────────────
  #
  # The notification channel above is re-read at dispatch by
  # `Letflow.NotificationSteps.Dispatcher`; the INLINE HTTP step is re-read by
  # `Letflow.Engine.ServiceTaskDispatcher` (the engine's own dispatch path).
  # Same rule, same moment: the list is read on the attempt that would open
  # the socket, so a host removed while the definition runs stops the step.

  defp insert_dispatch!(prefix, rendered_url) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      instance_id: Ecto.UUID.generate(),
      token_id: Ecto.UUID.generate(),
      node_id: "http-step",
      config_snapshot: %{
        "route_kind" => "inline_url",
        "url_template" => rendered_url,
        "rendered_url" => rendered_url,
        "method" => "POST",
        "body_template" => nil,
        "headers" => %{},
        "timeout_ms" => 5_000,
        "retry_limit" => 0
      },
      next_attempt_at: now,
      created_at: now
    }

    {:ok, dispatch} =
      %ServiceTaskDispatch{}
      |> ServiceTaskDispatch.arm_changeset(attrs)
      |> Repo.insert(prefix: prefix)

    dispatch
  end

  # The local listener is reached only with the SSRF gate's own documented
  # test seam off (`http://127.0.0.1:PORT` is a private range, which the gate
  # refuses -- the seam changes the URL check, not the allow-list).
  defp with_ssrf_seam_off do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  test "S7-d an inline HTTP step whose HOST is on the list reaches the target", ctx do
    with_ssrf_seam_off()

    %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

    allow(ctx, "http", nil)
    allow(ctx, "http", "127.0.0.1")

    dispatch = insert_dispatch!(ctx.prefix, server_url)

    assert {:ok, {:advance, decoded_body}} =
             ServiceTaskDispatcher.attempt_dispatch(dispatch.id, ctx.prefix)

    assert decoded_body == %{"result" => "ok"}
  end

  test "S7-e a HOST removed after the activation stops the inline HTTP step at dispatch", ctx do
    with_ssrf_seam_off()

    %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

    allow(ctx, "http", nil)
    allow(ctx, "http", "127.0.0.1")

    dispatch = insert_dispatch!(ctx.prefix, server_url)

    # The door is closed while the definition runs.
    assert {:ok, :removed} =
             OutboundDestinations.remove(ctx.prefix, ctx.admin.id, "http", "127.0.0.1")

    assert {:ok, {:give_up, error_attrs}} =
             ServiceTaskDispatcher.attempt_dispatch(dispatch.id, ctx.prefix)

    assert error_attrs.details.last_failure_kind == :request_build_error
  end

  test "S7-f an inline HTTP step whose HOST was never on the list stops at dispatch", ctx do
    with_ssrf_seam_off()

    %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

    allow(ctx, "http", nil)

    dispatch = insert_dispatch!(ctx.prefix, server_url)

    assert {:ok, {:give_up, error_attrs}} =
             ServiceTaskDispatcher.attempt_dispatch(dispatch.id, ctx.prefix)

    assert error_attrs.details.last_failure_kind == :request_build_error
  end

  test "S7-g an inline HTTP step with no rendered URL fails closed at dispatch", ctx do
    allow(ctx, "http", nil)

    dispatch = insert_dispatch!(ctx.prefix, "https://example.com/x")

    # The row carries no readable rendered URL: the fallback clause refuses it
    # (it must not reach the transport, whose guard needs a binary).
    snapshot = Map.put(dispatch.config_snapshot, "rendered_url", nil)

    dispatch
    |> Ecto.Changeset.change(%{config_snapshot: snapshot})
    |> Repo.update!(prefix: ctx.prefix)

    assert {:ok, {:give_up, error_attrs}} =
             ServiceTaskDispatcher.attempt_dispatch(dispatch.id, ctx.prefix)

    assert error_attrs.details.last_failure_kind == :request_build_error
  end
end
