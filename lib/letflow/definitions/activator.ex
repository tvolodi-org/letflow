defmodule Letflow.Definitions.Activator do
  @moduledoc """
  GH #2587 / REQ-499 PR B1 (decision 0054 D4a, design
  `lib/letflow/design/gh2587-req499-pr-b-human-task-writes.md` D-B.14, D-B.24, 5.3).

  A definition whose HUMAN_TASK node declares `entity_writes` writes records on completion
  that the completer's own role could not write: the write is a DELEGATED privilege of the
  principal that ACTIVATED the definition. This module builds that principal's authority
  record from the request's server-side `auth_context`, and the `activated_by` document that
  is stored on the activated `process_definitions` row.

  Pure in its arguments: `platform_tenant?` is passed in (the router recomputes it from the
  database-resolved tenant, as `Letflow.Plugs.Authorize` does), so a hand-assigned context
  can never widen the evaluated roles outside the platform tenant. No query, no clock (the
  caller passes `now`), never raises.

  ## `activated_by` (jsonb, deterministic key order, ids and names only)

      %{"user_id" => uuid, "roles" => [sorted role names],
        "permissions" => [sorted evaluated permission names],
        "authorized" => [%{"entity_type" => t, "op" => "create"}, ...],
        "activated_at" => iso8601,
        "signature" => %{"alg" => "HMAC-SHA256", "key_version" => n, "mac" => hex}}

  The `signature` (T-0250, GH #2644) is added by `Letflow.Definitions.ActivatedBy.sign/3` on the
  signing paths (activate, rollback, promotion) and checked at use. It holds no secret and no
  field value (INV-2, INV-4).
  """

  alias Letflow.Api.Authorization
  alias Letflow.Engine.EntityPort

  # The permissions this module evaluates at activation and records.
  @recorded_permissions [:DefinitionsActivate, :EntitiesRecordsWrite]

  @doc """
  Builds the activator authority from a server-side `auth_context`.

  `nil` when the context carries no binary `user_id`. `roles` are the EFFECTIVE roles
  (`Authorization.effective_roles/2`, so `PLATFORM_ADMIN` is dropped outside the platform
  tenant) as sorted role names; `entities_records_write?` is whether those roles hold
  `:EntitiesRecordsWrite`; `permissions` lists which of `:DefinitionsActivate` and
  `:EntitiesRecordsWrite` they hold.
  """
  @spec from_auth_context(auth_context :: term(), platform_tenant? :: boolean()) ::
          EntityPort.activator() | nil
  def from_auth_context(%{user_id: user_id, roles: role_strings}, platform_tenant?)
      when is_binary(user_id) and is_boolean(platform_tenant?) do
    roles = Authorization.effective_roles(role_strings, platform_tenant?)

    ctx = %Authorization.AccessContext{
      user_id: user_id,
      roles: roles,
      platform_tenant?: platform_tenant?
    }

    permissions =
      @recorded_permissions
      |> Enum.filter(&(Authorization.evaluate_access(ctx, &1).kind == :Allow))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{
      user_id: user_id,
      roles: roles |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      entities_records_write?: "EntitiesRecordsWrite" in permissions,
      permissions: permissions
    }
  end

  def from_auth_context(_auth_context, _platform_tenant?), do: nil

  @doc """
  The `activated_by` document for `activator`, authorising exactly `pairs` (`{entity_type,
  "create"}`; sorted and de-duplicated here). `now` is the activation instant.
  """
  @spec build_record(EntityPort.activator(), [{String.t(), String.t()}], DateTime.t()) :: map()
  def build_record(%{user_id: user_id} = activator, pairs, %DateTime{} = now)
      when is_list(pairs) do
    %{
      "user_id" => user_id,
      "roles" => Enum.sort(Map.get(activator, :roles, [])),
      "permissions" => Enum.sort(activator.permissions),
      "authorized" =>
        pairs
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn {entity_type, op} -> %{"entity_type" => entity_type, "op" => op} end),
      "activated_at" => DateTime.to_iso8601(now)
    }
  end
end
