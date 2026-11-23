defmodule Letflow.SecurityProbe.G01Case do
  @moduledoc """
  The test-side half of the G-01 probe (`Letflow.SecurityProbe.G01`): the
  fixture world, the check context and the sharded real-tree run, shared by
  `test/letflow/security_probe/g01_route_role_matrix_test.exs` (completeness,
  non-vacuity, shard coverage) and the shard files
  `test/letflow/security_probe/g01_matrix_shard_<i>_test.exs`.

  ## Why shards

  The checks step gives each tagged probe file an equal share of a fixed
  budget (`probe_cost_s` against the share). The whole matrix is about a
  minute of requests, over one file's share, so it is cut into
  `G01.shard_count/0` files. Shard `i` takes the matrix routes whose index in
  the sorted route list is `i` modulo the count: every route is in exactly one
  shard by construction, and the main file proves that a shard file exists
  for every index (G-01-C6). Each shard compares its violations with the
  ratchet lines of its own routes; the main file proves every ratchet line
  names a matrix route (G-01-C7), so no pinned line falls between shards.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Plug.Test, only: [conn: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.SecurityProbe.G01
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  # Routes closed by a feature flag answer 404 to every caller; the probe opens
  # them so their authorization is what it measures (restored on exit).
  @flags [
    {:record_triggers_enabled, true},
    {:scheduled_jobs, [enabled: true]}
  ]

  defp open_flags! do
    for {key, value} <- @flags do
      original = Application.fetch_env(:letflow, key)
      Application.put_env(:letflow, key, value)

      on_exit(fn ->
        case original do
          {:ok, v} -> Application.put_env(:letflow, key, v)
          :error -> Application.delete_env(:letflow, key)
        end
      end)
    end
  end

  @doc "The role strings of `Authorization.roles/0`."
  def roles, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  @doc """
  The fixture world. Committed tenants A, B and the platform tenant P
  (provisioning needs the sandbox's `:auto` mode) and their tokens; afterwards
  a fresh sandbox transaction holds everything else (module installs, A's
  draft definition, every request), so none of it survives the test.

  `opts[:install]` installs every golden module into A and B.
  """
  def world!(opts) do
    t = Fixture.three_tenants!()
    Fixture.pin!(t.p.tenant_id)
    open_flags!()

    a_callers =
      for role <- roles() do
        %{
          label: "A " <> role,
          role: role,
          platform?: false,
          tenant: :a,
          token: Fixture.mint_token!(t.a, [role]),
          slug: t.a.tenant.slug,
          schema: t.a.schema_name
        }
      end

    p_admin = %{
      label: "P PLATFORM_ADMIN",
      role: "PLATFORM_ADMIN",
      platform?: true,
      tenant: :p,
      token: Fixture.mint_token!(t.p, ["PLATFORM_ADMIN"]),
      slug: t.p.tenant.slug,
      schema: t.p.schema_name
    }

    # A token-holding user of B, so B's pool has rows even without installs.
    _ = Fixture.mint_token!(t.b, ["TENANT_ADMIN"])

    :ok = Sandbox.checkin(Letflow.Repo)
    # A shard holds this checkout for well under a minute here; the sandbox's
    # default 120 s ownership timeout would still close it on a loaded host.
    :ok = Sandbox.checkout(Letflow.Repo, ownership_timeout: 600_000)

    if opts[:install] do
      G01.install_golden_modules!(t.a.schema_name)
      G01.install_golden_modules!(t.b.schema_name)
    end

    foreign = %{
      tenant_id: t.b.tenant_id,
      slug: t.b.tenant.slug,
      schema: t.b.schema_name,
      pool: G01.foreign_pool(t.b.schema_name)
    }

    %{
      tenants: t,
      callers: a_callers ++ [p_admin],
      golden: G01.golden(),
      overlay: Letflow.Api.TenantGrants.load(t.a.schema_name),
      foreign: foreign,
      own: %{schema: t.a.schema_name, pool: own_pool!(t.a.schema_name)},
      schemas: [t.a.schema_name, t.b.schema_name, t.p.schema_name, "public"],
      plug: Letflow.Router,
      prefix: "/api/v1"
    }
  end

  # A's own id pool for the write-path shape: the smallest id of every A table
  # with a row (`G01.foreign_pool/1`), with `process_definitions` pointing at a
  # DRAFT of A (a plain graph): the definition PUT / PATCH write path works on
  # a draft only, so the privileged graph reaches its tenant check (T-2588).
  defp own_pool!(schema) do
    {:ok, draft} =
      Definitions.create(
        %{
          name: "g01-own-draft",
          version: "1",
          graph: %{
            "nodes" => [
              %{"id" => "start", "node_type" => "START"},
              %{"id" => "end", "node_type" => "END"}
            ],
            "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
          },
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    schema
    |> G01.foreign_pool()
    |> List.keystore("process_definitions", 0, {"process_definitions", draft.id})
  end

  defp canonical(fun) do
    resp = fun.(conn(:get, "/"))

    G01.normalise(
      %{
        status: resp.status,
        type: Plug.Conn.get_resp_header(resp, "content-type"),
        body: resp.resp_body
      },
      []
    )
  end

  @doc "The check context of `G01.violations/2` for `world`."
  def ctx(world) do
    %{
      canonical_403: canonical(&Response.forbidden(&1, "insufficient permissions")),
      canonical_404: canonical(&Response.not_found/1),
      concealed_keys: G01.concealed_keys(),
      foreign: world.foreign
    }
  end

  @doc """
  Shard `index` of the real-tree matrix: its observations' violations must
  equal the ratchet lines of its routes exactly (a new violation fails, and so
  does a pinned line of the shard that no longer occurs).
  """
  def run_shard!(index) do
    world = world!(install: true)
    routes = G01.shard_routes(index)

    assert routes != [], "G-01 shard #{index} has no route"

    assert length(world.foreign.pool) >= 8,
           "foreign pool too small: #{inspect(Enum.map(world.foreign.pool, &elem(&1, 0)))}"

    assert {"process_definitions", _} = List.keyfind(world.foreign.pool, "process_definitions", 0)
    assert {"process_definitions", _} = List.keyfind(world.own.pool, "process_definitions", 0)

    observations = G01.observe(Map.put(world, :routes, routes))

    matrix = Enum.count(observations, &(&1.shape == :missing))
    assert matrix == length(routes) * length(world.callers)
    assert Enum.any?(observations, &(&1.expected == :deny))
    assert Enum.any?(observations, &(&1.expected == :allow))

    violations = G01.violations(observations, ctx(world))
    details = Map.new(violations, &{G01.ratchet_line(&1), elem(&1, 4)})
    found = violations |> Enum.map(&G01.ratchet_line/1) |> Enum.uniq() |> Enum.sort()
    pinned = G01.ratchet_lines_for(routes) |> Enum.sort()

    new = found -- pinned
    gone = pinned -- found

    assert new == [] and gone == [],
           "G-01 shard #{index}: ratchet #{G01.ratchet_path()} differs.\n" <>
             "New violations (a new hole, or a new narrowing to review and pin):\n  " <>
             Enum.map_join(new, "\n  ", &"#{&1}    -- #{details[&1]}") <>
             "\nPinned lines that no longer occur (remove them):\n  " <> Enum.join(gone, "\n  ")

    observations
  end
end
