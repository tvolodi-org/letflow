defmodule Letflow.PlatformFunctions.Registry do
  @moduledoc """
  The CLOSED registry of platform function BODIES (T-2589, pilot gap G1a; the
  decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (a)).

  `Letflow.PlatformFunctions.Catalog` says WHAT a platform function is (its
  name, its typed inputs and their source class, its outputs, the permission
  the activator and the starter must hold, its side effects, its idempotency
  key and whether it may run only in the platform tenant). This module says
  WHICH CODE RUNS a name -- the closed list of implementations, compiled into
  the build.

  ## Closed, twice over

    * a name that is not declared in the catalogue has no body: the catalogue
      is the only list of names a definition may call, and
      `Letflow.PlatformFunctions.Guard` refuses an unknown one before the
      dispatcher ever looks here;
    * a name that IS declared but has no body yet is refused with
      `:platform_function_not_implemented`. The catalogue may declare a
      function before the pilot registers its body; the dispatcher never
      pretends such a call succeeded.

  ## The compile-time check

  An implementation whose name is not declared in the compiled catalogue is a
  COMPILE error, not a run-time surprise: the catalogue is code, and code
  that does not compile does not ship. The check runs in the module body,
  which Elixir executes while compiling the module.

  ## Who may add an entry

  Whoever may merge code (review, tests, CI). There is no write route and no
  run-time registration: designers and administrators only CHOOSE entries.
  """

  alias Letflow.PlatformFunctions.Catalog

  # The implementations, in code. `{name, {module, function, arity}}`.
  #
  # T-2590 (pilot gap G1b) adds the side-effecting functions of the tenant
  # registration chain: the code that today sits in the routes and in the
  # provisioner now lives in the modules below, so the route and the platform
  # step call ONE implementation. Each body is idempotent: a second run
  # changes nothing.
  @implementations [
    {"platform.validate_registration",
     {Letflow.PlatformFunctions.Impl.ValidateRegistration, :run, 1}},
    {"tenant.validate", {Letflow.PlatformFunctions.Impl.TenantValidate, :run, 1}},
    {"tenant.create", {Letflow.PlatformFunctions.Impl.TenantCreate, :run, 1}},
    {"tenant.provision", {Letflow.PlatformFunctions.Impl.TenantProvision, :run, 1}},
    {"tenant.bind_realm", {Letflow.PlatformFunctions.Impl.TenantBindRealm, :run, 1}},
    {"tenant.grant_first_admins",
     {Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins, :run, 1}},
    {"tenant.install_default_modules",
     {Letflow.PlatformFunctions.Impl.TenantInstallDefaultModules, :run, 1}}
  ]

  # The compile-time check: every body is declared in the compiled catalogue.
  for {name, _mfa} <- @implementations do
    case Catalog.fetch(name) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        raise "platform function implementation #{name} is not declared in the compiled catalogue"
    end
  end

  @implementation_map Map.new(@implementations)

  @doc """
  The body of the platform function named `name`.

  `{:error, :not_found}` when the name is not in the catalogue at all;
  `{:error, :not_implemented}` when it IS declared but has no body yet.
  """
  @spec fetch(String.t()) ::
          {:ok, {module(), atom(), arity()}} | {:error, :not_found | :not_implemented}
  def fetch(name) when is_binary(name) do
    case Map.fetch(@implementation_map, name) do
      {:ok, mfa} ->
        {:ok, mfa}

      :error ->
        case Catalog.fetch(name) do
          {:ok, _entry} -> {:error, :not_implemented}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc """
  The names that have a body, sorted. For the registry's own test and for the
  designer's picker (a name with no body is not offered).
  """
  @spec names() :: [String.t()]
  def names, do: @implementation_map |> Map.keys() |> Enum.sort()
end
