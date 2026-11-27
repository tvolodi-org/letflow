defmodule Letflow.PlatformFunctions.Catalog do
  @moduledoc """
  The COMPILED platform function catalogue (T-2588, gap G2 of the "Register a
  tenant" pilot; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (a)).

  The list of platform functions a definition may call exists only if it is
  compiled into the build: the same shape as `Letflow.Modules.Catalog`, read
  once at compile time via `Application.compile_env/3`. There is NO write
  route and no run-time registration: who may add an entry is whoever may
  merge code (review, tests, CI); designers and administrators only CHOOSE
  entries (`platform_catalogue_has_no_write_route_test` pins the absence of a
  write path).

  ## Source of the entry list

  `config :letflow, :platform_functions` names the modules that declare
  entries. Each such module exposes `entries/0`, a list of
  `Letflow.PlatformFunctions.Entry` structs. The core declares the platform
  family (`Letflow.PlatformFunctions.TenantFamily`); a module may declare its
  own family later.

  ## The module family (D-204)

  A module's functions are NOT declared by hand: they are DERIVED at compile
  time from the module's own write-handler registration
  (`Letflow.PlatformFunctions.ModuleFamily`), so `config :letflow,
  :platform_functions` needs no new entry per module and the catalogue reads
  the module families from `Letflow.Modules.Catalog`.

  A module family entry carries `family: "<module id>"` and
  `platform_tenant_only: false`: it runs where the module is INSTALLED, not in
  the platform tenant only (see
  `Letflow.PlatformFunctions.ModuleTenantRule`).

  ## What a caller may see

  `list/1` shows only the entries the CALLER's tenant may use: an entry marked
  `platform_tenant_only` (the platform family) is visible only in the platform
  tenant (INV-10). A company tenant sees the empty list for that family, so
  the read route cannot be used to probe which platform functions exist.

  The MODULE family is not hidden the way the platform family is: a module's
  functions are the module's own, and the module id is public (a tenant
  installs modules itself). But "visible" here means what `list/1` FILTERS, not
  who may call the read route: the one production caller of `list/1` is
  `GET /platform-functions`, whose policy `:TenantsManage` is PLATFORM scope,
  so in practice a company tenant's designer CANNOT yet pick a module family
  entry. The exposure is narrower than the filter, and it fails closed. Making
  the module family reachable for a company tenant is a P3 question (the
  module-call authority), not a property of this catalogue.

  ## Compile-time checks

  A duplicate entry name or a malformed entry (a missing permission, an
  unknown source class) is a COMPILE error, not a run-time surprise: the
  catalogue is code, and code that does not compile does not ship. The checks
  run in the module body, which Elixir executes while compiling the module.
  """

  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.ModuleFamily

  # ── the catalogue itself ─────────────────────────────────────────────────────────────────

  @entry_modules Application.compile_env(:letflow, :platform_functions, [])

  # D-204: the module family is DERIVED from the compiled modules' own write
  # handlers, never written by hand. A module that has not been converted
  # contributes nothing (its handlers declare no permission), so the catalogue
  # of a build without a converted module is the catalogue it was before.
  #
  # A refusal here is a COMPILE error: the catalogue is code, and code that
  # does not compile does not ship. The derivation itself never raises (it
  # answers with a code out of `Letflow.PlatformFunctions.ModuleFamily.codes/0`).
  @module_entries (case ModuleFamily.entries() do
                     {:ok, entries} ->
                       entries

                     {:error, code} ->
                       raise "module family entries could not be derived: #{inspect(code)}"
                   end)

  @entries (@entry_modules |> Enum.flat_map(& &1.entries())) ++ @module_entries

  # T-2727: the entries are read at COMPILE time from modules named in the configuration, so Mix
  # records no compile-time dependency on them. Without these resources a new entry in a family
  # module leaves this module's compiled list stale on an incremental build, and the registry's
  # compile check refuses the new body ("not declared in the compiled catalogue").
  for module <- @entry_modules do
    @external_resource module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
  end

  # The same rule for the MODULE FAMILY: the derivation reads the compiled
  # modules' own manifests, so a change of one of them (a new handler, a new
  # permission) must recompile this catalogue.
  for module <- ModuleFamily.source_modules() do
    @external_resource module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
  end

  @entry_map Map.new(@entries, &{&1.name, &1})

  @permission_atoms @entries
                    |> Enum.map(& &1.permission)
                    |> Enum.uniq()
                    |> Enum.sort()

  Letflow.PlatformFunctions.Entry.validate_catalogue!(@entries)

  @doc """
  The entries the caller's tenant may use, sorted by name.

  `opts[:platform_tenant?]` says whether the caller is in the platform
  tenant; a `platform_tenant_only` entry is hidden from everyone else.
  """
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) when is_list(opts) do
    platform_tenant? = Keyword.get(opts, :platform_tenant?, false) == true

    @entry_map
    |> Map.values()
    |> Enum.filter(fn entry -> not entry.platform_tenant_only or platform_tenant? end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The entry named `name`, or `{:error, :not_found}`. The one lookup the
  activation fence and the dispatch guard use.
  """
  @spec fetch(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def fetch(name) when is_binary(name) do
    case Map.fetch(@entry_map, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  The permission atoms the compiled catalogue names. The activator evaluates
  exactly these, so the signed `activated_by` document can carry the entry's
  permission without recording every permission the caller holds.
  """
  @spec permission_atoms() :: [atom()]
  def permission_atoms, do: @permission_atoms

  @doc """
  The names of the compiled entries, sorted. For the catalogue's own test and
  for the designer's picker.
  """
  @spec names() :: [String.t()]
  def names, do: @entry_map |> Map.keys() |> Enum.sort()

  @doc """
  The entry map of a catalogue, as plain data for a response body. No atom
  leaks: the permission is a string and the source classes are strings.

  The key composition of an entry is published under `idempotency_inputs` --
  the INPUT NAMES that make a repeat the same call -- and not under the name
  of the CALLER's idempotency key: that key belongs to `Letflow.Idempotency`
  alone (the AC5 guard scans every source file for it), and a catalogue entry
  must not look like one.
  """
  @spec entry_map(Entry.t()) :: map()
  def entry_map(%Entry{} = entry) do
    %{
      "name" => entry.name,
      "family" => to_string(entry.family),
      "version" => entry.version,
      "permission" => to_string(entry.permission),
      "platform_tenant_only" => entry.platform_tenant_only,
      "idempotency_inputs" => entry.idempotency_key,
      "inputs" =>
        Enum.map(entry.inputs, fn input ->
          %{
            "name" => input.name,
            "type" => to_string(input.type),
            "required" => input.required,
            "source_class" => to_string(input.source_class)
          }
        end),
      "outputs" =>
        Enum.map(entry.outputs, fn output ->
          %{"name" => output.name, "type" => to_string(output.type)}
        end),
      "side_effects" =>
        Enum.map(entry.side_effects, fn effect ->
          %{"text" => effect.text, "class" => to_string(effect.class)}
        end)
    }
  end
end
