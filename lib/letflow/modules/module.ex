defmodule Letflow.Modules.Module do
  @moduledoc """
  The module contract (REQ-400, `docs/migration/decisions/0039-platform-module-solution-layering.md`
  D4; design `lib/letflow/design/req400-module-behaviour-catalog.md` §1).

  ## File placement (D3)

  This file is **core** code, not a module — it lives at
  `lib/letflow/modules/module.ex`, one level, no subdirectory. It is the
  behaviour a module's own entry file (`lib/letflow/modules/<id>/<id>.ex`)
  implements; it is not itself an example of the file-level core/module split
  D3 draws. Only `Letflow.Modules.Catalog` is core code permitted to
  reference a specific module's entry file by name (D3's xref limitation) —
  this file must never be edited to name a concrete module.

  ## Contract summary (D4)

  * `manifest/0` — **required**. Every entry module must implement it; a
    module with no `manifest/0` is not a valid entry module. Returns the
    exact map shape `t:manifest/0` below.
  * `router/0` — **optional**. Returns the `Plug.Router`-implementing module
    itself (a `module()`, not a started process) that the platform mounts
    under `/api/v1/modules/<id>/…`. REQ-400 defines only the shape; mounting
    it is REQ-403's job.
  * `on_install/2` — **optional**. Receives `prefix` (the tenant's schema
    prefix, threaded the same way every other tenant-scoped call in this
    codebase threads it, per `docs/agents/instructions/security-invariants.md`
    INV-1) and `settings` (the module's settings map at install time).
    Returns `:ok` or `{:error, term()}`. Runs inside the install transaction
    after the module's pack is installed (D4) — REQ-400 defines only the
    callback's own contract, not the transaction that calls it (REQ-402).

  * `on_install/3` — **optional** (decision 0052 D3, GH 2531). Receives `prefix`,
    `settings` and `ctx = %{actor_id: installer_user_id, rationale: text,
    pack_entity_definition_ids: %{name => id}}`: the installer's id, the
    installer-supplied, non-blank rationale (the router never synthesises one), and
    the entity definitions this install's own pack inserted. For modules whose `on_install` activates and promotes their own
    entity definitions (0052 D2), which needs an activator and a rationale. Preferred
    over `on_install/2`: when a module exports both, ONLY `on_install/3` runs.

  `router/0`, `on_install/2` and `on_install/3` are declared `@optional_callbacks` — Elixir's
  `@callback`/`@optional_callbacks` machinery auto-generates
  `behaviour_info/1`, so no separate introspection function is written here.
  """

  @typedoc """
  One entry of a manifest's `route_policies` list: an HTTP method (upper-case
  string, e.g. `"GET"`), a path pattern relative to the module's own mount
  `/api/v1/modules/<id>` (does not repeat that prefix), and the permission
  atom required to reach it.
  """
  @type route_policy :: {method :: String.t(), path_pattern :: String.t(), permission :: atom()}

  @typedoc """
  One `:write_handlers` entry (GH #2590 / REQ-501): `name` matches
  `^[a-z][a-z0-9_]{0,63}$`; `function` is `{module, fun}` with `module`
  STRICTLY nested under the entry module (never the entry module itself) and
  `fun` exported with arity 3; `targets` is non-empty, distinct and a subset of the same manifest's `:manages_entity_types`;
  `args` declares argument names (and whether each is required) only.
  """
  @type write_handler_spec :: %{
          required(:name) => String.t(),
          required(:function) => {module(), atom()},
          required(:targets) => [String.t()],
          required(:args) => %{String.t() => %{required: boolean()}}
        }

  @typedoc """
  The manifest map shape every entry module's `manifest/0` must return
  (design §1.3). Field semantics:

    * `:id` — the module's own id string (e.g. `"fixture"`, `"exam"`).
    * `:version` — a version string, opaque to this requirement.
    * `:depends_on` — other module ids this module requires installed first.
    * `:pack` — a path to the module's solution-pack document, or `nil`.
    * `:permissions` — the permission atoms this module declares and owns.
    * `:role_grants` — `%{role_atom => [permission_atom]}`, restricted to
      atoms this module itself declares in `:permissions` and to role atoms
      already known to `Letflow.Api.Authorization.roles/0`.
    * `:required_roles` — advisory only (0029 §2); stored, not enforced.
    * `:settings_schema` — a JSON-Schema-shaped map describing the module's
      configurable settings, or `nil` if it has none.
    * `:route_policies` — see `t:route_policy/0`.
    * `:manages_entity_types` — **optional**; entity type names this module owns;
      the install step stamps `managed_by` on them (0050 D7, REQ-496). Absent
      means `[]`. Each name must match `^[a-z][a-z0-9_]{0,63}$`.
    * `:widens_grants` — **optional**; `[{role_atom, permission_atom}]`
      declaring a NARROWING (a role losing one of this module's atoms) in this
      version, matched exactly by `mix letflow.permission_matrix --check`
      (GH #2586 / REQ-498, decision 0055 D7). Never authorises a widening.
      Absent means `[]`; clear it at the next version bump.
    * `:write_handlers` - **optional** (GH #2590 / REQ-501, decision 0054 D4);
      see `t:write_handler_spec/0`. Absent means `[]`. Registration is manifest
      data only, resolved by `Letflow.Modules.Catalog.write_handler/2`. The
      manifest hash (`Letflow.Modules.ManifestHash`) covers `id`, `version`,
      `manages_entity_types` and the handler declarations but NOT handler code:
      bump `:version` whenever handler code changes.
    * `:scope_declarations` - **optional** (REQ-518, decision 0051 D6; design
      `lib/letflow/design/req518-compiler-scope-filter.md` 3.2); `%{entity_type_name =>
      {:column, field_name} | :tenant_wide}`. Absent means none. Read by
      `Letflow.Entities.ScopeDeclaration` only. Production modules may declare only types in
      their own `:manages_entity_types` (`Catalog` rule 11). The manifest hash covers it only
      when present.
  """
  @type manifest :: %{
          required(:id) => String.t(),
          required(:version) => String.t(),
          required(:depends_on) => [String.t()],
          required(:pack) => String.t() | nil,
          required(:permissions) => [atom()],
          required(:role_grants) => %{atom() => [atom()]},
          required(:required_roles) => [String.t()],
          required(:settings_schema) => map() | nil,
          required(:route_policies) => [route_policy()],
          optional(:manages_entity_types) => [String.t()],
          optional(:widens_grants) => [{atom(), atom()}],
          optional(:write_handlers) => [write_handler_spec()],
          optional(:scope_declarations) => %{String.t() => {:column, String.t()} | :tenant_wide}
        }

  @callback manifest() :: manifest()
  @callback router() :: module()
  @callback on_install(prefix :: String.t(), settings :: map()) :: :ok | {:error, term()}

  @typedoc """
  The install context passed to `on_install/3` (0052 D3): the installer, the
  installer-supplied rationale (verbatim), and the entity definitions this install's
  own pack inserted, `%{name => id}` (0052 D6: the only ones `on_install/3` may
  activate; `%{}` for a module without a pack).
  """
  @type install_ctx :: %{
          actor_id: Ecto.UUID.t(),
          rationale: String.t(),
          pack_entity_definition_ids: %{String.t() => Ecto.UUID.t()}
        }

  @callback on_install(prefix :: String.t(), settings :: map(), ctx :: install_ctx()) ::
              :ok | {:error, term()}

  @optional_callbacks router: 0, on_install: 2, on_install: 3

  @doc """
  Compile-time manifest declaration macro — opt-in syntactic sugar that
  generates `def manifest/0` **and** checks at compile time that every
  atom appearing in `role_grants` values is also declared in `permissions`.

  ## Usage

      import Letflow.Modules.Module, only: [defmanifest: 1]

      defmanifest(
        id: "my_module",
        version: "0.1.0",
        depends_on: [],
        pack: nil,
        permissions: [:MyRead, :MyWrite],
        role_grants: %{TASK_WORKER: [:MyRead]},
        required_roles: [],
        settings_schema: nil,
        route_policies: [{"GET", "/items/:id", :MyRead}]
      )

  This is exactly equivalent to writing `def manifest/0` by hand, except
  that any atom listed in `role_grants` but absent from `permissions` raises
  a `CompileError` at the call site during compilation rather than failing
  at test-time in `Catalog.validate/1`.

  ## Argument contract

  `fields` must be a keyword list **literal** at the call site. Required
  keys and their expected value shapes mirror `t:manifest/0`:

  | Key | Expected literal type |
  |---|---|
  | `:id` | `String.t()` literal |
  | `:version` | `String.t()` literal |
  | `:depends_on` | `[String.t()]` literal list |
  | `:pack` | `String.t()` literal or `nil` |
  | `:permissions` | `[atom()]` literal list |
  | `:role_grants` | `%{atom() => [atom()]}` literal map |
  | `:required_roles` | `[String.t()]` literal list |
  | `:settings_schema` | `map()` literal or `nil` |
  | `:route_policies` | `[{String.t(), String.t(), atom()}]` literal list |
  | `:widens_grants` (optional) | `[{atom(), atom()}]` literal list (narrowing declarations, GH #2586) |
  | `:write_handlers` (optional) | `[t:write_handler_spec/0]` literal list; `function: {Mod, :fun}` with full aliases (GH #2590) |
  | `:scope_declarations` (optional) | `%{String.t() => {:column, String.t()} | :tenant_wide}` literal map (REQ-518) |

  If any `role_grants` value atom is absent from `permissions`, a
  `CompileError` is raised at the call site during compilation. Non-literal
  values are silently passed through to `manifest/0` (no compile-time check
  is possible for them; use `Catalog.validate/1` at test time).

  Modules that cannot use compile-time literals for all fields must continue
  to implement `def manifest/0` directly — `defmanifest` is additive and
  does not replace the `@callback` contract.
  """
  defmacro defmanifest(fields) do
    caller = __CALLER__

    # Evaluate all compile-time literal values from the keyword list AST to
    # obtain actual Elixir values for the permissions check.  This works
    # because defmanifest requires literal values at the call site.
    {kw, _bindings} = Code.eval_quoted(fields, [], caller)

    permissions = Keyword.get(kw, :permissions, [])
    role_grants = Keyword.get(kw, :role_grants, %{})

    for {_role, perms} <- role_grants, perm <- perms do
      unless perm in permissions do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "role_grants atom :#{perm} is not declared in permissions for module #{inspect(caller.module)}"
      end
    end

    manifest_map = Map.new(kw)

    quote do
      def manifest(), do: unquote(Macro.escape(manifest_map))
    end
  end
end
