defmodule Letflow.Api.AuthorizationEnforcementTest do
  @moduledoc """
  REQ-131's enforcement artefact (per REQ-130's design
  `lib/letflow/design/req130-authorization-generalization.md` §4): walks
  every route macro invocation across every module under
  `lib/letflow/routers/` that `use`s `Letflow.Api.AuthorizedRouter`, by
  introspecting each router's own compiled `__authz_routes__/0` (accumulated
  at compile time by `Letflow.Api.AuthorizedRouter`'s `authz_get/3` etc
  macros) — **not** by re-parsing source, matching the design's own stated
  shape requirement.

  For each `{method, path_template, policy_key}` route, asserts either:

    * `Letflow.Api.Authorization.endpoint_policy_key(method, path_template)`
      returns the SAME, non-`:Unknown` atom the route itself declared (the
      common case — the route's own policy key is backed by a real,
      present `Letflow.Api.Authorization.endpoint_policy_key/2` clause); or
    * the exact `{method, path_template}` pair is named on `@allowlist`
      below, with a stated reason — reserved for a route whose declared
      policy key is enforced directly (bypassing
      `Authorization.endpoint_policy_key/2`) because no clause exists for
      it in `lib/letflow/api/authorization.ex`, which this requirement does
      not modify (see each allowlisted route's own router-file comment).

  A route added to any router under `lib/letflow/routers/` with NO policy
  key at all (declared via the plain `get`/`post`/`put`/`patch`/`delete`
  macros instead of `authz_get`/`authz_post`/`authz_put`/`authz_patch`/
  `authz_delete`) no longer compiles (ISS-0993 G0, `authorized_router.ex`;
  demonstrated in `platform_scope_inventory_test.exs`), and a route whose key
  is missing at request time evaluates `:Unknown`, which is denied for EVERY
  role (`authorization.ex`, rule 1; `test/letflow/plugs/authorize_test.exs`).
  The complete walk over every mounted router's `__authz_routes__/0` is G2 in
  `test/letflow/api/platform_scope_inventory_test.exs`; the hand list
  `@routers` below is narrower and is deliberately not extended here.
  This file's job is narrower and stricter: catch a route that WAS given a
  policy key but whose key drifted from (or was never backed by) the
  matrix, and force it into one of the two states above rather than leaving
  it silently reachable only by whoever happens to hold that key.

  `tenant_config.ex`/`mobile_tenant_config.ex` are excluded from this walk
  entirely (not allowlisted within it) — they are mounted outside
  `Letflow.Plugs.ApiPipeline` and never reach `Letflow.Plugs.Authorize`, by
  design (REQ-130's design §1/§4).
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization

  @routers [
    Letflow.Routers.Identity,
    Letflow.Routers.Audit,
    Letflow.Routers.Definitions,
    Letflow.Routers.Instances,
    Letflow.Routers.Onboarding,
    Letflow.Routers.Tenants,
    Letflow.Routers.Tasks,
    Letflow.Routers.SolutionPacks,
    Letflow.Routers.Promotions,
    Letflow.Routers.Services,
    Letflow.Routers.AdminServices,
    # REQ-310 -- Letflow.Routers.Entities' nine routes each declare a policy
    # key REQ-309 already backed with a real endpoint_policy_key/2 clause, so
    # every one resolves through the normal path above and none is (or may
    # be) added to @allowlist. Registering it in BOTH @routers and
    # @mount_prefix is what makes this router checked at all -- a router
    # absent from either is simply never walked and the suite stays green
    # while the surface goes unverified.
    Letflow.Routers.Entities,
    Letflow.Routers.EntityTypeHooks,
    Letflow.Routers.RecordTriggerBindings,
    Letflow.Routers.ScheduledJobs,
    # REQ-335/REQ-410 -- the exam-session HTTP surface moved from a direct
    # core-mount (REQ-335/REQ-408) to the D4/D5 gate at
    # /modules/exam/exam-sessions (REQ-410). Letflow.Modules.Exam.Router's
    # eight routes each declare a policy key backed by the module fallback
    # in Authorization.endpoint_policy_key/2 (REQ-401's module_route_permission/3),
    # so every one resolves through the normal path above and none is (or may
    # be) added to @allowlist.
    Letflow.Modules.Exam.Router,
    # GH #3162 (REQ-544 part 2) -- every Letflow.Modules.Procurement.Router route declares a policy key
    # the module fallback resolves (route_policies), so none is added to @allowlist.
    Letflow.Modules.Procurement.Router,
    # REQ-366 §1 -- Letflow.Routers.Help's single route declares :HelpRead,
    # backed by a real endpoint_policy_key/2 clause, so it resolves through
    # the normal path above and is not (and may not be) added to @allowlist.
    Letflow.Routers.Help,
    # REQ-384 Part A -- Letflow.Routers.Me's single route declares
    # :MembershipsRead, backed by a real endpoint_policy_key/2 clause, so it
    # resolves through the normal path above and is not (and may not be)
    # added to @allowlist.
    Letflow.Routers.Me,
    # REQ-382 -- Letflow.Routers.TenantSettings' single route declares
    # :TenantSettingsManage (tenant scope), backed by a real endpoint_policy_key/2 clause
    # (PATCH /tenant/settings), so it resolves through the normal path above
    # and is not (and may not be) added to @allowlist. Flagged during
    # SECURITY-REVIEWER's Step 2c review that the design doc's claim of
    # "automatic coverage" was false until this router was actually
    # registered here -- see
    # handoffs/WF02-REQ382-20260922/step-02c-security-reviewer.json.
    Letflow.Routers.Labels,
    Letflow.Routers.NotificationTemplates,
    Letflow.Routers.NotificationDeliveries,
    Letflow.Routers.NumberSequences,
    Letflow.Routers.TenantSettings,
    Letflow.Routers.TenantConfigBundle,
    Letflow.Routers.TenantLogo,
    Letflow.Routers.IntegrationMappings,
    # REQ-404 -- Letflow.Modules.Fixture.Router's one route
    # (authz_get "/items/:id", :FixtureRead, added by REQ-404 §0.1) declares
    # :FixtureRead, backed by the REQ-401 endpoint_policy_key/2 fallback
    # clause (module_route_permission/3) once mounted at /modules/fixture,
    # so it resolves through the normal path above and is not (and may not
    # be) added to @allowlist.
    Letflow.Modules.Fixture.Router,
    # GH 2534 PR 7b-2a -- Letflow.Routers.ScriptPolicy's five routes declare :ScriptPolicyRead /
    # :ScriptPolicyManage, each backed by an endpoint_policy_key/2 clause.
    Letflow.Routers.ScriptPolicy,
    # REQ-517 PR 2a (GH #2535) -- Letflow.Routers.TenantRoleScopeGrants' four routes declare
    # :RoleScopeGrantsRead / :RoleScopeGrantsManage, each backed by an endpoint_policy_key/2
    # clause (and required_permission/1 maps both to :UsersGroupsRolesManage), so every one
    # resolves through the normal path above and none is added to @allowlist.
    Letflow.Routers.TenantRoleScopeGrants
  ]

  # `Letflow.Plugs.ApiPipeline`'s own `forward/2` mount prefix per router
  # (see that module). `Letflow.Api.Authorization.endpoint_policy_key/2`
  # indexes its clauses by the FULL external path -- mount prefix + a
  # router's own local `Plug.Router` match pattern -- with exactly one
  # documented exception: `Letflow.Routers.Identity` is mounted at
  # `/identity`, but every one of its own already-shipped
  # `endpoint_policy_key/2` clauses (`/users*`, `/groups*`, `/tokens*`,
  # `/roles*`) omits that prefix, matching how the pre-REQ-131 route-local
  # `with_authorized_scope/4` calls in that router always passed the
  # UNPREFIXED literal (confirmed against `identity.ex`'s own pre-REQ-131
  # source). This test computes the same full path an
  # `authz_*` route's declared policy key must resolve against, from each
  # router's own local match pattern (as recorded in `__authz_routes__/0`)
  # plus this table -- it does not change how `Letflow.Plugs.Authorize`
  # enforces a route at runtime (that already uses the route's own directly
  # declared policy key, never a lookup through this function).
  @mount_prefix %{
    Letflow.Routers.Identity => "",
    Letflow.Routers.Audit => "/audit",
    Letflow.Routers.Definitions => "/definitions",
    Letflow.Routers.Instances => "/instances",
    Letflow.Routers.Onboarding => "/onboarding",
    Letflow.Routers.Tenants => "/tenants",
    Letflow.Routers.Tasks => "/tasks",
    Letflow.Routers.SolutionPacks => "/solution-packs",
    Letflow.Routers.Promotions => "/promotions",
    Letflow.Routers.Services => "/services",
    Letflow.Routers.AdminServices => "/admin/services",
    Letflow.Routers.Entities => "/entities",
    Letflow.Routers.EntityTypeHooks => "/entity-type-hooks",
    Letflow.Routers.RecordTriggerBindings => "/record-trigger-bindings",
    Letflow.Routers.ScheduledJobs => "/scheduled-jobs",
    Letflow.Modules.Exam.Router => "/modules/exam",
    Letflow.Modules.Procurement.Router => "/modules/procurement",
    Letflow.Routers.Help => "/help",
    Letflow.Routers.Me => "/me",
    Letflow.Routers.Labels => "/labels",
    Letflow.Routers.NotificationTemplates => "/notification-templates",
    Letflow.Routers.NotificationDeliveries => "/notification-deliveries",
    Letflow.Routers.NumberSequences => "/number-sequences",
    Letflow.Routers.TenantSettings => "/tenant/settings",
    Letflow.Routers.TenantConfigBundle => "/tenant/config-bundle",
    Letflow.Routers.TenantLogo => "/tenant/logo",
    Letflow.Routers.IntegrationMappings => "/integration-mappings",
    Letflow.Modules.Fixture.Router => "/modules/fixture",
    Letflow.Routers.ScriptPolicy => "/script-policy",
    Letflow.Routers.TenantRoleScopeGrants => "/tenant/role-scope-grants"
  }

  # {method, path_template, reason} -- a route whose declared policy key is
  # enforced directly by Letflow.Plugs.Authorize (a real, present route
  # option) but is NOT backed by a matching Authorization.endpoint_policy_key/2
  # clause, because this requirement does not modify
  # lib/letflow/api/authorization.ex. Per REQ-130's design §4: "either add a
  # policy key or add to the allowlist with a stated reason" -- these four
  # are the "add to the allowlist" branch, closing what were previously
  # silent, wholly-unguarded gaps (any authenticated tenant caller, any
  # role) rather than leaving them open. Flagged for REVIEWER.
  @allowlist [
    {"POST", "/instances/:id/rebind-pins",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §2.2(b)); " <>
       "route declares :InstancesCancel directly (lib/letflow/routers/instances.ex), reusing the " <>
       "same permission POST /instances/:id/cancel already requires, closing a previously wholly-open gap"},
    {"POST", "/instances/:id/reconstruct",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-079/design §2.2(b)); " <>
       "route declares :InstancesCancel directly, same reasoning as /:id/rebind-pins above"},
    {"POST", "/solution-packs/export",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §2.2(b)); " <>
       "route declares :DefinitionsRead directly (lib/letflow/routers/solution_packs.ex), closing a " <>
       "previously wholly-open gap"},
    {"POST", "/solution-packs/install",
     "no Authorization.endpoint_policy_key/2 clause exists for this route; route declares " <>
       ":DefinitionsCreate directly (required_permission/1 already maps it to :DefinitionsWrite), " <>
       "same reasoning as /solution-packs/export above"},
    {"POST", "/solution-packs/:pack_id/update-review",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-380/design §3.1); " <>
       "route declares :DefinitionsRead directly (lib/letflow/routers/solution_packs.ex), reusing " <>
       "the closest-matching existing policy key, same reasoning as /solution-packs/export above " <>
       "(OQ-1, flagged for REVIEWER)"},
    {"POST", "/solution-packs/:pack_id/update-apply",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-380/design §4.1); " <>
       "route declares :DefinitionsCreate directly (required_permission/1 already maps it to " <>
       ":DefinitionsWrite), same reasoning as /solution-packs/install above (flagged for REVIEWER)"},
    {"POST", "/definitions/:id/validate",
     "no Authorization.endpoint_policy_key/2 clause exists for this route (REQ-078/design §1); " <>
       "route declares :DefinitionsRead directly (lib/letflow/routers/definitions.ex), closing a " <>
       "previously wholly-open gap"}
  ]

  describe "every declared route resolves to a real, present, matching policy key" do
    for router <- @routers do
      @router router

      test "#{inspect(router)}.__authz_routes__/0 -- every route matches or is allowlisted" do
        routes = @router.__authz_routes__()
        prefix = Map.fetch!(@mount_prefix, @router)

        # Every router in @routers must actually use Letflow.Api.AuthorizedRouter.
        # (ISS-0993: Letflow.Routers.Promotions and the two other formerly plain-macro
        # routes now declare explicit authz_* keys, so they are walked here too.)
        for {method, local_path, declared_key} <- routes do
          full_path = full_path(prefix, local_path)
          real_key = Authorization.endpoint_policy_key(method, full_path)

          cond do
            real_key == declared_key and real_key != :Unknown ->
              :ok

            allowlisted?(method, full_path) ->
              :ok

            true ->
              flunk("""
              #{inspect(@router)}: route #{method} #{full_path} (router-local match pattern \
              #{inspect(local_path)}) declares policy key #{inspect(declared_key)}, but \
              Letflow.Api.Authorization.endpoint_policy_key/2 returns #{inspect(real_key)} for \
              that (method, path) pair, and this route is not on the enforcement test's \
              explicit allowlist.

              Either:
                1. add/fix the Authorization.endpoint_policy_key/2 clause so it returns \
              #{inspect(declared_key)} for #{inspect({method, full_path})}, or
                2. add {#{inspect(method)}, #{inspect(full_path)}, "<reason>"} to \
              @allowlist in this test file, with a stated reason.
              """)
          end
        end
      end
    end
  end

  # ==========================================================================
  # REQ-401 AC5 — every Catalog module's own route_policies resolves through
  # Authorization.endpoint_policy_key/2's new /modules/<id>/<rest> fallback.
  # Keyed on Letflow.Modules.Catalog.entry_modules/0, NOT on @routers above --
  # a module route's ground truth is its manifest().route_policies (design
  # lib/letflow/design/req401-catalog-sourced-permissions.md §5), independent
  # of whether the module's own router/0 happens to use
  # Letflow.Api.AuthorizedRouter. (REQ-404 §0.1 converted the fixture's
  # Router to AuthorizedRouter, so it is ALSO covered by @routers above via
  # its own __authz_routes__/0 -- this block still runs for it too, as a
  # second, independent check keyed on the manifest rather than the compiled
  # route table.) No entry is added to @allowlist for a module route -- a
  # module route that fails to resolve is a real failure, not an allowlist
  # candidate.
  # ==========================================================================

  describe "REQ-401 AC5 — every registered Catalog module's route_policies resolves" do
    test "every module exporting router/0 has every route_policies entry resolve to a real, non-:Unknown policy key" do
      for entry_module <- Letflow.Modules.Catalog.entry_modules(),
          # function_exported?/3 only inspects already-loaded modules -- it
          # will NOT force-load one, unlike an ordinary remote call. Without
          # this, a module untouched so far in the test process would be
          # (falsely) reported as not exporting router/0, silently skipping
          # every one of its routes rather than checking them.
          Code.ensure_loaded?(entry_module),
          function_exported?(entry_module, :router, 0) do
        manifest = entry_module.manifest()

        assert manifest.route_policies != [],
               "expected #{inspect(manifest.id)}'s manifest to declare at least one route_policies entry"

        for {method, path_pattern, _permission} <- manifest.route_policies do
          full_path = "/modules/#{manifest.id}#{path_pattern}"
          real_key = Authorization.endpoint_policy_key(method, full_path)

          refute real_key == :Unknown,
                 "#{inspect(manifest.id)}: route #{method} #{full_path} (route_policies pattern " <>
                   "#{inspect(path_pattern)}) resolved to :Unknown through " <>
                   "Authorization.endpoint_policy_key/2"
        end
      end
    end
  end

  test "Letflow.Routers.Promotions declares its ten routes with authz_* macros and explicit keys (ISS-0993: no longer :Unknown-gated)" do
    routes = Letflow.Routers.Promotions.__authz_routes__()
    assert length(routes) == 10
    refute Enum.any?(routes, fn {_method, _path, key} -> key == :Unknown end)
  end

  test "every allowlisted route is actually declared by its router (no stale allowlist entries)" do
    all_declared_full_paths =
      for router <- @routers,
          {method, local_path, _key} <- router.__authz_routes__() do
        {method, full_path(Map.fetch!(@mount_prefix, router), local_path)}
      end

    for {method, full_path, _reason} <- @allowlist do
      assert {method, full_path} in all_declared_full_paths,
             "#{method} #{full_path} is on @allowlist but no router declares it via authz_*/3 " <>
               "-- remove the stale allowlist entry"
    end
  end

  defp allowlisted?(method, full_path) do
    Enum.any?(@allowlist, fn {m, p, _reason} -> m == method and p == full_path end)
  end

  # mount prefix "" (Letflow.Routers.Identity) + local "/users" -> "/users".
  # Every other router: local "/" -> exactly the prefix (never prefix <> "/");
  # any other local path -> prefix <> local_path.
  defp full_path(prefix, "/"), do: if(prefix == "", do: "/", else: prefix)
  defp full_path(prefix, local_path), do: prefix <> local_path
end
