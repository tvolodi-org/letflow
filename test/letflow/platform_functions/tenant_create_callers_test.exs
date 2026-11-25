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

  ## What the scan covers

  The scan reads the AST and resolves the reference to a watched module in
  these forms, each with its own fixture path in the tests:

    * `alias Letflow.Identity`, `alias Letflow.Identity, as: I` (the `as:`
      value is an AST node, not an atom), `alias Letflow.{Audit, Identity}`,
      `alias Letflow.Identity.{User, Role}`, and any of them with the
      `Elixir.` prefix (`alias Elixir.Letflow.Identity`),
    * a fully qualified call, with or without `Elixir.`,
    * `apply/3`, `Kernel.apply/3` and `:erlang.apply/3` with a literal
      function name,
    * `&Identity.create_tenant/1`,
    * `import Letflow.Identity` (also `only:` / `except:`) followed by a local
      call or a capture,
    * a module attribute that holds the module (`@identity Letflow.Identity`,
      also through an alias) used as a receiver or as the `apply` module,
    * `defdelegate f(a), to: Letflow.Identity` (and `as:`),
    * an atom that spells the module (`:"Elixir.Letflow.Identity"`).

  ## Fail closed

  Each recognised consumer replaces the reference it placed. A reference to a
  watched module that is still in the tree afterwards (a variable bound to the
  module, the module passed as an argument, `apply/3` with a computed function
  name, `use`, a struct, an attribute passed on) is recorded as UNRESOLVED and
  is a violation: the real-tree test pins the unresolved references EXACTLY to
  `@unresolved_ok` (config keys and a catalogue tuple, with the reason), so a
  new one fails the test and so does a stale entry.

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

  What the scan does NOT see; each is a limit because the reference is not in
  this file's AST as a module name:

    * a module name BUILT at run time (`Module.concat/1`, `String.to_atom/1`,
      a name read from config or the database) -- no reference exists to find,
    * `Code.eval_*` and any other compile-time evaluation,
    * a MACRO defined elsewhere that expands into the call,
    * an `alias`, `import` or `use` written through a macro
      (`alias unquote(mod)`).

  Everything that names a watched module literally in the source is either
  placed (a caller) or reported as unresolved; the test
  "the accepted limits are limits" shows the forms above are silent.
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
    {[:Letflow, :Identity], :create_provisioned_tenant, [@provisioner_file, @tenant_create_impl]},
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
    # T-2704 (gap G17b): the two operator routes (`POST /tenants`, `POST /onboarding`)
    # start the definition now, so nobody calls the public create wrapper any more,
    # and only the provisioner chain still calls the provision wrapper.
    {[:Letflow, :PlatformFunctions, :Impl, :TenantCreate], :create_tenant, []},
    {[:Letflow, :PlatformFunctions, :Impl, :TenantProvision], :provision_and_migrate,
     [@provisioner_file]},
    {[:Letflow, :TenantProvisioner], :create, [@admin_router, @signup_provisioning]}
  ]

  # References to a watched module that are DATA, not a call: a config key
  # (`Application.get_env(Letflow.TenantProvisioner, ...)`) or a catalogue
  # entry `{Module, :run, 1}` that the dispatcher invokes, and `run/1` is not
  # one of the guarded functions. Pinned exactly; the reason is part of the
  # pin.
  @unresolved_ok %{
    {"lib/letflow/platform_functions/impl/tenant_install_default_modules.ex",
     [:Letflow, :TenantProvisioner]} =>
      "config key Application.get_env(:letflow, Letflow.TenantProvisioner, ...)",
    {"lib/letflow/platform_functions/registry.ex",
     [:Letflow, :PlatformFunctions, :Impl, :TenantCreate]} =>
      "catalogue entry {TenantCreate, :run, 1}: data the dispatcher calls, run/1 is not guarded",
    {"lib/letflow/platform_functions/registry.ex",
     [:Letflow, :PlatformFunctions, :Impl, :TenantProvision]} =>
      "catalogue entry {TenantProvision, :run, 1}: data the dispatcher calls, run/1 is not guarded",
    {"lib/letflow/tenant_provisioner/config.ex", [:Letflow, :TenantProvisioner]} =>
      "config key Application.get_env(:letflow, Letflow.TenantProvisioner, ...)",
    {"lib/letflow/tenant_provisioner/request.ex", [:Letflow, :TenantProvisioner]} =>
      "config key Application.get_env(..., Letflow.TenantProvisioner, ...)"
  }

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
  # The marker of a reference to a watched module that no consumer placed.
  @unresolved :__unresolved__

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
    attrs = attr_map(ast, aliases)

    %{
      aliases: aliases,
      imports: imports,
      defined: defined,
      attrs: attrs,
      sites: call_sites(ast, aliases, imports, defined, attrs)
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

  # Every reference to a module in the file: {resolved module parts, function
  # name, line}. A local call (`create_tenant(attrs)` inside the module that
  # defines it) is not a call site of the rule: the rule names a MODULE and a
  # function.
  #
  # FAIL CLOSED. Every recognised consumer of a module reference (a call, an
  # apply, a capture, a defdelegate, an alias, an import, a module attribute)
  # REPLACES the reference node by `:__consumed__` once it has recorded it.
  # Whatever reference to a watched module is still in the tree afterwards is
  # one the scan cannot place, and it is recorded as `:__unresolved__`: an
  # unresolved reference is a violation, not silence.
  defp call_sites(ast, aliases, imports, defined, attrs) do
    {_ast, sites} =
      Macro.prewalk(ast, [], fn
        # `alias ...`, `import ...`, `require ...`: the aliases and imports
        # are resolved by `alias_map/1` and `import_map/2`; the nodes are
        # consumed so that they are not reported as stray references.
        {kind, meta, [_ | _]}, acc when kind in [:alias, :import, :require] ->
          {{kind, meta, [:__consumed__]}, acc}

        {:defmodule, meta, [_name | rest]}, acc ->
          {{:defmodule, meta, [:__consumed__ | rest]}, acc}

        # `@identity Letflow.Identity`: remembered by `attr_map/2`; a use of
        # the attribute is resolved below.
        {:@, meta, [{attr, am, [value]}]} = node, acc when is_atom(attr) ->
          case module_parts_of(value, aliases, attrs) do
            nil -> {node, acc}
            _parts -> {{:@, meta, [{attr, am, [:__consumed__]}]}, acc}
          end

        # `defdelegate create_tenant(a), to: Letflow.Identity [, as: :other]`
        {:defdelegate, meta, [head, opts]} = node, acc when is_list(opts) ->
          with {:ok, target} <- Keyword.fetch(opts, :to),
               [_ | _] = parts <- module_parts_of(target, aliases, attrs),
               {name, _arity} <- head_name_arity(head) do
            fun = delegated_name(Keyword.get(opts, :as), name)
            opts = Keyword.put(opts, :to, :__consumed__)
            {{:defdelegate, meta, [head, opts]}, [{parts, fun, line(meta)} | acc]}
          else
            _ -> {node, acc}
          end

        # `Kernel.apply(Identity, :create_tenant, [a])` and
        # `:erlang.apply(Identity, :create_tenant, [a])`
        {{:., dmeta, [caller, :apply]}, cmeta, [receiver, fun, args]} = node, acc
        when is_atom(fun) and is_list(args) ->
          if apply_owner?(caller) do
            case module_parts_of(receiver, aliases, attrs) do
              nil ->
                {node, acc}

              parts ->
                {{{:., dmeta, [caller, :apply]}, cmeta, [:__consumed__, fun, args]},
                 [{parts, fun, line(dmeta)} | acc]}
            end
          else
            remote_call(node, aliases, attrs, acc)
          end

        {{:., _, [_receiver, fun]}, _call_meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          remote_call(node, aliases, attrs, acc)

        # `apply(Identity, :create_tenant, [attrs])`
        {:apply, meta, [receiver, fun, args]} = node, acc when is_atom(fun) ->
          case module_parts_of(receiver, aliases, attrs) do
            nil ->
              {node, acc}

            parts ->
              {{:apply, meta, [:__consumed__, fun, args]}, [{parts, fun, line(meta)} | acc]}
          end

        # `&Identity.create_tenant/1`
        {:&, cmeta, [{:/, smeta, [{{:., dmeta, [receiver, fun]}, fmeta, []}, arity]}]} = node, acc
        when is_atom(fun) ->
          case module_parts_of(receiver, aliases, attrs) do
            nil ->
              {node, acc}

            parts ->
              {{:&, cmeta,
                [{:/, smeta, [{{:., dmeta, [:__consumed__, fun]}, fmeta, []}, arity]}]},
               [{parts, fun, 0} | acc]}
          end

        # `&create_tenant/1` -- the capture of an IMPORTED function.
        {:&, _, [{:/, _, [{name, _, nil}, arity]}]} = node, acc
        when is_atom(name) and is_integer(arity) ->
          case imported_call(imports, defined, name, arity) do
            nil -> {node, acc}
            parts -> {node, [{parts, name, 0} | acc]}
          end

        # A module that still names a watched module here is in a position
        # the scan does not understand: unresolved, therefore a violation.
        {:__aliases__, meta, _} = node, acc ->
          case module_parts_of(node, aliases, attrs) do
            parts when is_list(parts) ->
              if parts in @watched,
                do: {node, [{parts, @unresolved, line(meta)} | acc]},
                else: {node, acc}

            _ ->
              {node, acc}
          end

        # An attribute that holds a watched module, used in a position the
        # scan does not understand.
        {:@, meta, [{attr, _, nil}]} = node, acc when is_atom(attr) ->
          case Map.fetch(attrs, attr) do
            {:ok, parts} when is_list(parts) ->
              if parts in @watched,
                do: {node, [{parts, @unresolved, line(meta)} | acc]},
                else: {node, acc}

            _ ->
              {node, acc}
          end

        # An atom that spells a watched module (`:"Elixir.Letflow.Identity"`).
        atom, acc when is_atom(atom) ->
          case module_parts_of(atom, aliases, attrs) do
            parts when is_list(parts) ->
              if parts in @watched,
                do: {atom, [{parts, @unresolved, 0} | acc]},
                else: {atom, acc}

            _ ->
              {atom, acc}
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

  # `Mod.fun(args)`: record the call and consume the receiver.
  defp remote_call({{:., dmeta, [receiver, fun]}, cmeta, args} = node, aliases, attrs, acc) do
    case module_parts_of(receiver, aliases, attrs) do
      nil ->
        {node, acc}

      parts ->
        {{{:., dmeta, [:__consumed__, fun]}, cmeta, args}, [{parts, fun, line(dmeta)} | acc]}
    end
  end

  # `Kernel.apply/3` and `:erlang.apply/3`.
  defp apply_owner?({:__aliases__, _, [:Kernel]}), do: true
  defp apply_owner?(:erlang), do: true
  defp apply_owner?(_other), do: false

  # The function a `defdelegate` calls: `as:` when given, the head name
  # otherwise.
  defp delegated_name(as, _name) when is_atom(as) and not is_nil(as), do: as
  defp delegated_name(_as, name), do: name

  # The module attributes that hold a module: attr -> full module parts.
  defp attr_map(ast, aliases) do
    {_ast, attrs} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attr, _, [{:__aliases__, _, _} = value]}]} = node, acc when is_atom(attr) ->
          {node, [{attr, module_parts_of(value, aliases, %{})} | acc]}

        node, acc ->
          {node, acc}
      end)

    Map.new(attrs)
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

  # The FULL module parts of a receiver: nil when the receiver is not a module
  # (a variable, an unrelated atom). The alias map is applied, a leading
  # `Elixir` segment is dropped (`Elixir.Letflow.Identity` is
  # `Letflow.Identity`), a module attribute is replaced by the module it
  # holds and an atom that spells a module (`:"Elixir.Letflow.Identity"`) is
  # read as that module.
  defp module_parts_of({:__aliases__, _, parts}, aliases, _attrs) when is_list(parts),
    do: resolve(strip_elixir(parts), aliases)

  defp module_parts_of({:__aliases__, _, head, tail}, aliases, _attrs),
    do: resolve(strip_elixir([head | tail]), aliases)

  defp module_parts_of({:@, _, [{attr, _, nil}]}, _aliases, attrs) when is_atom(attr),
    do: Map.get(attrs, attr)

  defp module_parts_of(atom, _aliases, _attrs) when is_atom(atom) and not is_nil(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest |> String.split(".") |> Enum.map(&String.to_atom/1)
      _ -> nil
    end
  end

  defp module_parts_of(_other, _aliases, _attrs), do: nil

  defp strip_elixir([:"Elixir" | rest]) when rest != [], do: rest
  defp strip_elixir(parts), do: parts

  # The full module path of a call: the alias map first (the local name), the
  # written path otherwise (a fully qualified call).
  defp resolve([local | rest], aliases) do
    case Map.fetch(aliases, local) do
      {:ok, full} -> full ++ rest
      :error -> [local | rest]
    end
  end

  defp resolve(parts, _aliases), do: parts

  defp module_parts({:__aliases__, _, parts}), do: strip_elixir(parts)
  defp module_parts({:__aliases__, _, head, tail}), do: strip_elixir([head | tail])
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

  # The files that hold a reference to a watched module the scan cannot place.
  defp unresolved(files) do
    for {path, _source, scan} <- files,
        {module, @unresolved, _line} <- scan.sites,
        do: {path, module},
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

    test "the only references the scan cannot place are the listed data references",
         %{files: files} do
      # The list is pinned EXACTLY: a new unplaced reference fails the test,
      # and so does an entry that no longer matches the tree.
      assert Enum.sort(unresolved(files)) == Enum.sort(Map.keys(@unresolved_ok))

      for {key, reason} <- @unresolved_ok, do: assert(reason != "", inspect(key))
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
    # ONE path per form: neutering the resolution of any single form turns
    # exactly its own row red (the offender list is a uniq'd path list, so a
    # shared path would hide it).
    @rogue_forms [
      {"plain alias", "alias Letflow.Identity\n  def f(a), do: Identity.create_tenant(a)"},
      {"fully qualified", "def f(a), do: Letflow.Identity.create_tenant(a)"},
      {"apply/3", "alias Letflow.Identity\n  def f(a), do: apply(Identity, :create_tenant, [a])"},
      {"capture", "alias Letflow.Identity\n  def f(_), do: &Identity.create_tenant/1"},
      {"Elixir. alias",
       "alias Elixir.Letflow.Identity\n  def f(a), do: Identity.create_tenant(a)"},
      {"Elixir. fully qualified", "def f(a), do: Elixir.Letflow.Identity.create_tenant(a)"},
      {"Kernel.apply/3",
       "alias Letflow.Identity\n  def f(a), do: Kernel.apply(Identity, :create_tenant, [a])"},
      {":erlang.apply/3",
       "alias Letflow.Identity\n  def f(a), do: :erlang.apply(Identity, :create_tenant, [a])"},
      {"module attribute",
       "@identity Letflow.Identity\n  def f(a), do: @identity.create_tenant(a)"},
      {"module attribute through an alias",
       "alias Letflow.Identity\n  @identity Identity\n  def f(a), do: @identity.create_tenant(a)"},
      {"apply/3 on a module attribute",
       "@identity Letflow.Identity\n  def f(a), do: apply(@identity, :create_tenant, [a])"},
      {"defdelegate", "defdelegate create_tenant(a), to: Letflow.Identity"},
      {"defdelegate as:", "defdelegate make(a), to: Letflow.Identity, as: :create_tenant"},
      {"defdelegate through an alias",
       "alias Letflow.Identity\n  defdelegate create_tenant(a), to: Identity"},
      {"atom module", "def f(a), do: :\"Elixir.Letflow.Identity\".create_tenant(a)"},
      {"atom module in apply/3",
       "def f(a), do: apply(:\"Elixir.Letflow.Identity\", :create_tenant, [a])"}
    ]

    test "every call form is flagged, each on its own path" do
      files =
        for {{name, body}, i} <- Enum.with_index(@rogue_forms) do
          {"lib/rogue_#{i}.ex", "defmodule Rogue#{i} do\n  # #{name}\n  #{body}\nend"}
        end
        |> fake_files()

      found = offenders(files, [:Letflow, :Identity], :create_tenant, [])

      for {{name, _}, i} <- Enum.with_index(@rogue_forms) do
        assert "lib/rogue_#{i}.ex" in found, "the form `#{name}` is not seen"
      end
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

  describe "accepted limits" do
    test "the accepted limits are limits: the scan is silent on them" do
      files =
        fake_files([
          {"lib/l1.ex",
           "defmodule L1 do\n  def f(a), do: Module.concat([Letflow, Identity]).create_tenant(a)\nend"},
          {"lib/l2.ex",
           "defmodule L2 do\n  def f(a), do: String.to_atom(\"Elixir.Letflow.Identity\").create_tenant(a)\nend"},
          {"lib/l3.ex",
           "defmodule L3 do\n  def f(a), do: Code.eval_string(\"Letflow.Identity.create_tenant(a)\", a: a)\nend"}
        ])

      assert offenders(files, [:Letflow, :Identity], :create_tenant, []) == []
      assert unresolved(files) == []
    end
  end

  describe "fail closed: a reference the scan cannot place is a violation" do
    @unplaced [
      {"a variable bound to the module",
       "def f(a) do\n    m = Letflow.Identity\n    m.create_tenant(a)\n  end"},
      {"the module passed as an argument",
       "def f(a), do: run(Letflow.Identity, a)\n  defp run(m, a), do: m.create_tenant(a)"},
      {"apply/3 with a computed function",
       "def f(a, fun), do: apply(Letflow.Identity, fun, [a])"},
      {"a module attribute passed on",
       "@identity Letflow.Identity\n  def f(a), do: run(@identity, a)\n  defp run(m, a), do: m.create_tenant(a)"},
      {"use of the module", "use Letflow.Identity"},
      {"a struct of the module", "def f, do: %Letflow.Identity{}"},
      {"an atom of the module passed on",
       "def f(a), do: run(:\"Elixir.Letflow.Identity\", a)\n  defp run(m, a), do: m.create_tenant(a)"}
    ]

    test "each unplaced reference is reported as unresolved, on its own path" do
      files =
        for {{name, body}, i} <- Enum.with_index(@unplaced) do
          {"lib/unplaced_#{i}.ex", "defmodule Unplaced#{i} do\n  # #{name}\n  #{body}\nend"}
        end
        |> fake_files()

      found = unresolved(files)

      for {{name, _}, i} <- Enum.with_index(@unplaced) do
        assert "lib/unplaced_#{i}.ex" in Enum.map(found, &elem(&1, 0)), "`#{name}` is silent"
      end
    end

    test "a placed reference is not reported as unresolved" do
      files =
        fake_files([
          {"lib/placed.ex",
           "defmodule Placed do\n  alias Letflow.Identity\n  import Letflow.Identity\n  @identity Identity\n  defdelegate create_tenant(a), to: Identity\n  def f(a), do: Identity.get_tenant(a)\n  def g(a), do: @identity.get_tenant(a)\nend"}
        ])

      assert unresolved(files) == []
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
