defmodule Letflow.PlatformProcesses.SystemStart do
  @moduledoc """
  The narrow START AUTHORITY of the two routes that have no person behind them
  (T-2727, pilot gap G17c; `docs/platform-register-tenant-v2.md` section 6;
  decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  Update "The system-authority start").

  Route 3 (the provisioner mount) and route 4 (the self-service signup) create a
  tenant today with no `auth_context`. When they start `platform.register_tenant`
  they hold THIS struct instead. It keeps today's behaviour behind the
  definition: it is NO new way to create a tenant.

  The struct is bound to ONE definition name and to a closed list of routes.
  The only constructor is `for_route/1`; there is no cast, no decoder and no
  field comes from a request. `Letflow.Definitions.StartPermission.check/4`
  admits it for the registration definition only, in the platform prefix only,
  with exactly the permission `:TenantsManage`, no SUB_PROCESS child and the v2
  start contract. Anything else answers as an unknown definition (INV-5).
  """

  @definition_name "platform.register_tenant"
  @routes [:admin_v1_tenants_create, :signup_provisioning]

  @enforce_keys [:definition_name, :route]
  defstruct [:definition_name, :route]

  @type route :: :admin_v1_tenants_create | :signup_provisioning
  @type t :: %__MODULE__{definition_name: String.t(), route: route()}

  @doc """
  The ONLY constructor: a route of the closed list, or `{:error, :unknown_route}`.
  """
  @spec for_route(term()) :: {:ok, t()} | {:error, :unknown_route}
  def for_route(route) when route in @routes,
    do: {:ok, %__MODULE__{definition_name: @definition_name, route: route}}

  def for_route(_other), do: {:error, :unknown_route}

  @doc "The route name written to the audit row (`started_via`)."
  @spec started_via(t()) :: String.t()
  def started_via(%__MODULE__{route: route}), do: Atom.to_string(route)
end
