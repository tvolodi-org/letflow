defmodule Letflow.PlatformProcesses.Seed do
  @moduledoc """
  The SEED of the pilot's registration definition (T-2595, gap G9 of the
  "Register a tenant" pilot; the spike is `project/pilot-register-tenant-design.md`
  of the team repository, section 3).

  It writes ONE version of ONE key -- `platform.register_tenant` v1 -- into
  the PLATFORM tenant, as an ordinary, unstamped, editable definition
  (`Letflow.PlatformProcesses.Definition` holds the document), and it never
  overwrites a version an administrator already made.

  ## v2 (T-2727)

  The seed now writes `Letflow.PlatformProcesses.DefinitionV2` (version "2"). Over the seed's own v1
  it writes v2 and switches it on (`:created`); v1 is deprecated by the activation and instances that
  run on it finish on their snapshot. A version "2" that carries another document is answered
  `:version_taken` and nothing is written.

  ## The answers

  `seed/1` answers one of these, and it says which:

    * `:version_taken` -- a row of the seed's version exists with a graph that is not the shipped
      document (an administrator's own);

    * `:created` -- the definition did not exist and was written and switched
      on;
    * `:already_present` -- the version of this key already exists. Nothing was
      written: the seed is idempotent, and an administrator's own version of
      the key is never touched;
    * `:newer_version_kept` -- a NEWER version of the key is active and this
      seed's version is older. Nothing was written: the administrator's newer
      version stays the one that runs.

  A version that cannot be compared with the seed's (a version string that is
  not a plain number) counts as NEWER, so an unknown version is kept, never
  replaced.

  The comparison with the version that already runs comes FIRST, in every
  branch: a newer active version is kept and NOTHING is written -- not even
  when the seed's own older version is still lying around as a DRAFT (an
  interrupted seed run leaves one behind). Switching such a draft on would
  DEPRECATE the newer version that runs, so the seed never does it.

  ## The authority of the switch-on

  A definition that calls a platform function may be switched on only by
  someone who holds the catalogue entry's permission -- `:TenantsManage` in
  the platform tenant -- because the SIGNED `activated_by` document is the
  authority the run-time fence checks again (`Letflow.PlatformFunctions.Guard`).
  A seed cannot invent that authority: the seed names the platform
  administrator whose authority signs the version, and it READS that
  administrator's roles from the database (never from the caller's word).

  The administrator is `opts[:activator_user_id]` when the caller names one,
  and otherwise the first PLATFORM_ADMIN holder of the platform tenant
  (`Letflow.Identity.list_platform_admin_user_ids/1`, sorted by id, so the
  choice is deterministic). A tenant with no such administrator is answered
  `{:error, :no_platform_activator}` and NOTHING is written: a definition
  nobody may switch on is a definition that does not exist.

  ## The write

  The definition is written through the ordinary store functions --
  `Letflow.Definitions.create_with_variable_schemas/3` and
  `Letflow.Definitions.activate/2` -- so it is an ordinary draft that became
  an ordinary active version, with the ordinary audit rows. It carries NO
  owner stamp (`owner_module` and the two hashes stay NULL), so an
  administrator may edit it in the designer: an edit makes a NEW draft, and
  only an activation switches it on.

  ## The channels the seeded version uses

  A tenant may reach outside itself only where its own allow-list says so
  (T-2597, gap G14): the list is empty by default, and a version whose
  notification step reaches outside is refused at the activation. The platform's
  own standard version would therefore never be switched on.

  So the seed opens the CHANNELS its own version uses -- the mail channel of
  its notification step -- for the tenant it writes into, right before the
  switch-on. Two things it does NOT do:

    * it never opens a DESTINATION (a recipient domain): the address behind
      the door stays a human decision (decision record G2 (c)), so a
      notification still goes only to a domain a human listed;
    * it never opens a channel outside its own switch-on: the channels are
      opened on the path where the seed writes and switches on its own
      version, and on the path where it finishes an interrupted switch-on of
      that same version (a draft). A channel an administrator closed AFTER a
      completed switch-on stays closed; on the interrupted-switch-on path the
      seed re-opens the CHANNEL of its own version, which opens no address (a
      destination is still needed for a send).

  The seed may open a channel only with the authority of an administrator who
  HOLDS the narrow atom `:OutboundDestinationsManage`: a seed cannot invent
  that authority, exactly as it cannot invent `:TenantsManage`. Without it the
  seed answers `{:error, :activator_not_permitted}` and writes nothing.

  A channel alone opens nothing: a destination is still needed for a send, so
  the list shows the transport, not the address.

  ## The extension point (owner decision D-180, not built here)

  A standard definition is locked for everyone inside its tenant, and a tenant
  may later fork it into its own copy (`custom`, with
  `based_on: <standard key>@<version>`). The seed adds no column and no map
  for that lineage: it belongs to the definition ROW (see
  `Letflow.Definitions.ProcessDefinition`'s D-180 note). Nothing here assumes
  that a definition is editable by whoever sees it, nor that a tenant has
  exactly one definition per key.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity
  alias Letflow.OutboundDestinations
  alias Letflow.PlatformProcesses.DefinitionV2, as: Definition
  alias Letflow.PlatformTenant

  @typedoc "What the seed did."
  @type outcome :: :created | :already_present | :newer_version_kept | :version_taken

  @typedoc "The answer of the seed."
  @type result :: %{
          outcome: outcome(),
          definition: ProcessDefinition.t() | nil,
          version: String.t()
        }

  @doc """
  Writes the registration definition into the platform tenant, if the seed's
  version is the one that should run.

  `opts`:

    * `:prefix` -- the tenant schema to write in. It defaults to the platform
      tenant's schema, and a prefix that is NOT the platform tenant is
      refused: a `platform_call` may live in the platform tenant only (INV-10);
    * `:activator_user_id` -- the platform administrator whose authority signs
      the switch-on. It defaults to the first PLATFORM_ADMIN holder of the
      platform tenant.

  The answer is `{:ok, %{outcome: outcome, definition: row_or_nil, version: v}}`
  or `{:error, reason}`. It never raises (INV-8): every failure is an error
  tuple with a stable code.
  """
  @spec seed(keyword()) :: {:ok, result()} | {:error, term()}
  def seed(opts) when is_list(opts) do
    with {:ok, prefix} <- prefix(opts),
         {:ok, activator} <- activator(opts, prefix) do
      write(prefix, activator)
    end
  end

  # ── the tenant ───────────────────────────────────────────────────────────────────────

  defp prefix(opts) do
    case Keyword.get(opts, :prefix) do
      nil ->
        case PlatformTenant.platform_prefix() do
          {:ok, prefix} -> {:ok, prefix}
          :error -> {:error, :platform_tenant_not_configured}
        end

      prefix when is_binary(prefix) ->
        if PlatformTenant.platform_prefix?(prefix) do
          {:ok, prefix}
        else
          {:error, :not_the_platform_tenant}
        end

      _other ->
        {:error, :invalid_prefix}
    end
  end

  # ── the authority ────────────────────────────────────────────────────────────────────

  defp activator(opts, prefix) do
    with {:ok, user_id} <- activator_user_id(opts, prefix),
         {:ok, roles} <- roles(user_id, prefix),
         {:ok, activator} <- build_activator(user_id, roles),
         :ok <- permitted(activator) do
      {:ok, activator}
    end
  end

  defp activator_user_id(opts, prefix) do
    case Keyword.get(opts, :activator_user_id) do
      nil ->
        case Identity.list_platform_admin_user_ids(prefix) do
          [user_id | _rest] -> {:ok, user_id}
          [] -> {:error, :no_platform_activator}
        end

      user_id when is_binary(user_id) ->
        if Identity.user_exists?(user_id, prefix) do
          {:ok, user_id}
        else
          {:error, :activator_not_found}
        end

      _other ->
        {:error, :activator_not_found}
    end
  end

  # The roles are the ones the DATABASE resolved for that user in that tenant
  # (the same read the start permission and the run-time fence use), never the
  # ones the caller claims.
  defp roles(user_id, prefix) do
    {:ok, Identity.list_effective_role_names(user_id, prefix: prefix)}
  end

  defp build_activator(user_id, roles) do
    case Activator.from_auth_context(%{user_id: user_id, roles: roles}, true) do
      nil -> {:error, :activator_not_found}
      activator -> {:ok, activator}
    end
  end

  # The activator must hold the permission the catalogue entries of this
  # definition require (`:TenantsManage`), else the activation fence would
  # refuse the version and the seed would leave a draft behind.
  defp permitted(activator) do
    if "TenantsManage" in Map.get(activator, :catalogue_permissions, []) do
      :ok
    else
      {:error, :activator_not_permitted}
    end
  end

  # ── the write ────────────────────────────────────────────────────────────────────────

  # The ONE place where the seed decides what to do. The comparison with the
  # version that already runs comes FIRST and in EVERY branch: a newer active
  # version is kept and NOTHING is written, whichever of the seed's own rows
  # lies around. A seed may never switch an OLDER version on over a newer one
  # that already runs -- the activation deprecates the newer one.
  defp write(prefix, activator) do
    case existing(prefix) do
      {:ok, %{same_version: row, actives: actives}} ->
        cond do
          # A version NEWER than the seed's is already the one that runs.
          Enum.any?(actives, &newer?(&1.version, Definition.version())) ->
            kept = newest(actives)

            {:ok, %{outcome: :newer_version_kept, definition: kept, version: kept.version}}

          # The version of this key exists. An ACTIVE one is the seed's own work,
          # done. A DRAFT that carries the seed's OWN document is a seed whose
          # switch-on did not finish: the seed finishes it. Any other row (an
          # administrator's draft of the same version, a deprecated one) is left
          # alone -- the seed never touches what it did not write.
          unfinished_switch_on?(row) ->
            activate(row, prefix, activator)

          # T-2727: a row of the seed's version that carries ANOTHER document (an administrator's own
          # v2) is never mistaken for the shipped one: nothing is written.
          row != nil and row.graph != Definition.graph() ->
            {:ok, %{outcome: :version_taken, definition: row, version: Definition.version()}}

          row != nil ->
            {:ok, %{outcome: :already_present, definition: row, version: Definition.version()}}

          true ->
            create_and_activate(prefix, activator)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A DRAFT of the seed's own version carrying the seed's own document: the
  # switch-on did not finish, so the seed finishes it.
  defp unfinished_switch_on?(nil), do: false

  defp unfinished_switch_on?(row) do
    row.status == :draft and row.graph == Definition.graph()
  end

  # The rows of this key in the platform tenant: the row of the seed's own
  # version and the ACTIVE rows (the ones that run).
  defp existing(prefix) do
    case Definitions.list(%{name: Definition.name(), limit: 200}, prefix: prefix) do
      {:ok, rows} ->
        rows = Enum.filter(rows, &(&1.name == Definition.name()))

        same_version = Enum.find(rows, &(&1.version == Definition.version()))
        actives = Enum.filter(rows, &(&1.status == :active))

        {:ok, %{same_version: same_version, actives: actives}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The NEWEST active version: the one that must keep running. A version that
  # cannot be compared counts as the newest, because an unknown version is
  # kept, never replaced.
  defp newest([]), do: nil

  defp newest([row | rest]) do
    Enum.reduce(rest, row, fn candidate, best ->
      if newer?(candidate.version, best.version), do: candidate, else: best
    end)
  end

  defp create_and_activate(prefix, activator) do
    attrs = Definition.attrs() |> Map.put(:created_by, activator.user_id)

    case Definitions.create_with_variable_schemas(attrs, Definition.variable_schemas(),
           prefix: prefix,
           actor_id: activator.user_id
         ) do
      {:ok, draft} ->
        activate(draft, prefix, activator)

      {:error, :duplicate_name_version} ->
        # Another seed won the race: the definition exists, so the seed's own
        # rule applies -- nothing is written.
        {:ok, %{outcome: :already_present, definition: nil, version: Definition.version()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp activate(draft, prefix, activator) do
    with :ok <- open_channels(draft, prefix, activator),
         {:ok, %{definition: definition}} <-
           Definitions.activate(draft.id, prefix: prefix, activator: activator) do
      {:ok, %{outcome: :created, definition: definition, version: definition.version}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The CHANNELS the seeded version uses are opened for the tenant BEFORE the
  # switch-on: a version that cannot send anything is never switched on
  # (T-2597, gap G14 -- the deny-by-default allow-list). Only a channel is
  # opened, never a destination: the recipient domain stays a human decision.
  #
  # A switch-on that then fails for another reason leaves the channel open: a
  # channel alone opens nothing (a send still needs a listed destination), and
  # a channel the seed opened for its own version is not a door it may close
  # again -- the tenant's list belongs to the tenant.
  defp open_channels(draft, prefix, activator) do
    with :ok <- permitted_outbound(activator, prefix),
         {:ok, _channels} <-
           OutboundDestinations.open_channels(prefix, activator.user_id, draft.graph) do
      :ok
    end
  end

  # The seed may open a channel of the allow-list only with the authority of
  # someone who holds the narrow atom (T-2597, gap G14): a seed cannot invent
  # that authority, exactly as it cannot invent `:TenantsManage`.
  #
  # The scope is read from the PREFIX, not assumed: the seed writes to the
  # platform tenant (`prefix/1` refuses any other), and there the atom is a
  # tenant-scope one that the platform administrator holds.
  defp permitted_outbound(activator, prefix) do
    roles = Authorization.roles_from_strings(Map.get(activator, :roles, []))

    if Authorization.has_permission_in_scope?(
         roles,
         :OutboundDestinationsManage,
         PlatformTenant.platform_prefix?(prefix)
       ) do
      :ok
    else
      {:error, :activator_not_permitted}
    end
  end

  # Is the existing version NEWER than the seed's? A version that cannot be
  # compared (a string that is not a plain number) counts as newer: an
  # unknown version is kept, never replaced.
  defp newer?(existing, seed_version) do
    case {parse_version(existing), parse_version(seed_version)} do
      {{:ok, existing_number}, {:ok, seed_number}} -> existing_number > seed_number
      _not_comparable -> true
    end
  end

  defp parse_version(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp parse_version(_other), do: :error
end
