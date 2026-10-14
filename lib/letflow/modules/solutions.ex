defmodule Letflow.Modules.Solutions do
  @moduledoc """
  Solution install context (REQ-415, decision
  `docs/migration/decisions/0039-platform-module-solution-layering.md` D6).

  ## File placement (D3)

  `lib/letflow/modules/solutions.ex`, one level, no subdirectory — core
  mechanism file (fifth in the D3 core layer alongside `catalog.ex`,
  `installs.ex`, `module.ex`, and `tenant_module.ex`). This file must NOT
  reference any concrete module by name — solution entries are resolved
  through `Letflow.Modules.Catalog.fetch/1` at runtime; only D3-permitted
  `catalog.ex` is allowed to name concrete module atoms.

  ## What a solution is (D6)

  A solution is a JSON document in `priv/solutions/<id>.json` that lists an
  ordered set of platform modules plus their desired default settings. Its
  purpose is to install a coherent bundle of modules in one atomic operation,
  in dependency order, with default settings applied after all installs
  succeed.

  No new table is needed: the solution file is a static build artefact, not
  a runtime-mutable entity (D6 explicitly forbids a `solutions` table). Only
  `tenant_modules` rows are written, via the existing
  `Letflow.Modules.Installs.install/3` and `put_settings/3`.

  ## Tenant scoping (INV-1)

  The tenant is identified ONLY by `opts[:prefix]`, threaded from
  `conn.assigns.scoped_opts` in the HTTP layer — never from a body field or
  path parameter.

  ## Atomicity

  `install/3` wraps all module installs and settings writes in ONE
  `Repo.transaction/1`. If any module install fails (including the second
  module while the first already succeeded), the whole transaction is rolled
  back, leaving no `tenant_modules` rows for any of the solution's modules.
  Nested transactions via savepoints (Ecto's default for nested
  `Repo.transaction` calls) preserve this guarantee.

  ## Dependency ordering

  Modules within the solution are installed in topological order derived from
  each module's `manifest().depends_on`. Only intra-solution dependencies
  drive the sort; a dependency on a module NOT in the solution is assumed to
  be pre-installed (and will be checked by `Installs.install/3` itself, which
  returns `{:error, {:dependency_not_installed, dep_id}}` if absent).
  """

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Repo

  @typedoc "One module entry inside a solution document."
  @type solution_module :: %{
          module_id: String.t(),
          version: String.t(),
          settings: map()
        }

  @typedoc "A parsed, validated solution document."
  @type solution :: %{
          id: String.t(),
          modules: [solution_module()]
        }

  # Only lower-case alphanumeric, underscore, and hyphen — prevents path traversal.
  @id_regex ~r/^[a-z0-9_-]+$/

  @doc """
  Reads and validates `priv/solutions/<solution_id>.json`.

  Validation order:
  1. `solution_id` must match `^[a-z0-9_-]+$` — returns `{:error, :not_found}`
     if it doesn't (treats path-traversal attempts and unknown uppercase ids
     identically so no information is leaked about what exists on disk).
  2. File must exist at `priv/solutions/<id>.json` —
     `{:error, :not_found}` when absent.
  3. Every `module_id` in the modules list must be a Catalog module —
     `{:error, {:unknown_module, id}}`.
  4. Every `version` must match the Catalog module's manifest version —
     `{:error, {:version_mismatch, id, expected, given}}`.

  Returns `{:ok, solution()}` on success.
  """
  @spec load(String.t()) :: {:ok, solution()} | {:error, term()}
  def load(solution_id) when is_binary(solution_id) do
    if String.match?(solution_id, @id_regex) do
      path =
        Path.join(
          Application.app_dir(:letflow, "priv"),
          "solutions/#{solution_id}.json"
        )

      case File.read(path) do
        {:ok, contents} ->
          with {:ok, data} <- Jason.decode(contents),
               :ok <- validate_solution_modules(data["modules"]) do
            {:ok,
             %{
               id: data["id"],
               modules:
                 Enum.map(data["modules"], fn m ->
                   %{
                     module_id: m["module_id"],
                     version: m["version"],
                     settings: m["settings"] || %{}
                   }
                 end)
             }}
          end

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Installs the solution identified by `solution_id` into the tenant identified
  by `opts[:prefix]`, acting as `actor_id`.

  All installs and default-settings writes happen in ONE `Repo.transaction/1`.
  If any step fails, the entire transaction is rolled back.

  Error returns:
  - `{:error, :rationale_required}` — `opts[:rationale]` missing, non-string or blank
    (decision 0052 D3); nothing is read or written.
  - `{:error, :not_found}` — solution file absent or id fails validation.
  - `{:error, {:unknown_module, id}}` — solution references an unregistered module.
  - `{:error, {:version_mismatch, id, expected, given}}` — solution's version
    doesn't match the registered module's manifest version.
  - `{:error, {:already_installed, module_id}}` — one or more modules in the
    solution are already installed in the tenant; the whole solution is refused
    (D7 forbids silently replacing existing settings).
  - Any error from `Letflow.Modules.Installs.install/3` or `put_settings/3`
    if an individual module install or settings write fails.

  Returns `{:ok, [TenantModule.t()]}` with one entry per installed module, in
  the order they were installed (dependency order).
  """
  @spec install(String.t(), term(), keyword()) ::
          {:ok, [Letflow.Modules.TenantModule.t()]} | {:error, term()}
  def install(solution_id, actor_id, opts \\ []) do
    # Decision 0052 D3: one installer-supplied rationale, checked before anything is
    # read or written, then passed unchanged (in `opts`) to every Installs.install/3.
    with {:ok, _rationale} <- Installs.fetch_rationale(opts),
         {:ok, solution} <- load(solution_id) do
      prefix = Keyword.fetch!(opts, :prefix)

      Repo.transaction(fn ->
        with :ok <- check_none_already_installed(solution.modules, prefix),
             sorted = topo_sort(solution.modules),
             {:ok, tenant_modules} <- install_all(sorted, actor_id, opts),
             :ok <- apply_all_settings(sorted, opts) do
          tenant_modules
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # ── Validation ────────────────────────────────────────────────────────────

  @spec validate_solution_modules(term()) :: :ok | {:error, term()}
  defp validate_solution_modules(modules) when is_list(modules) do
    Enum.reduce_while(modules, :ok, fn
      %{"module_id" => module_id, "version" => given_version}, :ok ->
        case Catalog.fetch(module_id) do
          {:error, :not_found} ->
            {:halt, {:error, {:unknown_module, module_id}}}

          {:ok, entry_module} ->
            expected_version = entry_module.manifest().version

            if expected_version == given_version do
              {:cont, :ok}
            else
              {:halt, {:error, {:version_mismatch, module_id, expected_version, given_version}}}
            end
        end

      _, :ok ->
        {:halt, {:error, :invalid_format}}
    end)
  end

  defp validate_solution_modules(_), do: {:error, :invalid_format}

  # ── Install helpers ────────────────────────────────────────────────────────

  @spec check_none_already_installed([solution_module()], String.t()) ::
          :ok | {:error, {:already_installed, String.t()}}
  defp check_none_already_installed(module_entries, prefix) do
    Enum.reduce_while(module_entries, :ok, fn module_entry, :ok ->
      if Installs.installed?(module_entry.module_id, prefix: prefix) do
        {:halt, {:error, {:already_installed, module_entry.module_id}}}
      else
        {:cont, :ok}
      end
    end)
  end

  @spec install_all([solution_module()], term(), keyword()) ::
          {:ok, [Letflow.Modules.TenantModule.t()]} | {:error, term()}
  defp install_all(sorted_modules, actor_id, opts) do
    Enum.reduce_while(sorted_modules, {:ok, []}, fn module_entry, {:ok, acc} ->
      case Installs.install(module_entry.module_id, actor_id, opts) do
        {:ok, tm} -> {:cont, {:ok, [tm | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  @spec apply_all_settings([solution_module()], keyword()) :: :ok | {:error, term()}
  defp apply_all_settings(sorted_modules, opts) do
    prefix = opts[:prefix]

    Enum.reduce_while(sorted_modules, :ok, fn module_entry, :ok ->
      case Installs.put_settings(module_entry.module_id, module_entry.settings, prefix: prefix) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ── Topological sort ───────────────────────────────────────────────────────

  # Sorts `module_entries` so that if module B's `manifest().depends_on`
  # includes module A — and A is also in this solution — A comes before B.
  # Dependencies on modules NOT in the solution are ignored here (those are
  # checked at runtime by `Installs.install/3`'s own dependency gate).
  @spec topo_sort([solution_module()]) :: [solution_module()]
  defp topo_sort(module_entries) do
    solution_ids = MapSet.new(module_entries, & &1.module_id)
    do_topo_sort(module_entries, MapSet.new(), [], solution_ids)
  end

  @spec do_topo_sort([solution_module()], MapSet.t(), [solution_module()], MapSet.t()) ::
          [solution_module()]
  defp do_topo_sort([], _placed, sorted, _solution_ids), do: sorted

  defp do_topo_sort(remaining, placed, sorted, solution_ids) do
    {ready, not_ready} =
      Enum.split_with(remaining, fn entry ->
        intra_deps =
          case Catalog.fetch(entry.module_id) do
            {:ok, m} ->
              Enum.filter(m.manifest().depends_on, &MapSet.member?(solution_ids, &1))

            _ ->
              []
          end

        Enum.all?(intra_deps, &MapSet.member?(placed, &1))
      end)

    case ready do
      [] ->
        # Circular or irresolvable — append remaining in original order rather
        # than looping forever. `load/1`'s Catalog validation should prevent
        # this; reaching here is a programmer error.
        sorted ++ remaining

      _ ->
        new_placed =
          Enum.reduce(ready, placed, fn entry, acc -> MapSet.put(acc, entry.module_id) end)

        do_topo_sort(not_ready, new_placed, sorted ++ ready, solution_ids)
    end
  end
end
