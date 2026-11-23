defmodule Letflow.PlatformFunctions.TenantCreateCallersTest do
  @moduledoc """
  The NO BYPASS rule of the "Register a tenant" pilot (T-2605, gap G17 of the
  spike `project/pilot-register-tenant-design.md`, section 2.j): the functions
  that CREATE a tenant and the functions that PROVISION one have a closed set
  of callers.

  A pure AST scan over `lib/**/*.ex` (`test/**` is excluded: test bodies forge
  a tenant on purpose), in the shape of the sibling caller scans
  (`test/letflow/ledger/credential_callers_test.exs`,
  `test/letflow/entities/handler_writes_callers_test.exs`). Each rule is a
  pure function over source text; the real-tree test and the synthetic
  non-vacuity tests run the SAME function.

  ## The rule

  The tenant row and the tenant schema are written by FOUR public functions:

    * `Letflow.Identity.create_tenant/1` -- the tenant ROW,
    * `Letflow.Identity.create_provisioned_tenant/1` -- the tenant ROW of the
      portfolio provisioner,
    * `Letflow.TenantOnboarding.provision_and_migrate/1` -- the tenant SCHEMA
      (the DDL, the migrations, the roles),
    * `Letflow.TenantOnboarding.recover_provisioning/1` -- the AC9 recovery
      entry point, a second PUBLIC NAME for the same schema write. A caller of
      it is a caller of the write, so it carries the same allowed set.

  Their callers are closed:

    * the platform step's catalogue body (`tenant.create` and
      `tenant.provision`, the entries of the compiled catalogue that the
      definition's steps call),
    * the module they delegate to (`Letflow.TenantProvisioner`),
    * the seed task (`mix letflow.seed`), which creates the PLATFORM tenant
      before any definition can exist.

  ## The call forms the scan resolves

  The scan reads the AST, so it resolves every form the parser produces. A
  caller that hid behind a form would land with the pin green, which is the
  one thing this control must not allow:

    * `alias Letflow.Identity` -- the plain alias,
    * `alias Letflow.Identity, as: I` -- the RENAMED alias: the `as:` value
      arrives as an AST node (`{:__aliases__, _, [:I]}`), not as the atom `:I`,
    * `alias Letflow.{Audit, Identity}` -- the MULTI alias: one entry per
      member, each expanded with the base,
    * `alias Letflow.Identity.{User, Role}` -- the multi alias over a nested
      base,
    * a fully qualified call (`Letflow.Identity.create_tenant/1`),
    * `apply(Identity, :create_tenant, [attrs])`,
    * `&Identity.create_tenant/1`,
    * `import Letflow.Identity` -- an IMPORT puts the function in scope
      unqualified, so a local `create_tenant(attrs)` is that module's call.

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

  ## Accepted limits

  These are the forms the scan does NOT see, stated so that no reader
  overstates the closure:

    * a COMPUTED module name (`mod = Identity; mod.create_tenant(attrs)`) --
      the receiver is a variable, not a module,
    * `apply/3` with a computed module,
    * `Code.eval_*` and any other compile-time evaluation,
    * a MACRO that expands into the call (defined in another module, so the
      expansion is not in this file's AST),
    * an `alias` or an `import` written through a macro (`alias unquote(mod)`),
    * an `import` of a computed module.

  Everything else that names the module in the source IS seen, in every alias
  form the parser produces.
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
    {[:Letflow, :TenantOnboarding], :provision_and_migrate, [@tenant_provision_impl, @seed_task]},
    # AC9's recovery entry point is a second public name for the SAME schema
    # write, so it carries the SAME allowed set: a caller of either is a
    # caller of the write.
    {[:Letflow, :TenantOnboarding], :recover_provisioning, [@tenant_provision_impl, @seed_task]}
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

  # The modules the rules watch. An IMPORT of one of them brings its
  # functions into scope unqualified, so a local call is that module's call.
  @watched [
    [:Letflow, :Identity],
    [:Letflow, :TenantOnboarding],
    [:Letflow, :PlatformFunctions, :Impl, :TenantCreate],
    [:Letflow, :PlatformFunctions, :Impl, :TenantProvision],
    [:Letflow, :TenantProvisioner]
  ]

  # The function names the rules name. Only a local call with one of these
  # names can be an imported call of a watched module, so the scan does not
  # report the AST nodes that merely look like a call.
  @watched_functions for({_, function, _} <- @rules ++ @bypass_rules, do: function) |> Enum.uniq()

  setup_all do
    {:ok, files: sources()}
  end

  defp scanned_files, do: Path.wildcard("lib/**/*.ex") |> Enum.sort()

  # One scan per file, computed ONCE: the file's alias map, the watched
  # modules it imports and every call site in it.
  defp sources do
    for path <- scanned_files() do
      source = File.read!(path)
      {path, source, scan(source)}
    end
  end

  # The synthetic sources of the non-vacuity tests, in the same shape the
  # real-tree scan uses, so that `offenders/4` reads one kind of input.
  defp fake_files(entries) do
    for {path, source} <- entries, do: {path, source, scan(source)}
  end

  defp parse(source), do: Code.string_to_quoted!(source, columns: false)

  # Everything the scan needs from one file.
  defp scan(source) do
    ast = parse(source)
    aliases = alias_map(ast)
    imports = import_map(ast, aliases)
    defined = defined_functions(ast)

    %{
      aliases: aliases,
      imports: imports,
      defined: defined,
      sites: call_sites(ast, aliases, imports, defined)
    }
  end

  # The alias map of one file: the LOCAL name -> the full module path. A file
  # that calls `Identity.create_tenant/1` has aliased `Letflow.Identity`, so
  # the map is what tells the two apart.
  #
  # Every alias FORM the parser produces is resolved:
  #
  #   alias Letflow.Identity          -> Identity => [:Letflow, :Identity]
  #   alias Letflow.Identity, as: I   -> I       => [:Letflow, :Identity]
  #   alias Letflow.{Audit, Identity} -> Audit   => [:Letflow, :Audit]
  #                                     Identity => [:Letflow, :Identity]
  #   alias Letflow.Identity.{User, Role}
  #                                   -> User    => [:Letflow, :Identity, :User]
  defp alias_map(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, [], fn
        {:alias, _, [module]} = node, acc ->
          {node, alias_entries(module) ++ acc}

        {:alias, _, [module, opts]} = node, acc when is_list(opts) ->
          parts = module_parts(module)

          local =
            case Keyword.fetch(opts, :as) do
              {:ok, as} -> local_name(as)
              :error -> List.last(parts)
            end

          {node, [{local, parts} | acc]}

        node, acc ->
          {node, acc}
      end)

    Map.new(aliases)
  end

  # The entries of ONE alias node. A plain alias is one entry; a multi-alias
  # (`alias A.{B, C}`) is one entry per member, each expanded with the base.
  defp alias_entries({{:., _, [base, :{}]}, _, members}) do
    base_parts = module_parts(base)

    for member <- members do
      parts = base_parts ++ module_parts(member)
      {List.last(parts), parts}
    end
  end

  defp alias_entries({:__aliases__, _, _} = module) do
    parts = module_parts(module)
    [{List.last(parts), parts}]
  end

  # An alias node the scan does not understand (a macro in the alias
  # position): nothing is resolved, and the accepted limits say so.
  defp alias_entries(_other), do: []

  # The local name of an `as:` option. The parser hands it over as an AST
  # node (`{:__aliases__, _, [:I]}`), not as the atom `:I`, so both forms are
  # accepted.
  defp local_name({:__aliases__, _, parts}), do: List.last(parts)
  defp local_name({:__aliases__, _, head, tail}), do: List.last([head | tail])
  defp local_name(name) when is_atom(name), do: name

  # The modules a file IMPORTS, with the functions that are in scope
  # unqualified: {module parts} -> :all | {:only, pairs} | {:except, pairs}.
  # Only the watched modules are kept: an import of any other module cannot
  # name a guarded function.
  defp import_map(ast, aliases) do
    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _, [module]} = node, acc ->
          {node, [import_entry(resolve(module_parts(module), aliases), :all) | acc]}

        {:import, _, [module, opts]} = node, acc when is_list(opts) ->
          scope =
            case Keyword.fetch(opts, :only) do
              {:ok, pairs} -> {:only, pairs}
              :error -> {:except, Keyword.get(opts, :except, [])}
            end

          {node, [import_entry(resolve(module_parts(module), aliases), scope) | acc]}

        node, acc ->
          {node, acc}
      end)

    Map.new(Enum.reject(imports, &is_nil/1))
  end

  # An import entry, kept only for a watched module.
  defp import_entry(parts, scope) do
    if parts in @watched, do: {parts, scope}, else: nil
  end

  # The functions a file DEFINES: {name, arity}. A local call to one of them
  # is that local function and never an imported one (Elixir refuses to
  # compile a file that imports a name it defines), so the definition head is
  # not a call site either.
  defp defined_functions(ast) do
    {_ast, defined} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head | _]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          case head_name_arity(head) do
            nil -> {node, acc}
            pair -> {node, [pair | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    MapSet.new(defined)
  end

  # The name and the arity of a definition head, a guard included.
  defp head_name_arity({:when, _, [head | _]}), do: head_name_arity(head)

  defp head_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp head_name_arity(_other), do: nil

  # Every call in the file: {resolved module parts, function name, line}.
  # A local call (`create_tenant(attrs)` inside the module that defines it) is
  # not a call site of the rule: the rule names a MODULE and a function.
  defp call_sites(ast, aliases, imports, defined) do
    {_ast, sites} =
      Macro.prewalk(ast, [], fn
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

        # `&create_tenant/1` -- the capture of an IMPORTED function.
        {:&, _, [{:/, _, [{name, _, nil}, arity]}]} = node, acc
        when is_atom(name) and is_integer(arity) ->
          case imported_call(imports, defined, name, arity) do
            nil -> {node, acc}
            parts -> {node, [{parts, name, 0} | acc]}
          end

        # A LOCAL call in a file that IMPORTS a watched module: the import
        # puts the function in scope unqualified, so the call names the
        # imported module's function.
        {name, meta, args} = node, acc
        when is_atom(name) and is_list(meta) and is_list(args) ->
          arity = call_arity(args)

          if {name, arity} in defined do
            {node, acc}
          else
            case imported_call(imports, defined, name, arity) do
              nil -> {node, acc}
              parts -> {node, [{parts, name, line(meta)} | acc]}
            end
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  # The watched module an unqualified call names, when the file imports one,
  # the function is in scope there and the name is one the rules watch: nil
  # when it names none.
  defp imported_call(imports, defined, name, arity) do
    if name not in @watched_functions or {name, arity} in defined do
      nil
    else
      Enum.find_value(imports, fn
        {parts, :all} -> parts
        {parts, {:only, pairs}} -> if({name, arity} in pairs, do: parts)
        {parts, {:except, pairs}} -> if({name, arity} not in pairs, do: parts)
      end)
    end
  end

  # The arity of a call: a `do` block is not an argument.
  defp call_arity(args) do
    case List.last(args) do
      [{key, _} | _] when key in [:do, :else] -> length(args) - 1
      _ -> length(args)
    end
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

  defp module_parts({:__aliases__, _, parts}), do: parts
  defp module_parts({:__aliases__, _, head, tail}), do: [head | tail]
  defp module_parts(other), do: [other]

  defp line(meta), do: Keyword.get(meta, :line, 0)

  # The files that call {module, function} and are not allowed to.
  defp offenders(files, module, function, allowed) do
    for {path, _source, scan} <- files,
        path not in allowed,
        {^module, ^function, _line} <- scan.sites,
        do: path,
        uniq: true
  end

  # The files that call {module, function}, allowed or not.
  defp callers(files, module, function) do
    for {path, _source, scan} <- files,
        {^module, ^function, _line} <- scan.sites,
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

    test "the schema write has no second public door: the recovery entry point is in the rule", %{
      files: files
    } do
      # `recover_provisioning/1` is a public second name for the same schema
      # write (AC9), so it carries the SAME allowed set as
      # `provision_and_migrate/1`: a caller of either is a caller of the write.
      allowed =
        Enum.find_value(@rules, fn
          {[:Letflow, :TenantOnboarding], :provision_and_migrate, allowed} -> allowed
          _ -> nil
        end)

      assert allowed, "the rule set lost the provision_and_migrate entry"

      assert {[:Letflow, :TenantOnboarding], :recover_provisioning, ^allowed} =
               Enum.find(@rules, fn
                 {module, function, _allowed} ->
                   module == [:Letflow, :TenantOnboarding] and
                     function == :recover_provisioning

                 _ ->
                   false
               end)

      assert offenders(files, [:Letflow, :TenantOnboarding], :recover_provisioning, allowed) == [],
             "recover_provisioning/1 has a caller outside #{inspect(allowed)}"
    end
  end

  describe "non-vacuity on synthetic sources" do
    test "a rogue caller is flagged, whatever the call form" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: Identity.create_tenant(a)\nend"},
          {"lib/rogue.ex",
           "defmodule Rogue do\n  def f(a), do: Letflow.Identity.create_tenant(a)\nend"},
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: apply(Identity, :create_tenant, [a])\nend"},
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.Identity\n  def f(a), do: &Identity.create_tenant/1\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "an alias is resolved, so a different module of the same last name is not flagged" do
      files =
        fake_files([
          {"lib/other.ex",
           "defmodule Other do\n  alias My.Identity\n  def f(a), do: Identity.create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end

    test "a doc mention and a definition are not call sites" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  @moduledoc \"see Identity.create_tenant/1\"\n  @spec create_tenant(term()) :: term()\n  def create_tenant(a), do: a\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end
  end

  describe "non-vacuity: every alias form the parser produces is resolved" do
    test "a renamed alias (`as:`) is resolved" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.Identity, as: I\n  def f(a), do: I.create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "a multi-alias is resolved" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.{Audit, Identity}\n  def f(a), do: Identity.create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "a multi-alias over a nested base expands the base, not the guarded module" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  alias Letflow.Identity.{Tenant, User}\n  def f(a), do: Tenant.create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end

    test "an import of a guarded module is a caller" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  import Letflow.Identity\n  def f(a), do: create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "an import with `only:` keeps the named function in scope" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  import Letflow.Identity, only: [create_tenant: 1]\n  def f(a), do: create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == ["lib/rogue.ex"]
    end

    test "an import with `except:` drops the named function from scope" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  import Letflow.Identity, except: [create_tenant: 1]\n  def create_tenant(a), do: a\n  def f(a), do: create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end

    test "an import of a module that is not guarded is not a caller" do
      files =
        fake_files([
          {"lib/rogue.ex",
           "defmodule Rogue do\n  import My.Identity\n  def f(a), do: create_tenant(a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
    end
  end
end
