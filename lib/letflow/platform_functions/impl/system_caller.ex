defmodule Letflow.PlatformFunctions.Impl.SystemCaller do
  @moduledoc """
  Who a platform step IS when it runs (T-2590, pilot gap G1b).

  A platform step runs OUTSIDE any person's request: the dispatcher calls the
  body from a durable queue, long after the person who started the instance
  answered. So the body has no operator to name.

  ## The fact the bodies share: the PLATFORM PREFIX

  The schema of the platform tenant, taken from the server's own
  configuration (`Letflow.PlatformTenant.platform_prefix/0`), never from the
  caller. A platform step may only run in the platform tenant (INV-10), and
  the dispatcher proves that before the body runs.

  ## The fact the bodies do NOT share: an actor id

  The audited rows a step writes carry NO actor (`actor_id: nil`), and the
  marker that says "a system wrote this" is IN the entry: the realm bind
  writes `actor_class: "provisioner"` in the tenant chain, the pending grant
  writes `created_via: "provisioning"`. Those rows are written by the
  product's own SYSTEM paths (`Letflow.Identity.bind_provisioned_realm/3`,
  `Letflow.Identity.PendingAdminGrants.create_provisioned/2`), which take no
  actor of their own -- so a body has no actor id to pass and none to
  invent. The codebase's other "not a user" literal (the nil UUID, used by
  the module installer and the module boot) belongs to those paths and is
  not this module's to hand out.

  ## Why the person who activated the version is not the actor

  The person who switched a version on is recorded where it belongs: in the
  signed `activated_by` document of the definition version (the decision
  record 0094, decision (b)). The tenant's own audit chain records what
  happened to the tenant, and a step that ran long after the request has no
  single operator to name -- so it is written as a SYSTEM row.

  ## Extension point (owner decision D-180, not built here)

  A tenant may later fork a standard definition into its own copy (`custom`,
  `based_on`). Nothing here assumes that a definition is editable by whoever
  sees it, or that a tenant has exactly one definition per key: the prefix of
  a step is read from the platform's own configuration and from the row the
  step writes, never from the definition's author.
  """

  alias Letflow.PlatformTenant

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
