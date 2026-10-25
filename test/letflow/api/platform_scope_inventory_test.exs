defmodule Letflow.Api.PlatformScopeInventoryTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 11 (guards G0..G4) and section 12 items 13 and 18
  (specs `test/specs/ISS-0993-A1.md`, `ISS-0993-A2.md`): the route-inventory guard for platform scope separation.

  INV-10 check ("platform authority bound to the platform tenant"), enforced from the merge of
  Q-960 PR A. Named checks carried here: the scope-table completeness guard (G2), the platform
  pinning snapshot (G3), the permission-classification guard.

    * **G0** -- compile time. `use Letflow.Api.AuthorizedRouter` no longer imports the plain
      `get/post/put/patch/delete/head/options` macros, so a plain-macro route does not compile;
      `match/2` (router catch-all) and `forward/2` still do, and `authz_unmatched/1` accepts only
      its two kinds.
    * **G1** -- source scan of the router files for route declarations that are neither `authz_*`
      nor a catch-all, with an explicit allowlist of the six public routes (design 7.4). The
      scanner takes source text, so one test feeds it a literal bad snippet and asserts it is
      flagged (demonstrated once, without compiling a bad route).
    * **G2** -- route table. Every router mounted by `Letflow.Plugs.ApiPipeline` is discovered
      through `__authz_routes__/0`; no declared key is `:Unknown`; every route's permission is a
      core or a Catalog permission; every permission atom reachable is classified in exactly one
      of the two sets (core scope table or Catalog rule), otherwise the runtime fail-closed
      fallback (`:platform`) would apply and the test fails.
    * **G3** -- platform pinning. The set of routes whose permission is platform scope equals a
      literal snapshot of the 27 rows (design 7.1 plus ISS-1030's POST /onboarding/:id/bind-realm, GH 2534 7b-2a's two and 7b-2b's one /tenants/:slug/script-policy routes and, in PR 2, GET /onboarding/:id/pending-admins and DELETE /onboarding/:id/pending-admins/:grant_id), and the pure `evaluate_access/2` grid for the
      platform keys is as designed.
    * **G4** -- tenant-identifier scan (design 11, A2). Router files that read a tenant identifier
      from the request (a field constraint naming a tenant or slug, a `params["..."]` read of one,
      a `:slug` / `:..._tenant_id` path parameter, a tenant key copied from the body) must be on
      `@tenant_param_allowlist` (promotions, tenants, admin_services, onboarding), and each of those
      must call `TenantTarget.authorize_target_tenant/2` or be a platform-only router (every route
      platform scope). One public router (`mobile_tenant_config`) is exempt by name. The scanner
      takes source text, so a literal bad snippet demonstrates it. Design 11 allows dropping G4 if
      it proves brittle; it is kept because its patterns match the current sources exactly, and an
      unlisted reader or a stale entry fails with `file:line`. If a pattern ever becomes a
      maintenance burden, drop the describe and record the reason here (G0-G3 and the
      handler-level tests of items 5, 7, 11 and 20 do not depend on it).

  No database. `async: true` is safe: nothing here mutates global state.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Modules.Catalog

  # --------------------------------------------------------------------------
  # shared helpers
  # --------------------------------------------------------------------------

  @pipeline_source File.read!("lib/letflow/plugs/api_pipeline.ex")

  # {router module, mount prefix} from the `forward("<prefix>", to: <Module>)` lines.
  defp pipeline_mounts do
    ~r/forward\(\s*"([^"]+)"\s*,\s*to:\s*([A-Za-z0-9_.]+)\s*\)/
    |> Regex.scan(@pipeline_source)
    |> Enum.map(fn [_all, prefix, module] -> {Module.concat([module]), prefix} end)
  end

  # Routers reached only through `Letflow.Routers.Modules` (mounted at /modules/<manifest id>).
  defp module_mounts do
    for entry <- Catalog.entry_modules(),
        Code.ensure_loaded?(entry),
        function_exported?(entry, :router, 0) do
      {entry.router(), "/modules/" <> entry.manifest().id}
    end
  end

  defp all_mounts, do: pipeline_mounts() ++ module_mounts()

  defp discovered_routers do
    for module <- Application.spec(:letflow, :modules),
        Code.ensure_loaded?(module),
        function_exported?(module, :__authz_routes__, 0),
        do: module
  end

  defp full_path(prefix, "/"), do: prefix
  defp full_path(prefix, local), do: prefix <> local

  # [{router, method, full_path, declared_key}]
  defp all_routes do
    mounts = Map.new(all_mounts())

    for router <- discovered_routers(),
        {method, local, key} <- router.__authz_routes__() do
      prefix = Map.fetch!(mounts, router)
      {router, method, full_path(prefix, local), key}
    end
  end

  # REQ-446 T-4: the G2 (a) predicate, as one helper over `{router, method, path, key}` tuples:
  # the routes that declare `:Unknown` or a catch-all marker as their key.
  defp offending_routes(routes) do
    Enum.filter(routes, fn {_router, _method, _path, key} ->
      key in [:Unknown, :UnmatchedPlatformPath, :UnmatchedRoute]
    end)
  end

  defp classified_core, do: Authorization.core_permissions()
  defp classified_catalog, do: Catalog.permissions()

  # --------------------------------------------------------------------------
  # G0 -- compile time
  # --------------------------------------------------------------------------

  describe "G0: no plain verb macros in an AuthorizedRouter" do
    defp compile_router(body) do
      name = "Elixir.PlatformScopeG0Probe#{System.unique_integer([:positive])}"

      source = """
      defmodule #{name} do
        use Letflow.Api.AuthorizedRouter
      #{body}
      end
      """

      capture_io(:stderr, fn ->
        send(self(), {:result, safe_compile(source)})
      end)

      receive do
        {:result, result} -> result
      end
    end

    defp safe_compile(source) do
      Code.compile_string(source)
      :compiled
    rescue
      error -> {:error, error}
    end

    for verb <- ~w(get post put patch delete head options) do
      test "a plain `#{verb}` route does not compile" do
        assert {:error, %CompileError{}} =
                 compile_router(~s|  #{unquote(verb)} "/x" do\n    conn\n  end|)
      end
    end

    test "authz_* routes, `match _` and `forward` still compile" do
      assert :compiled ==
               compile_router("""
                 authz_get "/x", :HelpRead do
                   conn
                 end

                 authz_post "/y", :HelpRead do
                   conn
                 end
               """)

      assert :compiled == compile_router("  match _ do\n    conn\n  end")
    end

    test "authz_unmatched/1 accepts exactly :platform_prefix and :ordinary" do
      assert :compiled == compile_router("  authz_unmatched(:platform_prefix)")
      assert :compiled == compile_router("  authz_unmatched(:ordinary)")
      assert {:error, _} = compile_router("  authz_unmatched(:other)")
      assert {:error, _} = compile_router("  authz_unmatched(\"ordinary\")")
    end

    test "authz_unmatched/1 records the marker policy key and answers 404; it is not a route" do
      name = Module.concat(__MODULE__, "UnmatchedProbe#{System.unique_integer([:positive])}")

      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(name)} do
          use Letflow.Api.AuthorizedRouter
          authz_get "/x", :HelpRead do
            conn
          end
          authz_unmatched(:platform_prefix)
        end
        """)
      end)

      assert name.__authz_routes__() == [{"GET", "/x", :HelpRead}]
    end
  end

  # --------------------------------------------------------------------------
  # G1 -- source scan (takes source text)
  # --------------------------------------------------------------------------

  describe "G1: every route declaration is authz_*, a catch-all, public or credential-authenticated" do
    # [{line_number, verb, path_or_pattern}] for route declarations that are not authz_*,
    # `match _` or `forward`. Heredoc (doc) blocks and comment lines are skipped.
    def plain_route_declarations(source) do
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({false, []}, fn {line, number}, {in_doc?, found} ->
        quotes = length(String.split(line, ~s(""")) |> tl())
        toggled? = rem(quotes, 2) == 1

        cond do
          in_doc? -> {if(toggled?, do: false, else: true), found}
          toggled? -> {true, found}
          true -> {false, found ++ declaration(line, number)}
        end
      end)
      |> elem(1)
    end

    defp declaration(line, number) do
      trimmed = String.trim_leading(line)

      cond do
        String.starts_with?(trimmed, "#") ->
          []

        match =
            Regex.run(~r/^(get|post|put|patch|delete|head|options)\s*\(?\s*"([^"]*)"/, trimmed) ->
          [_all, verb, path] = match
          [{number, String.upcase(verb), path}]

        match = Regex.run(~r/^match\s*\(?\s*"([^"]*)"/, trimmed) ->
          [_all, path] = match
          [{number, "MATCH", path}]

        true ->
          []
      end
    end

    # The six GLOBAL-PUBLIC routes of design 7.4 (never under ApiPipeline).
    @public_allowlist [
      {"lib/letflow/router.ex", "GET", "/health"},
      {"lib/letflow/routers/login_discovery.ex", "POST", "/"},
      {"lib/letflow/routers/metrics_exposition.ex", "GET", "/"},
      {"lib/letflow/routers/mobile_tenant_config.ex", "GET", "/"},
      {"lib/letflow/routers/public_read.ex", "GET", "/:kind/:handle"},
      {"lib/letflow/routers/tenant_config.ex", "GET", "/"}
    ]

    # REQ-572 / decision 0072 D6 (test CS1): the five routes of the provisioner mount. They are plain
    # Plug.Router routes on purpose: they are authenticated by a credential class, not a role, behind
    # `Letflow.Plugs.ProvisionerAuth`, outside ApiPipeline. They are not public: the test below pins that
    # the plug is declared before the first route and that the router is mounted by `Letflow.Router`.
    @credential_allowlist [
      {"lib/letflow/routers/admin_v1.ex", "GET", "/tenants/:id"},
      {"lib/letflow/routers/admin_v1.ex", "POST", "/tenants"},
      {"lib/letflow/routers/admin_v1.ex", "POST", "/tenants/:id/suspend"},
      {"lib/letflow/routers/admin_v1.ex", "POST", "/tenants/:id/resume"},
      {"lib/letflow/routers/admin_v1.ex", "POST", "/tenants/:id/expire"}
    ]

    defp scanned_files do
      Enum.sort(
        ["lib/letflow/router.ex"] ++
          Path.wildcard("lib/letflow/routers/**/*.ex") ++
          Path.wildcard("lib/letflow/modules/**/router.ex")
      )
    end

    test "the scanner flags a literal bad snippet (demonstrated without compiling a bad route)" do
      bad = """
      defmodule Bad do
        use Letflow.Api.AuthorizedRouter

        authz_get "/ok", :HelpRead do
          conn
        end

        post "/plain" do
          conn
        end

        match "/sneaky" do
          conn
        end

        match _ do
          conn
        end
      end
      """

      assert plain_route_declarations(bad) == [
               {8, "POST", "/plain"},
               {12, "MATCH", "/sneaky"}
             ]
    end

    test "the scanner ignores doc blocks, comments, authz_* and the `match _` catch-all" do
      source = ~s'''
      defmodule Fine do
        @moduledoc """
        get "/in-a-doc" do
        """
        # get "/in-a-comment" do
        authz_get "/x", :HelpRead do
          conn
        end
        match _ do
          conn
        end
      end
      '''

      assert plain_route_declarations(source) == []
    end

    test "the router files are discovered (the scan is not vacuous)" do
      files = scanned_files()
      assert length(files) >= 30
      assert "lib/letflow/routers/tenants.ex" in files
      assert "lib/letflow/modules/exam/router.ex" in files
    end

    test "every plain route declaration under the router files is on the public or credential allowlist, and neither has a stale entry" do
      found =
        for file <- scanned_files(),
            {line, verb, path} <- plain_route_declarations(File.read!(file)),
            do: {file, line, verb, path}

      offenders =
        for {file, line, verb, path} <- found,
            {file, verb, path} not in @public_allowlist,
            {file, verb, path} not in @credential_allowlist,
            do: "#{file}:#{line}  #{verb} #{inspect(path)}"

      assert offenders == [],
             "route(s) declared without an authz_* macro (explicit policy key required):\n" <>
               Enum.join(offenders, "\n")

      seen = for {file, _line, verb, path} <- found, do: {file, verb, path}

      for entry <- @public_allowlist ++ @credential_allowlist do
        assert entry in seen, "stale public allowlist entry #{inspect(entry)}"
      end

      assert length(@public_allowlist) == 6
      assert length(@credential_allowlist) == 5
    end

    test "CS1 the credential routes sit behind ProvisionerAuth and the mount is in Letflow.Router" do
      source = File.read!("lib/letflow/routers/admin_v1.ex")
      {plug_at, _} = :binary.match(source, "Letflow.Plugs.ProvisionerAuth)")
      {first_route, _} = ~r/^  (get|post) "/m |> Regex.run(source, return: :index) |> hd()
      assert plug_at < first_route, "ProvisionerAuth must be plugged before the first route"

      router = File.read!("lib/letflow/router.ex")
      assert router =~ ~r/forward\(?\s*"\/admin\/v1"/
      refute File.read!("lib/letflow/plugs/api_pipeline.ex") =~ "AdminV1"
    end
  end

  # --------------------------------------------------------------------------
  # G2 -- route table
  # --------------------------------------------------------------------------

  describe "G2: route table" do
    test "every router mounted by the pipeline declares its routes through AuthorizedRouter or is the module gateway" do
      mounted = Enum.map(pipeline_mounts(), &elem(&1, 0))
      discovered = discovered_routers()

      assert length(mounted) >= 20

      for router <- mounted do
        Code.ensure_loaded!(router)

        assert router in discovered or router == Letflow.Routers.Modules,
               "#{inspect(router)} is mounted by ApiPipeline but exports no __authz_routes__/0"
      end
    end

    test "every discovered router has a mount (no router declares routes that are never walked)" do
      mounted = all_mounts() |> Enum.map(&elem(&1, 0))

      for router <- discovered_routers() do
        assert router in mounted, "#{inspect(router)} declares authz routes but has no mount"
      end
    end

    test "no mount prefix is shared by two routers" do
      prefixes = pipeline_mounts() |> Enum.map(&elem(&1, 1))
      assert prefixes == Enum.uniq(prefixes)
    end

    test "(a) no route declares :Unknown, and no catch-all marker is declared as a route key" do
      routes = all_routes()
      assert length(routes) >= 130

      offenders = offending_routes(routes)

      assert offenders == [],
             "routes declaring :Unknown or a catch-all marker: #{inspect(offenders)}"
    end

    test "G2 (a) flags a fixture router that declares :Unknown as an explicit key (REQ-446 T-4)" do
      name =
        Module.concat(__MODULE__, "ExplicitUnknownProbe#{System.unique_integer([:positive])}")

      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(name)} do
          use Letflow.Api.AuthorizedRouter

          authz_get "/named", :HelpRead do
            conn
          end

          authz_get "/explicit-unknown", :Unknown do
            conn
          end
        end
        """)
      end)

      # the explicit-key form COMPILES (the macro accepts any term) ...
      routes = for {method, path, key} <- name.__authz_routes__(), do: {name, method, path, key}
      assert length(routes) == 2

      # ... and is caught by the very predicate G2 (a) applies to the real route table
      assert offending_routes(routes) == [{name, "GET", "/explicit-unknown", :Unknown}]

      # control: the same predicate accepts the named route on its own
      assert offending_routes(Enum.reject(routes, &(elem(&1, 3) == :Unknown))) == []
    end

    test "a route declared with NO policy key does not compile (REQ-446 T-4)" do
      assert {:error, %CompileError{}} =
               compile_router(~s|  authz_get "/no-key" do
    conn
  end|)
    end

    test "(b)/(d) every route's permission is a core or a Catalog permission (never the identity fallback)" do
      known = classified_core() ++ classified_catalog()

      for {router, method, path, key} <- all_routes() do
        permission = Authorization.required_permission(key)

        assert permission in known,
               "#{inspect(router)} #{method} #{path}: key #{inspect(key)} resolves to " <>
                 "#{inspect(permission)}, which is in neither core_permissions/0 nor Catalog.permissions/0"
      end
    end

    test "(c) every reachable permission atom is classified in exactly one of core and Catalog" do
      assert classified_core() -- Enum.uniq(classified_core()) == []
      assert classified_catalog() -- Enum.uniq(classified_catalog()) == []

      assert Enum.filter(classified_core(), &(&1 in classified_catalog())) == [],
             "a permission is both core and Catalog"

      reachable =
        all_routes()
        |> Enum.map(fn {_r, _m, _p, key} -> Authorization.required_permission(key) end)
        |> Kernel.++(classified_core())
        |> Kernel.++(classified_catalog())
        |> Enum.uniq()

      for permission <- reachable do
        in_core? = permission in classified_core()
        in_catalog? = permission in classified_catalog()

        assert in_core? != in_catalog?,
               "#{inspect(permission)} must be in exactly one of core_permissions/0 and Catalog.permissions/0"

        assert Authorization.permission_scope(permission) in [:platform, :tenant]
      end
    end

    test "an unclassified atom falls to the fail-closed :platform scope, so (c) would catch it" do
      assert Authorization.permission_scope(:NotARealPermissionAtom) == :platform
      assert :NotARealPermissionAtom not in classified_core()
      assert :NotARealPermissionAtom not in classified_catalog()
    end

    test "the formerly plain-macro routes and PATCH /tenant/settings resolve to explicit keys" do
      expected = [
        {"POST", "/promotions", :PromotionsManage},
        {"POST", "/promotions/plan", :PromotionsManage},
        {"GET", "/promotions/platform-events", :PromotionsRead},
        {"GET", "/promotions/:id", :PromotionsRead},
        {"GET", "/promotions/:id/context", :PromotionsRead},
        {"POST", "/promotions/:id/approve", :PromotionsManage},
        {"POST", "/promotions/:id/reject", :PromotionsManage},
        {"POST", "/promotions/:id/apply", :PromotionsManage},
        {"POST", "/promotions/:review_id/run-assertions", :PromotionsManage},
        {"GET", "/promotions", :PromotionsRead},
        {"POST", "/definitions/:process_key/rollback", :DefinitionsRollback},
        {"POST", "/tenants/:test_tenant_id/promote/:process_key", :PromotionsManage},
        {"PATCH", "/tenant/settings", :TenantSettingsManage}
      ]

      routes = all_routes()

      for {method, path, key} <- expected do
        assert {method, path, key} in Enum.map(routes, fn {_r, m, p, k} -> {m, p, k} end),
               "#{method} #{path} does not declare #{inspect(key)}"
      end
    end
  end

  # --------------------------------------------------------------------------
  # G3 -- platform pinning
  # --------------------------------------------------------------------------

  @platform_routes [
    {"POST", "/tenants"},
    {"GET", "/tenants"},
    {"GET", "/tenants/:slug"},
    {"PATCH", "/tenants/:slug"},
    {"POST", "/tenants/:slug/deactivate"},
    {"POST", "/tenants/:slug/reactivate"},
    # GH 2534 7b-2a (decision 0053 D7): the operator's script policy view and platform latch.
    {"GET", "/tenants/:slug/script-policy"},
    {"PUT", "/tenants/:slug/script-policy/kill-switch"},
    # GH 2534 7b-2b (decision 0053 D6): the platform flag allowing solo_audited.
    {"PUT", "/tenants/:slug/script-policy/solo-audited"},
    {"POST", "/onboarding"},
    {"GET", "/onboarding/:id"},
    {"POST", "/onboarding/:id/bind-realm"},
    {"GET", "/onboarding/:id/pending-admins"},
    {"DELETE", "/onboarding/:id/pending-admins/:grant_id"},
    {"GET", "/onboarding"},
    {"POST", "/platform-migrations/rollouts"},
    {"GET", "/platform-migrations/rollouts/:id"},
    {"POST", "/platform-migrations/rollouts/:id/resume"},
    {"GET", "/event-retention/summary"},
    {"POST", "/event-retention/retirements"},
    {"GET", "/event-retention/retirements/:id"},
    {"GET", "/admin/services"},
    {"POST", "/admin/services"},
    {"PATCH", "/admin/services/:service_id"},
    {"DELETE", "/admin/services/:service_id"},
    {"POST", "/admin/services/:service_id/versions"},
    {"POST", "/admin/services/:service_id/retire"}
  ]

  describe "G3: platform pinning" do
    test "the routes whose permission is platform scope are exactly the 27 snapshot rows" do
      actual =
        for {_router, method, path, key} <- all_routes(),
            Authorization.permission_scope(Authorization.required_permission(key)) == :platform,
            do: {method, path}

      assert length(@platform_routes) == 27
      assert Enum.sort(actual) == Enum.sort(@platform_routes)
    end

    test "the only non-platform route under the /tenants mount is the promote route" do
      tenants_routes =
        for {Letflow.Routers.Tenants, method, path, key} <- all_routes(), do: {method, path, key}

      # GH 2534 7b-2a added GET /:slug/script-policy and PUT /:slug/script-policy/kill-switch;
      # 7b-2b added PUT /:slug/script-policy/solo-audited.
      assert length(tenants_routes) == 10

      non_platform =
        for {method, path, key} <- tenants_routes,
            Authorization.permission_scope(Authorization.required_permission(key)) == :tenant,
            do: {method, path}

      assert non_platform == [{"POST", "/tenants/:test_tenant_id/promote/:process_key"}]
    end

    test "platform_permissions/0 is exactly :TenantsManage and :PlatformServicesManage" do
      assert Enum.sort(Authorization.platform_permissions()) ==
               Enum.sort([:TenantsManage, :PlatformServicesManage])

      for permission <- Authorization.platform_permissions() do
        assert Authorization.permission_scope(permission) == :platform
      end

      derived =
        Enum.filter(
          Authorization.core_permissions(),
          &(Authorization.permission_scope(&1) == :platform)
        )

      assert Enum.sort(derived) == Enum.sort(Authorization.platform_permissions())
    end

    test "evaluate_access/2 on every platform key: the platform tenant's PLATFORM_ADMIN is allowed, nobody else" do
      platform_keys =
        for {_r, _m, _p, key} <- all_routes(),
            Authorization.permission_scope(Authorization.required_permission(key)) == :platform,
            uniq: true,
            do: key

      assert Enum.sort(platform_keys) == [
               :AdminServicesManage,
               :AdminServicesRead,
               :TenantsManage
             ]

      for key <- platform_keys do
        admin = fn platform? ->
          Authorization.evaluate_access(
            %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN], platform_tenant?: platform?},
            key
          )
        end

        assert admin.(false).kind == :Deny403, "#{key}: PLATFORM_ADMIN of another tenant"
        assert admin.(true).kind == :Allow, "#{key}: PLATFORM_ADMIN of the platform tenant"

        for role <- Authorization.roles() -- [:PLATFORM_ADMIN], platform? <- [true, false] do
          decision =
            Authorization.evaluate_access(
              %AccessContext{user_id: "u", roles: [role], platform_tenant?: platform?},
              key
            )

          assert decision.kind == :Deny403,
                 "#{key}: #{role} with platform_tenant? #{platform?} must be denied"
        end

        # the default (field omitted) fails closed
        assert Authorization.evaluate_access(
                 %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN]},
                 key
               ).kind == :Deny403
      end
    end

    test "platform permissions are granted only through the platform-scope check" do
      for permission <- Authorization.platform_permissions(),
          role <- Authorization.roles() do
        refute Authorization.has_permission_in_scope?([role], permission, false),
               "#{role} must not hold #{permission} outside the platform tenant"
      end

      assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :TenantsManage, true)

      assert Authorization.has_permission_in_scope?(
               [:PLATFORM_ADMIN],
               :PlatformServicesManage,
               true
             )

      refute Authorization.has_permission_in_scope?([:PROCESS_DESIGNER], :TenantsManage, true)

      # fail closed on a non-boolean platform flag
      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :TenantsManage, nil)
      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :TenantsManage, "true")
    end
  end

  # --------------------------------------------------------------------------
  # G4 -- tenant-identifier scan
  # --------------------------------------------------------------------------

  describe "G4: a router that reads a tenant identifier from the request is on the allowlist and applies the scope rule" do
    # Router files that may read a tenant identifier (a tenant id, or a tenant slug) from the
    # request: promotions and tenants name tenants through the helper; admin_services and
    # onboarding are platform-only routers (every route is platform scope), so only the operator
    # reaches their handlers.
    @tenant_param_allowlist [
      "lib/letflow/routers/admin_services.ex",
      "lib/letflow/routers/onboarding.ex",
      "lib/letflow/routers/promotions.ex",
      "lib/letflow/routers/tenants.ex"
    ]

    # GLOBAL-PUBLIC router (design 7.4, never under ApiPipeline): reads the public tenant slug to
    # answer the unauthenticated mobile bootstrap; it returns only public configuration.
    @tenant_param_public ["lib/letflow/routers/mobile_tenant_config.ex"]

    @tenant_param_patterns [
      # a request field constraint naming a tenant (or a tenant slug)
      {:field, ~r/name:\s*"([^"]*tenant[^"]*|slug)"/},
      # a request parameter read: conn.params["slug"], Map.get(conn.query_params, "tenant_id")
      {:param, ~r/params(?:\[|,)\s*"([^"]*(?:tenant|slug)[^"]*)"/},
      # a path parameter in a route pattern: "/:slug", "/:test_tenant_id/promote"
      {:path,
       ~r/^(?:authz_\w+|get|post|put|patch|delete|match)\s*\(?\s*"[^"]*:([a-z_]*(?:tenant|slug)[a-z_]*)/},
      # a body value copied through to a write: maybe_put(body, "owner_tenant_id", ...)
      {:body, ~r/maybe_put\(\s*\w+,\s*"([^"]*tenant[^"]*)"/}
    ]

    # [{line_number, kind, token}] for the code lines of `source` (doc heredocs and comments skipped)
    def tenant_param_hits(source) do
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({false, []}, fn {line, number}, {in_doc?, found} ->
        quotes = length(String.split(line, ~s(""")) |> tl())
        toggled? = rem(quotes, 2) == 1

        cond do
          in_doc? -> {not toggled?, found}
          toggled? -> {true, found}
          String.starts_with?(String.trim_leading(line), "#") -> {false, found}
          true -> {false, found ++ line_hits(line, number)}
        end
      end)
      |> elem(1)
    end

    defp line_hits(line, number) do
      trimmed = String.trim_leading(line)

      for {kind, regex} <- @tenant_param_patterns,
          [_all, token] <- Regex.scan(regex, trimmed),
          do: {number, kind, token}
    end

    defp code_references_helper?(source) do
      source
      |> String.split("\n")
      |> Enum.any?(fn line ->
        not String.starts_with?(String.trim_leading(line), "#") and
          line =~ "TenantTarget.authorize_target_tenant("
      end)
    end

    defp router_module(file) do
      Module.concat(Letflow.Routers, file |> Path.basename(".ex") |> Macro.camelize())
    end

    defp platform_only?(router) do
      Code.ensure_loaded!(router)

      routes = router.__authz_routes__()

      routes != [] and
        Enum.all?(routes, fn {_method, _path, key} ->
          Authorization.permission_scope(Authorization.required_permission(key)) == :platform
        end)
    end

    test "the scanner flags a literal bad snippet and ignores docs and comments" do
      bad = ~s'''
      defmodule Bad do
        use Letflow.Api.AuthorizedRouter

        @moduledoc """
        name: "tenant_id" in a doc is ignored
        """
        # conn.params["tenant_id"] in a comment is ignored

        authz_get "/:tenant_id/things", :HelpRead do
          lookup(conn.params["tenant_id"])
        end

        @schema [%FieldConstraint{name: "target_tenant_id", type: :string}]
        defp copy(body), do: maybe_put(body, "owner_tenant_id", :owner)
      end
      '''

      hits = tenant_param_hits(bad)

      assert {9, :path, "tenant_id"} in hits
      assert {10, :param, "tenant_id"} in hits
      assert {13, :field, "target_tenant_id"} in hits
      assert {14, :body, "owner_tenant_id"} in hits
      assert hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == [9, 10, 13, 14]
    end

    test "every router that reads a tenant identifier is on the allowlist (or is the public router)" do
      offenders =
        for file <- scanned_files(),
            file not in @tenant_param_allowlist,
            file not in @tenant_param_public,
            {line, kind, token} <- tenant_param_hits(File.read!(file)),
            do: "#{file}:#{line}  #{kind} #{inspect(token)}"

      assert offenders == [],
             "router(s) read a tenant identifier from the request but are not on " <>
               "@tenant_param_allowlist (add the Letflow.Api.TenantTarget call, then the file):\n" <>
               Enum.join(offenders, "\n")
    end

    test "the allowlist and the public exemption are not stale: every entry still reads a tenant identifier" do
      for file <- @tenant_param_allowlist ++ @tenant_param_public do
        assert tenant_param_hits(File.read!(file)) != [],
               "#{file} no longer reads a tenant identifier; remove it from the allowlist"
      end
    end

    test "every allowlisted router applies TenantTarget.authorize_target_tenant/2 or is platform-only" do
      for file <- @tenant_param_allowlist do
        assert code_references_helper?(File.read!(file)) or platform_only?(router_module(file)),
               "#{file} reads a tenant identifier but neither calls " <>
                 "TenantTarget.authorize_target_tenant/2 nor is a platform-only router"
      end

      # the two that name tenants through the helper really call it
      for file <- ["lib/letflow/routers/promotions.ex", "lib/letflow/routers/tenants.ex"] do
        assert code_references_helper?(File.read!(file)), file
      end

      # the platform-only ones really are (every route platform scope)
      for file <- ["lib/letflow/routers/admin_services.ex", "lib/letflow/routers/onboarding.ex"] do
        assert platform_only?(router_module(file)), file
      end
    end
  end
end
