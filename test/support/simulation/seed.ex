defmodule Letflow.Simulation.Seed do
  @moduledoc """
  REQ-205 test-support module (`lib/letflow/design/req205-simulation-harness-foundation.md`
  §2). One function per R-Co `tests/simulation/seed.py` responsibility, each calling
  Letflow's own context modules directly (`Letflow.Identity`, `Letflow.TenantOnboarding`,
  `Letflow.Definitions`) -- never HTTP, never a subprocess (Decision 1 of the design;
  AC2).

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs` --
  no change needed there). Not part of the shipped application.

  ## Idempotency (AC3)

  Every function here treats "seeding something that already exists from a prior
  seed call in the same test run" as a no-op, not an error -- mirrors `seed.py`'s
  documented "409 means already exists, left unchanged" contract. Each function's
  own `@doc` states its exact mechanism.

  ## OQ-1 resolution (design §9) -- there is no `prefix`/`schema_name` field on
  ## `Letflow.Identity.Tenant.t()`

  The design deferred "confirm the field name" to implementation, on the premise
  that `Tenant.t()` carries one. Reading `lib/letflow/identity/tenant.ex`'s schema
  directly (this session) shows it does not: `Tenant` has `id`, `slug`,
  `display_name`, `status`, `idp_realm_id`, timestamps -- no schema/prefix field at
  all. The tenant's Postgres schema name is a *separate* piece of state, owned by
  `Letflow.TenantProvisioning` (`Registration.schema_name`, looked up via
  `Letflow.TenantProvisioning.schema_name_for_tenant/1`). Every function below that
  needs `opts: [prefix: ...]` for an `Letflow.Identity`/`Letflow.Definitions` call
  therefore derives it by calling `schema_name_for_tenant/1` on the tenant's `id`,
  not by reading a field off the `Tenant` struct. Reported as a MINOR
  design/implementation discrepancy, same disposition as `Letflow.TenantFixture`'s
  own recorded OQ-4/deviation note.

  ## Deviation from the design's literal function names (`get_by_username/2`,
  ## `username_unique_conflict?/1`, and the mirror `group_name_unique_conflict?/1`)

  The design cites these as "confirmed present" in `lib/letflow/identity.ex` and
  callable by this module. They are indeed present -- but as `defp` (module-private)
  functions, not reachable from outside `Letflow.Identity`. Re-verified by direct
  read this session (`lib/letflow/identity.ex` lines ~1526-1573, ~1256-1260). This
  module therefore cannot call them directly and substitutes the same *public*
  idiom the design already settled for `seed_groups/2`'s OQ-2 resolution --
  list-all via the module's own public list function
  (`Letflow.Identity.list_users/2`'s `:search` filter, ILIKE-substring, followed by
  an exact client-side match on `username`) rather than an exact-match private
  lookup. `create_user/2` and `create_group/2` already surface the unique-conflict
  case as a public `{:error, :duplicate_username}` / `{:error,
  :duplicate_group_name}` tuple, so the conflict-branch fallback needs no private
  helper either -- only the pre-check needed a public substitute. Reported to
  ORCH/REVIEWER as a MINOR design/implementation discrepancy, not a silent
  re-decision: the *mechanism* (pre-check + conflict-branch fallback) is unchanged,
  only the pre-check's underlying query is swapped for an equivalent public one.

  ## `seed_process/1` widened to `seed_process/3`

  The design's §2.4 literal signature is `seed_process(process_fixture :: map())`.
  `Letflow.Definitions.create/2` requires `opts: [prefix: ...]` (which the fixture
  map alone cannot supply -- it is derived from a tenant, see the OQ-1 resolution
  above) and `created_by :: Ecto.UUID.t()` in `create_attrs()` (no fixture field
  carries this; R-Co's process fixtures have no authorship reference at all).
  This module therefore implements `seed_process/3`, taking `tenant` and
  `created_by` explicitly rather than threading them through the fixture map or a
  process dictionary. Reported as a MINOR design/implementation discrepancy.
  """

  alias Letflow.Definitions
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning

  @typedoc "Fields resolved from a fixture's org_structure.yaml people entry."
  @type person_fixture :: %{
          required(String.t()) => String.t()
        }

  @doc """
  Seeds one company's tenant + onboarding record, per §2.1. Input is the parsed
  `company.yaml` map (post-YAML-decode: `"slug"`, `"display_name"`, `"hostname"`
  string keys, matching this fixture's own YAML key names verbatim).

  Idempotency: pre-checks via `Letflow.Identity.get_tenant_by_slug/1`. If the
  tenant already exists, schema provisioning/migration replay is skipped entirely
  (replaying migrations against an already-migrated schema is the hazard this
  avoids per the design) and the onboarding record is fetched-or-created. If the
  tenant does not exist, runs the full create-tenant -> provision-and-migrate ->
  create-onboarding sequence. Returns `{:ok, %{tenant: ..., onboarding: ...}}` in
  both branches -- the caller cannot distinguish "just created" from "already
  existed," matching `seed.py`'s documented 409-is-a-no-op contract.
  """
  @spec seed_company(company_fixture :: map()) ::
          {:ok, %{tenant: Tenant.t(), onboarding: Identity.OnboardingRecord.t()}}
          | {:error, term()}
  def seed_company(company_fixture) do
    slug = Map.fetch!(company_fixture, "slug")
    display_name = Map.fetch!(company_fixture, "display_name")
    hostname = Map.fetch!(company_fixture, "hostname")

    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        with_existing_tenant_onboarding(tenant, hostname)

      {:error, :not_found} ->
        create_company(slug, display_name, hostname)
    end
  end

  defp create_company(slug, display_name, hostname) do
    with {:ok, tenant} <-
           Identity.create_tenant(%{"slug" => slug, "display_name" => display_name}),
         {:ok, _registration} <- TenantOnboarding.provision_and_migrate(tenant.id),
         {:ok, onboarding} <-
           Identity.create_onboarding(%{tenant_id: tenant.id, slug: slug, hostname: hostname}) do
      {:ok, %{tenant: tenant, onboarding: onboarding}}
    end
  end

  defp with_existing_tenant_onboarding(tenant, hostname) do
    case Identity.get_onboarding_by_hostname(hostname) do
      {:ok, onboarding} ->
        {:ok, %{tenant: tenant, onboarding: onboarding}}

      {:error, :not_found} ->
        case Identity.create_onboarding(%{
               tenant_id: tenant.id,
               slug: tenant.slug,
               hostname: hostname
             }) do
          {:ok, onboarding} -> {:ok, %{tenant: tenant, onboarding: onboarding}}
          {:error, :duplicate_hostname} -> retry_onboarding_lookup(tenant, hostname)
          {:error, _reason} = error -> error
        end
    end
  end

  # Belt-and-suspenders for a TOCTOU race between the lookup above and this
  # function's own create_onboarding/1 call -- same shape as create_company/3's
  # (and every other seed_*/N function's) conflict-branch fallback below.
  defp retry_onboarding_lookup(tenant, hostname) do
    case Identity.get_onboarding_by_hostname(hostname) do
      {:ok, onboarding} -> {:ok, %{tenant: tenant, onboarding: onboarding}}
      {:error, :not_found} -> {:error, :onboarding_race_unresolved}
    end
  end

  @doc """
  Seeds every person in an `org_structure.yaml` fixture's `"people"` list under
  `tenant`, per §2.2. Calls `Letflow.Identity.create_user/2` with `opts: [prefix:
  schema_name]`, where `schema_name` is resolved via
  `Letflow.TenantProvisioning.schema_name_for_tenant/1` (see moduledoc's OQ-1
  resolution).

  Idempotency: pre-checks each username via `Letflow.Identity.list_users/2`'s
  `:search` filter (ILIKE substring) plus an exact client-side match on
  `username` (moduledoc's documented substitute for the private
  `get_by_username/2`). If found, skips creation and uses the existing record. If
  `create_user/2` itself races and returns `{:error, :duplicate_username}`, the
  same list-and-match lookup re-fetches the winner instead of propagating the
  error.

  Returns `{:ok, [user, ...]}`, one entry per fixture person, in fixture order.
  """
  @spec seed_users(org_structure_fixture :: map(), tenant :: Tenant.t()) ::
          {:ok, [Identity.User.t()]} | {:error, term()}
  def seed_users(org_structure_fixture, %Tenant{} = tenant) do
    prefix = schema_name!(tenant)
    people = Map.get(org_structure_fixture, "people", [])

    Enum.reduce_while(people, {:ok, []}, fn person, {:ok, acc} ->
      case seed_one_user(person, prefix, tenant.id) do
        {:ok, user} -> {:cont, {:ok, acc ++ [user]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp seed_one_user(person, prefix, tenant_id) do
    username = Map.fetch!(person, "username")

    case find_user_by_username(username, prefix) do
      %Identity.User{} = user ->
        {:ok, user}

      nil ->
        attrs = %{
          "username" => username,
          "display_name" => Map.fetch!(person, "display_name"),
          "email" => Map.fetch!(person, "email")
        }

        case Identity.create_user(attrs, prefix: prefix, tenant_id: tenant_id) do
          {:ok, user} -> {:ok, user}
          {:error, :duplicate_username} -> refetch_user_or_error(username, prefix)
          {:error, _reason} = error -> error
        end
    end
  end

  defp refetch_user_or_error(username, prefix) do
    case find_user_by_username(username, prefix) do
      %Identity.User{} = user -> {:ok, user}
      nil -> {:error, {:duplicate_username_race_unresolved, username}}
    end
  end

  # Public substitute for the private Letflow.Identity.get_by_username/2 -- see
  # moduledoc. list_users/2 requires :page_size; a fixture's whole company is
  # always far smaller than this, so one page always covers it.
  defp find_user_by_username(username, prefix) do
    {:ok, %{users: users}} =
      Identity.list_users(%{search: username, page_size: 500}, prefix: prefix)

    Enum.find(users, &(&1.username == username))
  end

  @doc """
  Seeds every group in an `org_structure.yaml` fixture's `"groups"` list under
  `tenant`, and adds each listed member, per §2.3 (OQ-2, settled: client-side
  name matching, not a pending question).

  Idempotency: `Letflow.Identity.list_groups/1` takes only `opts: [prefix: ...]`
  and returns every group in the tenant's schema, unfiltered -- there is no
  server-side by-name lookup. This function lists all groups and matches the
  fixture's group `"name"` client-side. If a match is found, `create_group/2` is
  skipped for that entry; if `create_group/2` still races
  (`{:error, :duplicate_group_name}`), the same list-and-match lookup re-fetches
  the winner. `add_group_member/3`'s own idempotency (already-present membership
  is a no-op at the context-function level) is reused as-is -- no extra
  pre-check for individual members.

  Returns `{:ok, [group, ...]}`.
  """
  @spec seed_groups(org_structure_fixture :: map(), tenant :: Tenant.t()) ::
          {:ok, [Identity.Group.t()]} | {:error, term()}
  def seed_groups(org_structure_fixture, %Tenant{} = tenant) do
    prefix = schema_name!(tenant)
    groups_fixture = Map.get(org_structure_fixture, "groups", [])
    users_by_actor_id = index_people_by_actor_id(Map.get(org_structure_fixture, "people", []))

    Enum.reduce_while(groups_fixture, {:ok, []}, fn group_fixture, {:ok, acc} ->
      case seed_one_group(group_fixture, prefix, users_by_actor_id) do
        {:ok, group} -> {:cont, {:ok, acc ++ [group]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp index_people_by_actor_id(people) do
    Map.new(people, fn person ->
      {Map.fetch!(person, "actor_id"), Map.fetch!(person, "username")}
    end)
  end

  defp seed_one_group(group_fixture, prefix, users_by_actor_id) do
    name = Map.fetch!(group_fixture, "name")

    with {:ok, group} <- find_or_create_group(name, group_fixture, prefix),
         :ok <-
           add_members(group, Map.get(group_fixture, "members", []), users_by_actor_id, prefix) do
      {:ok, group}
    end
  end

  defp find_or_create_group(name, group_fixture, prefix) do
    case find_group_by_name(name, prefix) do
      %Identity.Group{} = group ->
        {:ok, group}

      nil ->
        attrs = %{
          "name" => name,
          "display_name" => Map.get(group_fixture, "display_name", name)
        }

        case Identity.create_group(attrs, prefix: prefix) do
          {:ok, group} -> {:ok, group}
          {:error, :duplicate_group_name} -> refetch_group_or_error(name, prefix)
          {:error, _reason} = error -> error
        end
    end
  end

  defp refetch_group_or_error(name, prefix) do
    case find_group_by_name(name, prefix) do
      %Identity.Group{} = group -> {:ok, group}
      nil -> {:error, {:duplicate_group_name_race_unresolved, name}}
    end
  end

  defp find_group_by_name(name, prefix) do
    {:ok, %{groups: groups}} = Identity.list_groups(prefix: prefix)
    Enum.find(groups, &(&1.name == name))
  end

  defp add_members(group, member_actor_ids, users_by_actor_id, prefix) do
    Enum.reduce_while(member_actor_ids, :ok, fn actor_id, :ok ->
      username = Map.fetch!(users_by_actor_id, actor_id)

      case find_user_by_username(username, prefix) do
        %Identity.User{} = user ->
          case Identity.add_group_member(group.id, user.id, prefix: prefix) do
            {:ok, %{}} -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        nil ->
          {:halt, {:error, {:member_user_not_seeded, actor_id}}}
      end
    end)
  end

  @doc """
  Seeds one `process_*.yaml` fixture as an active process definition, per §2.4.
  `created_by` is not a fixture field (R-Co's fixtures carry no user reference for
  authorship) -- `created_by` is supplied by the caller (usually the first seeded
  user for the company) since `Letflow.Definitions.create/2`'s `create_attrs()`
  requires it.

  Idempotency: pre-checks via `Letflow.Definitions.get_active_by_name/2`. If an
  active definition with that name already exists, creation/activation is
  skipped entirely and the existing definition is returned as-is. Otherwise,
  `create/2` then `activate/2` run in sequence to reach the same active state
  `seed.py`'s POST-then-activate sequence produces.
  """
  @spec seed_process(process_fixture :: map(), tenant :: Tenant.t(), created_by :: Ecto.UUID.t()) ::
          {:ok, Definitions.ProcessDefinition.t()} | {:error, term()}
  def seed_process(process_fixture, %Tenant{} = tenant, created_by) do
    prefix = schema_name!(tenant)
    name = Map.fetch!(process_fixture, "name")

    case Definitions.get_active_by_name(name, prefix: prefix) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, :not_found} ->
        create_and_activate_process(process_fixture, name, created_by, prefix)
    end
  end

  defp create_and_activate_process(process_fixture, name, created_by, prefix) do
    attrs = %{
      name: name,
      version: Map.fetch!(process_fixture, "version"),
      description: Map.get(process_fixture, "description"),
      graph: Map.fetch!(process_fixture, "graph"),
      created_by: created_by
    }

    # REQ-530: a fixture that declares required_outputs also declares their variable_schemas,
    # which the registration check (REQ-461) needs; register them with the definition.
    entries =
      Enum.map(Map.get(process_fixture, "variable_schemas", []), fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    with {:ok, definition} <-
           Definitions.create_with_variable_schemas(attrs, entries, prefix: prefix),
         {:ok, %{definition: activated}} <- Definitions.activate(definition.id, prefix: prefix) do
      {:ok, activated}
    else
      {:error, :duplicate_name_version} -> refetch_process_or_error(name, prefix)
      {:error, _reason} = error -> error
    end
  end

  defp refetch_process_or_error(name, prefix) do
    case Definitions.get_active_by_name(name, prefix: prefix) do
      {:ok, definition} -> {:ok, definition}
      {:error, :not_found} -> {:error, {:duplicate_process_race_unresolved, name}}
    end
  end

  # Shared schema_name derivation -- see moduledoc's OQ-1 resolution.
  defp schema_name!(%Tenant{id: tenant_id}) do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end
end
