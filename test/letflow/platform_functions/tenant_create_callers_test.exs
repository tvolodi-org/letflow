defmodule Letflow.PlatformFunctions.TenantCreateCallersTest do
  @moduledoc """
  The NO BYPASS rule of the "Register a tenant" pilot (T-2605, gap G17 of the
  spike `project/pilot-register-tenant-design.md`, section 2.j): the functions
  that CREATE a tenant and the functions that PROVISION one have a closed set
  of callers.

  A pure AST scan over `lib/**/*.ex` (`test/**` is excluded: test bodies forge
  a tenant on purpose), the same shape and the same accepted limits as the
  sibling caller scans (`test/letflow/ledger/credential_callers_test.exs`,
  `test/letflow/entities/handler_writes_callers_test.exs`). Each rule is a
  pure function over source text; the real-tree test and the synthetic
  non-vacuity tests run the SAME function.

  ## The rule

  The tenant row and the tenant schema are written by TWO functions only:

    * `Letflow.Identity.create_tenant/1` -- the tenant ROW,
    * `Letflow.Identity.create_provisioned_tenant/1` -- the tenant ROW of the
      portfolio provisioner,
    * `Letflow.TenantOnboarding.provision_and_migrate/1` -- the tenant SCHEMA
      (the DDL, the migrations, the roles).

  Their callers are closed:

    * the platform step's catalogue body (`tenant.create` and
      `tenant.provision`, the entries of the compiled catalogue that the
      definition's steps call),
    * the module they delegate to (`Letflow.TenantProvisioner`),
    * the seed task (`mix letflow.seed`), which creates the PLATFORM tenant
      before any definition can exist.

  ## What the scan does NOT do (and what the next slice must change)

  The four ROUTES that create a tenant today reach the row through the
  catalogue body's PUBLIC wrapper (`TenantCreate.create_tenant/1` and
  `TenantProvision.provision_and_migrate/1`) or through the provisioner chain
  (`TenantProvisioner.create/1`). Those three entries are listed in
  `@bypass_rules` and are asserted EXACTLY: the set of files that may call
  them is pinned, so the set can only SHRINK. The rewiring task of gap G17
  removes the four route entries from that pinned set and THEN adds the
  "every route starts an instance" test; the scan names the file that changed.

  The reason the entries are still there: the ENGINE does not run a platform
  step yet (nothing in `lib/letflow/engine.ex` arms a
  `platform_step_dispatches` row, so a definition with a `platform_call` node
  cannot be started at all). Rewiring the routes before the engine runs the
  step would answer `202` and create no tenant at all, which is why the
  rewiring waits for that piece.

  Accepted limits, as in the siblings: computed function names, `Code.eval_*`,
  macros defined away from the call site, `%__MODULE__{}` forms and
  dependencies are not seen.
  """

  use ExUnit.Case, async: true

  # The catalogue bodies of the tenant family (the steps of the definition).
  @tenant_create_impl "lib/letflow/platform_functions/impl/tenant_create.ex"
  @tenant_provision_impl "lib/letflow/platform_functions/impl/tenant_provision.ex"

  # The module the catalogue bodies delegate to.
  @provisioner_file "lib/letflow/tenant_provisioner.ex"

  # The seed task: it creates the platform tenant itself, before any
  # definition can exist, and Mix tasks are not part of the release.
  @seed_task "lib/mix/tasks/letflow.seed.ex"

  # The routes that still reach the write (the remaining bypass).
  @tenants_router "lib/letflow/routers/tenants.ex"
  @onboarding_router "lib/letflow/routers/onboarding.ex"
  @admin_router "lib/letflow/routers/admin_v1.ex"
  @signup_provisioning "lib/letflow/signup/provisioning.ex"

  # The rule: who may call the functions that write a tenant row or a tenant
  # schema. {module, function, allowed files}.
  @rules [
    {[:Letflow, :Identity], :create_tenant, [@tenant_create_impl, @seed_task]},
    {[:Letflow, :Identity], :create_provisioned_tenant, [@provisioner_file]},
    {[:Letflow, :TenantOnboarding], :provision_and_migrate, [@tenant_provision_impl, @seed_task]}
  ]

  # The catalogue body's public wrappers and the provisioner chain: the routes
  # reach the write through these. The set is pinned exactly, so it can only
  # shrink: the rewiring task of gap G17 removes the four route entries from
  # it and THEN adds the "every route starts an instance" test.
  @bypass_rules [
    {[:Letflow, :PlatformFunctions, :Impl, :TenantCreate], :create_tenant,
     [@tenants_router, @onboarding_router]},
    {[:Letflow, :PlatformFunctions, :Impl, :TenantProvision], :provision_and_migrate,
     [
       @tenants_router,
       @onboarding_router,
       @provisioner_file
     ]},
    {[:Letflow, :TenantProvisioner], :create, [@admin_router, @signup_provisioning]}
  ]

  setup_all do
    {:ok, files: sources()}
  end

  defp scanned_files, do: Path.wildcard("lib/**/*.ex") |> Enum.sort()

  defp sources, do: for(path <- scanned_files(), do: {path, File.read!(path)})

  defp parse(source), do: Code.string_to_quoted!(source, columns: false)

  # The alias map of one file: the LOCAL name -> the full module path. A file
  # that calls `Identity.create_tenant/1` has aliased `Letflow.Identity`, so
  # the map is what tells the two apart.
  defp alias_map(source) do
    {_ast, aliases} =
      source
      |> parse()
      |> Macro.prewalk([], fn
        {:alias, _, [module]} = node, acc ->
          parts = module_parts(module)
          {node, [{List.last(parts), parts} | acc]}

        {:alias, _, [module, opts]} = node, acc when is_list(opts) ->
          parts = module_parts(module)

          local =
            case Keyword.fetch(opts, :as) do
              {:ok, as} -> as
              :error -> List.last(parts)
            end

          {node, [{local, parts} | acc]}

        node, acc ->
          {node, acc}
      end)

    Map.new(aliases)
  end

  defp module_parts({:__aliases__, _, parts}), do: parts
  defp module_parts({:__aliases__, _, head, tail}), do: [head | tail]
  defp module_parts(other), do: [other]

  # Every remote call in the file: {resolved module parts, function name, line}.
  # A local call (`create_tenant(attrs)` inside the module that defines it) is
  # not a call site of the rule: the rule names a MODULE and a function.
  defp call_sites(source) do
    aliases = alias_map(source)

    {_ast, sites} =
      source
      |> parse()
      |> Macro.prewalk([], fn
        {{:., meta, [receiver, fun]}, _call_meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          case module_parts_of(receiver) do
            nil -> {node, acc}
            parts -> {node, [{resolve(parts, aliases), fun, line(meta)} | acc]}
          end

        # `apply(Identity, :create_tenant, [attrs])`
        {:apply, meta, [receiver, fun, _args]} = node, acc when is_atom(fun) ->
          case module_parts_of(receiver) do
            nil -> {node, acc}
            parts -> {node, [{resolve(parts, aliases), fun, line(meta)} | acc]}
          end

        # `&Identity.create_tenant/1`
        {:&, _, [{:/, _, [{{:., _, [receiver, fun]}, _, []}, _arity]}]} = node, acc
        when is_atom(fun) ->
          case module_parts_of(receiver) do
            nil -> {node, acc}
            parts -> {node, [{resolve(parts, aliases), fun, 0} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  # The module parts of a call's receiver: nil when the receiver is not a
  # module (a variable, an atom).
  defp module_parts_of({:__aliases__, _, parts}), do: parts
  defp module_parts_of({:__aliases__, _, head, tail}), do: [head | tail]
  defp module_parts_of(_other), do: nil

  # The full module path of a call: the alias map first (the local name), the
  # written path otherwise (a fully qualified call).
  defp resolve([local | rest], aliases) do
    case Map.fetch(aliases, local) do
      {:ok, full} -> full ++ rest
      :error -> [local | rest]
    end
  end

  defp resolve(parts, _aliases), do: parts

  defp line(meta), do: Keyword.get(meta, :line, 0)

  # The files that call {module, function} and are not allowed to.
  defp offenders(files, module, function, allowed) do
    for {path, source} <- files,
        path not in allowed,
        {^module, ^function, _line} <- call_sites(source),
        do: path,
        uniq: true
  end

  # The files that call {module, function}, allowed or not.
  defp callers(files, module, function) do
    for {path, source} <- files,
        {^module, ^function, _line} <- call_sites(source),
        do: path,
        uniq: true
  end

  describe "real tree" do
    test "the scan set is non-trivial and carries the definers", %{files: files} do
      paths = Enum.map(files, &elem(&1, 0))
      assert length(paths) > 100

      for path <- [
            @tenant_create_impl,
            @tenant_provision_impl,
            @provisioner_file,
            @seed_task,
            @tenants_router,
            @onboarding_router
          ] do
        assert path in paths, path
      end
    end

    test "the tenant row and the tenant schema are written only by the step, the provisioner and the seed",
         %{files: files} do
      for {module, function, allowed} <- @rules do
        assert offenders(files, module, function, allowed) == [],
               "#{inspect(module)}.#{function} has a caller outside #{inspect(allowed)}"
      end

      # positive controls: the allowed callers really do call them
      assert @tenant_create_impl in callers(files, [:Letflow, :Identity], :create_tenant)
      assert @seed_task in callers(files, [:Letflow, :Identity], :create_tenant)

      assert @provisioner_file in callers(
               files,
               [:Letflow, :Identity],
               :create_provisioned_tenant
             )

      assert @tenant_provision_impl in callers(
               files,
               [:Letflow, :TenantOnboarding],
               :provision_and_migrate
             )

      assert @seed_task in callers(files, [:Letflow, :TenantOnboarding], :provision_and_migrate)
    end

    test "the remaining bypass is pinned exactly: the set of callers may only shrink", %{
      files: files
    } do
      for {module, function, allowed} <- @bypass_rules do
        found = Enum.sort(callers(files, module, function))

        assert found == Enum.sort(allowed),
               "#{inspect(module)}.#{function} is called from #{inspect(found)}"

        assert offenders(files, module, function, allowed) == [],
               "#{inspect(module)}.#{function} has a caller outside #{inspect(allowed)}"
      end
    end

    test "no other file in lib/ reaches the tenant row", %{files: files} do
      # every caller of the row writer, wherever it is, is one of the two
      for path <- callers(files, [:Letflow, :Identity], :create_tenant) do
        assert path in [@tenant_create_impl, @seed_task], path
      end
    end
  end

  describe "non-vacuity on synthetic sources" do
    test "a rogue caller is flagged, whatever the call form" do
      files = [
        {"lib/rogue.ex",
         "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: Identity.create_tenant(a)\nend"},
        {"lib/rogue.ex",
         "defmodule Rogue do\n  def f(a), do: Letflow.Identity.create_tenant(a)\nend"},
        {"lib/rogue.ex",
         "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: apply(Identity, :create_tenant, [a])\nend"},
        {"lib/rogue.ex",
         "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: &Identity.create_tenant/1\nend"}
      ]

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "an alias is resolved, so a different module of the same last name is not flagged" do
      files = [
        {"lib/other.ex",
         "defmodule Other do\n  alias My.Identity\n  def f(a), do: Identity.create_tenant(a)\nend"}
      ]

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end

    test "a doc mention and a definition are not call sites" do
      files = [
        {"lib/rogue.ex",
         "defmodule Rogue do\n  @moduledoc \"see Identity.create_tenant/1\"\n  @spec create_tenant(term()) :: term()\n  def create_tenant(a), do: a\nend"}
      ]

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end
  end
end
