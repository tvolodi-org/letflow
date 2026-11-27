defmodule Letflow.PlatformFunctions.ModuleTenantRule do
  @moduledoc """
  The TENANT RULE of a module family entry (D-204, the module-process
  conversion, section 1.2).

  The platform family runs only in the platform tenant (INV-10). A MODULE
  family entry runs somewhere else: in the tenant that has the module
  INSTALLED, with the compiled module's manifest hash accepted.

  That is the check `Letflow.Definitions.ModuleWrites` does today for the
  OWNER STAMP (its module is installed in this tenant, its installed manifest
  hash equals the stamp's, and the manifest hash compiled into THIS build
  matches the installed one -- decision OQ-R3, no drift tolerance). D-204 moves
  that check from the stamp to the entry: a tenant-edited definition has no
  stamp, so the stamp could not carry the rule; the entry can.

  The check itself lives in `Letflow.Definitions.ModuleWrites` (one
  implementation, one vocabulary of codes); this module is the rule the module
  call path asks: the entry names the module, the rule looks the module up in
  the tenant.

  ## The refusals

    * `:module_call_tenant_rule_not_applicable` -- the entry is not a module
      family entry (the platform family has its own rule);
    * `:module_write_module_not_installed` -- the module is not installed in
      the tenant (or it is uninstalled);
    * `:module_write_hash_mismatch` -- the tenant's install row carries no
      manifest hash;
    * `:module_write_upgrade_required` -- the tenant has an older module than
      the one compiled into this build. The tenant must upgrade the module
      before it may run the call.

  ## Never raises

  A rule that answers at run time never raises (INV-8): every answer is `:ok`
  or `{:error, code}` with a code out of `codes/0`. A module that is not
  compiled into this build cannot have an entry (the catalogue is derived from
  the compiled modules), so it is not a case the rule has to answer.
  """

  alias Letflow.Definitions.ModuleWrites
  alias Letflow.PlatformFunctions.Entry

  @codes [
    :module_call_tenant_rule_not_applicable,
    :module_write_module_not_installed,
    :module_write_hash_mismatch,
    :module_write_upgrade_required
  ]

  @doc """
  The closed list of refusal codes the rule answers with.
  """
  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc """
  The rule for a MODULE FAMILY entry in `prefix`: `:ok` when the module is
  installed in that tenant and the compiled module's manifest hash is the
  accepted one, `{:error, code}` otherwise.

  Never raises.
  """
  @spec check(Entry.t(), String.t()) :: :ok | {:error, atom()}
  def check(%Entry{} = entry, prefix) when is_binary(prefix) do
    case Entry.module_id(entry) do
      nil ->
        {:error, :module_call_tenant_rule_not_applicable}

      module_id ->
        case ModuleWrites.module_install_codes(module_id, prefix) do
          [] -> :ok
          [code | _rest] -> {:error, code}
        end
    end
  end

  def check(_entry, _prefix), do: {:error, :module_call_tenant_rule_not_applicable}
end
