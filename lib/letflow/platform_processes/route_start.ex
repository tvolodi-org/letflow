defmodule Letflow.PlatformProcesses.RouteStart do
  @moduledoc """
  The answer of the two operator routes that REGISTER a tenant (T-2704, pilot
  gap G17b): `POST /api/v1/onboarding` and `POST /api/v1/tenants`.

  Both routes used to create and provision the tenant themselves. They now
  validate their form and hand it to `Letflow.PlatformProcesses.start_register_tenant/2`
  -- the ONE start function of the `platform.register_tenant` definition -- and
  answer here, so the two routes answer the same shape:

    * `202` `{instance_id, status, slug, replayed?}` -- the instance is started;
      the engine runs its steps (create, provision, bind, notify) afterwards.
      The tenant id is the OUTPUT of the `tenant.create` step, so it does not
      exist yet at this answer: the caller reads the instance timeline, or
      `GET /tenants/:slug`, to follow it;
    * `409` -- the same registration was started with other values (the start
      key is the slug alone, so a double click of ONE form is a replay and
      answers the first instance, `replayed: true`);
    * `503` -- no active `platform.register_tenant` definition. The route's own
      permission (`:TenantsManage`, platform tenant) is already proven here, so
      an unknown definition is an operational fact, not an existence oracle;
    * `404` -- the caller has no user id to audit (never a 5xx, INV-8).

  No secret is in the answer: the form's realm and e-mail are start variables
  of the instance and are never echoed.
  """

  require Logger

  alias Letflow.Api.Response
  alias Letflow.PlatformProcesses

  @doc """
  True when a start with this form's key already exists (a replay or a reuse).

  The routes ask this BEFORE their state prechecks: once the create step has
  committed, the slug is taken by the registration's own tenant, so a precheck
  would answer 409 to a double click. An existing start goes straight to
  `respond/2`, where the engine answers the replay (same values) or the 409
  (other values). A genuinely new request never matches, so its prechecks run.
  """
  @spec started?(map()) :: boolean()
  def started?(form) when is_map(form) do
    with {:ok, prefix} <- Letflow.PlatformTenant.platform_prefix() do
      match?(
        {:ok, _event},
        Letflow.Engine.IdempotentReplay.lookup(
          PlatformProcesses.register_tenant_start_key(form),
          prefix
        )
      )
    else
      _ -> false
    end
  rescue
    # No readable platform start ledger (the schema is not provisioned): nothing was started,
    # so the route's own prechecks decide (INV-8: no 500 from the lookup).
    Postgrex.Error -> false
  end

  @doc """
  Starts the registration for `form` as the caller of `conn` and answers.
  """
  @spec respond(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def respond(conn, form) when is_map(form) do
    auth_context = conn.assigns.auth_context

    opts = [
      actor_id: Map.get(auth_context, :user_id),
      idempotency_key: PlatformProcesses.register_tenant_start_key(form),
      auth_context: auth_context
    ]

    answer(conn, form, PlatformProcesses.start_register_tenant(form, opts))
  end

  defp answer(conn, form, {:ok, result}) do
    body = %{
      "instance_id" => result.instance_id,
      "status" => to_string(result.status),
      "slug" => Map.get(form, :slug)
    }

    body = if Map.get(result, :replayed), do: Map.put(body, "replayed", true), else: body
    Response.send_json(conn, 202, body)
  end

  defp answer(conn, _form, {:error, :idempotency_key_reuse}),
    do: Response.conflict(conn, "this registration was already started with other values")

  defp answer(conn, _form, {:error, reason})
       when reason in [
              :definition_not_found,
              :definition_not_active,
              :platform_tenant_not_configured
            ],
       do: Response.service_unavailable(conn, "the tenant registration process is not available")

  defp answer(conn, _form, {:error, reason}) when reason in [:missing_actor_id],
    do: Response.not_found(conn)

  defp answer(conn, _form, {:error, reason}) do
    # The tag only: a start error can carry a changeset or an exception (INV-4, INV-8).
    Logger.error("tenant registration start failed: #{inspect(error_tag(reason))}")
    Response.internal_error(conn)
  end

  defp error_tag({tag, _detail}) when is_atom(tag), do: tag
  defp error_tag(tag) when is_atom(tag), do: tag
  defp error_tag(_other), do: :other
end
