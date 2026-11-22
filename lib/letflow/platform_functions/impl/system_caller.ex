defmodule Letflow.PlatformFunctions.Impl.SystemCaller do
  @moduledoc """
  Who a platform step IS when it runs (T-2590, pilot gap G1b).

  A platform step runs OUTSIDE any person's request: the dispatcher calls the
  body from a durable queue, long after the person who started the instance
  answered. So the body has no operator to name.

  Two facts are shared by the bodies that write an audited row:

    * the ACTOR a system call writes. The nil UUID is this codebase's own
      "not a user" literal: `Letflow.TenantProvisioner.DefaultModules` installs
      modules under it and `Letflow.ModuleUpgrade.Boot` does the same. It is a
      literal, never an invented user id, and it grants nothing: no role row
      and no membership name it.
    * the PLATFORM PREFIX -- the schema of the platform tenant, taken from the
      server's own configuration (`Letflow.PlatformTenant.platform_prefix/0`),
      never from the caller. A platform step may only run in the platform
      tenant (INV-10), and the dispatcher proves that before the body runs.

  ## Why the person who activated the version is not the actor

  The person who switched a version on is recorded where it belongs: in the
  signed `activated_by` document of the definition version (the decision
  record 0094, decision (b)). The tenant's own audit chain records what
  happened to the tenant, and a step that ran long after the request has no
  single operator to name -- so it is written as a SYSTEM row.

  ## Extension point (owner decision D-180, not built here)

  A tenant may later fork a standard definition into its own copy (`custom`,
  `based_on`). Nothing here assumes that a definition is editable by whoever
  sees it, or that a tenant has exactly one definition per key: the actor of a
  step is read from the platform's own configuration and from the row the step
  writes, never from the definition's author.
  """

  alias Letflow.PlatformTenant

  # The nil UUID: the codebase's literal for "not a user" (see the moduledoc).
  @actor_id "00000000-0000-0000-0000-000000000000"

  @doc """
  The actor id a system call writes: the nil UUID.
  """
  @spec actor_id() :: String.t()
  def actor_id, do: @actor_id

  @doc """
  The schema of the platform tenant, `{:ok, prefix}`, or `:error` when no
  platform tenant is configured. The value comes from the server's own
  configuration, never from the caller.
  """
  @spec platform_prefix() :: {:ok, String.t()} | :error
  def platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> :error
    end
  end
end
