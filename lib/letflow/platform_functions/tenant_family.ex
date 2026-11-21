defmodule Letflow.PlatformFunctions.TenantFamily do
  @moduledoc """
  The platform family's catalogue entries: the tenant registration chain of the
  "Register a tenant" pilot (T-2588, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`).

  These are DECLARATIONS. The bodies of the functions and the dispatcher that
  runs them belong to the step library (gap G1); what this module states is what
  the AUTHORITY rule needs: the function name, the typed inputs and their
  source classes, the outputs, the permission the activator and the starter
  must hold, the side effects, the idempotency key and the fact that the whole
  family runs only in the platform tenant (INV-10).

  Every entry of the family requires `:TenantsManage`, the platform atom the
  tenant lifecycle routes already use (`Letflow.Api.Authorization` maps
  `POST /tenants` and the onboarding routes to it), so a holder of that atom is
  the one who may switch a version that calls the family on.

  ## The chain

      tenant.validate -> tenant.create -> tenant.provision ->
      tenant.bind_realm -> tenant.grant_first_admins ->
      tenant.install_default_modules

  `tenant.create` and the steps after it read the tenant id from the OUTPUT of
  an earlier platform step (source class `:step`), never from a human task's
  completer: a write-like input may never be `:person` (the T-2430 rule
  carried over by source class).
  """

  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Entry.Input
  alias Letflow.PlatformFunctions.Entry.Output
  alias Letflow.PlatformFunctions.Entry.SideEffect

  @permission :TenantsManage
  @version "1"

  @doc """
  The entries this family declares, in chain order.
  """
  @spec entries() :: [Entry.t()]
  def entries do
    [
      validate(),
      create(),
      provision(),
      bind_realm(),
      grant_first_admins(),
      install_default_modules()
    ]
  end

  @doc """
  The permission atom every entry of the family requires.
  """
  @spec permission() :: atom()
  def permission, do: @permission

  defp validate do
    %Entry{
      name: "tenant.validate",
      family: :platform,
      version: @version,
      inputs: [
        %Input{name: "slug", type: :string, required: true, source_class: :start},
        %Input{name: "name", type: :string, required: true, source_class: :start}
      ],
      outputs: [],
      permission: @permission,
      side_effects: [
        %SideEffect{
          text: "reads the tenant registry and answers whether the slug is free",
          class: :read
        }
      ],
      idempotency_key: ["slug"],
      platform_tenant_only: true
    }
  end

  defp create do
    %Entry{
      name: "tenant.create",
      family: :platform,
      version: @version,
      inputs: [
        %Input{name: "slug", type: :string, required: true, source_class: :start},
        %Input{name: "name", type: :string, required: true, source_class: :start}
      ],
      outputs: [%Output{name: "tenant_id", type: :uuid}],
      permission: @permission,
      side_effects: [
        %SideEffect{text: "writes the tenant registry row", class: :write_tenant_registry}
      ],
      idempotency_key: ["slug"],
      platform_tenant_only: true
    }
  end

  defp provision do
    %Entry{
      name: "tenant.provision",
      family: :platform,
      version: @version,
      inputs: [%Input{name: "tenant_id", type: :uuid, required: true, source_class: :step}],
      outputs: [%Output{name: "schema_name", type: :string}],
      permission: @permission,
      side_effects: [
        %SideEffect{text: "creates the tenant schema and runs its migrations", class: :ddl}
      ],
      idempotency_key: ["tenant_id"],
      platform_tenant_only: true
    }
  end

  defp bind_realm do
    %Entry{
      name: "tenant.bind_realm",
      family: :platform,
      version: @version,
      inputs: [
        %Input{name: "tenant_id", type: :uuid, required: true, source_class: :step},
        %Input{name: "realm_id", type: :string, required: true, source_class: :start}
      ],
      outputs: [],
      permission: @permission,
      side_effects: [
        %SideEffect{text: "calls the identity provider's realm API", class: :outbound}
      ],
      idempotency_key: ["tenant_id"],
      platform_tenant_only: true
    }
  end

  defp grant_first_admins do
    %Entry{
      name: "tenant.grant_first_admins",
      family: :platform,
      version: @version,
      inputs: [
        %Input{name: "tenant_id", type: :uuid, required: true, source_class: :step},
        %Input{name: "admin_email", type: :string, required: true, source_class: :start}
      ],
      outputs: [],
      permission: @permission,
      side_effects: [
        %SideEffect{
          text: "grants the first administrator of the new tenant",
          class: :write_tenant_registry
        }
      ],
      idempotency_key: ["tenant_id"],
      platform_tenant_only: true
    }
  end

  defp install_default_modules do
    %Entry{
      name: "tenant.install_default_modules",
      family: :platform,
      version: @version,
      inputs: [%Input{name: "tenant_id", type: :uuid, required: true, source_class: :step}],
      outputs: [],
      permission: @permission,
      side_effects: [
        %SideEffect{
          text: "installs the new tenant's default modules",
          class: :write_tenant_registry
        }
      ],
      idempotency_key: ["tenant_id"],
      platform_tenant_only: true
    }
  end
end
