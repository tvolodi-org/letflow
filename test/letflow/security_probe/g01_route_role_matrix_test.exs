defmodule Letflow.SecurityProbe.G01RouteRoleMatrixTest do
  @moduledoc """
  G-01 of the team repo's `docs/security-coverage.md` §4: the generated
  real-HTTP **route x role x tenant x request-shape** matrix, with
  foreign/missing byte identity and no-write assertions. The generator, the
  oracle and the rules live in `Letflow.SecurityProbe.G01`; the class table is
  `docs/security-probes/G-01.md`.

  The matrix test sends every route of the inventory, for every role, through
  the full `Letflow.Router` pipeline with a real API token, and every id route
  again with each real id of a populated foreign tenant. Its violations must
  equal the committed ratchet `test/fixtures/security_probes/g01/ratchet.txt`
  exactly: a new violation fails (a new hole), and so does a ratchet line
  that no longer occurs (a fixed finding must leave the file, so the ratchet
  only tightens).

  Non-vacuity: the rogue router (`Letflow.SecurityProbe.G01RogueRouter`)
  goes through the SAME `G01.observe/1` and `G01.violations/2` and must trip
  every rule M1..M7; the completeness tests prove the inventory, the role
  list, the oracle and the foreign pool are not empty.

  Deterministic: fixed ids, sorted routes, roles and pool, every request in a
  rolled-back transaction (no order dependence), no clock, no network.
  `async: false`: the platform-tenant pin and the two feature flags are
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.SecurityProbe.G01
  alias Letflow.SecurityProbe.G01RogueRouter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @moduletag :security_probe
  @moduletag probe_cost_s: 85
  @moduletag timeout: 600_000

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

  defp roles, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  # Committed tenants (provisioning needs the sandbox's :auto mode) and their
  # tokens; afterwards a fresh sandbox transaction holds everything else
  # (module installs, every request), so none of it survives the test.
  defp world!(opts) do
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
    # The matrix holds this checkout for about two minutes: above the sandbox's
    # default 120 s ownership timeout, after which the pool closes it.
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
      schemas: [t.a.schema_name, t.b.schema_name, t.p.schema_name, "public"],
      plug: Letflow.Router,
      prefix: "/api/v1"
    }
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

  defp ctx(world) do
    %{
      canonical_403: canonical(&Response.forbidden(&1, "insufficient permissions")),
      canonical_404: canonical(&Response.not_found/1),
      concealed_keys: G01.concealed_keys(),
      foreign: world.foreign
    }
  end

  describe "completeness (the generator is not empty)" do
    test "the inventory, the golden and the role list are not empty" do
      routes = G01.matrix_routes()
      assert length(routes) >= 400, "only #{length(routes)} routes in the matrix"
      assert Enum.any?(routes, &(G01.module_id(&1.path) != nil)), "no module route in the matrix"
      assert Enum.any?(routes, &G01.param_route?(&1.path)), "no id route in the matrix"
      assert Enum.any?(routes, &G01.mutating?(&1.method)), "no mutating route in the matrix"
      assert length(roles()) >= 9
      golden = G01.golden()
      assert map_size(golden) >= length(roles()) * 50

      for role <- roles(),
          do: assert(Enum.any?(golden, &match?({{^role, _}, true}, &1)) or role == "CANDIDATE")

      assert G01.golden_modules() != []
      assert G01.concealed_keys() != []
    end

    test "every matrix route has an oracle answer for every role" do
      golden = G01.golden()

      for route <- G01.matrix_routes(), role <- roles(), platform? <- [true, false] do
        assert G01.expected(golden, %{}, role, platform?, route.key) in [:allow, :deny]
      end
    end

    test "every route outside the oracle belongs to a module that is not shipped" do
      shipped =
        "config/config.exs"
        |> Config.Reader.read!(env: :prod, target: :host)
        |> get_in([:letflow, :modules])
        |> Enum.map(& &1.manifest().id)

      excluded = G01.excluded_routes() |> Enum.map(&G01.module_id(&1.path)) |> Enum.uniq()

      assert shipped != []
      assert MapSet.disjoint?(MapSet.new(excluded), MapSet.new(shipped))
      assert Enum.sort(shipped) == Enum.sort(G01.golden_modules())
    end

    test "the inventory does not discover the rogue router" do
      refute Enum.any?(G01.routes(), &(&1.router == G01RogueRouter))
    end
  end

  describe "non-vacuity: the seeded rogue router trips every rule" do
    test "M1..M7 each name a rogue route" do
      world = world!(install: false)
      G01RogueRouter.put_foreign(world.foreign)
      world = %{world | plug: G01RogueRouter, prefix: ""}
      routes = G01RogueRouter.routes()

      observations = G01.observe(Map.put(world, :routes, routes))
      found = G01.violations(observations, ctx(world))
      by_rule = Enum.group_by(found, &elem(&1, 0), &{elem(&1, 2), elem(&1, 3)})

      assert world.foreign.pool != []
      assert {"GET", "/rogue/items"} in Map.get(by_rule, :M1, [])
      assert {"POST", "/rogue/items"} in Map.get(by_rule, :M2, [])
      assert {"GET", "/rogue/locked"} in Map.get(by_rule, :M3, [])
      assert {"GET", "/rogue/items/:id"} in Map.get(by_rule, :M4, [])
      assert {"POST", "/rogue/items"} in Map.get(by_rule, :M5, [])
      assert {"GET", "/rogue/items/:id/owner"} in Map.get(by_rule, :M6, [])
      assert {"GET", "/rogue/crash"} in Map.get(by_rule, :M7, [])

      # The ratchet comparison the real tree uses fails on these lines.
      lines = Enum.map(found, &G01.ratchet_line/1)
      refute MapSet.subset?(MapSet.new(lines), MapSet.new(G01.read_ratchet()))
    end
  end

  describe "the real tree" do
    test "route x role x tenant x shape: the violations equal the ratchet" do
      world = world!(install: true)
      routes = G01.matrix_routes()

      assert length(world.foreign.pool) >= 8,
             "foreign pool too small: #{inspect(Enum.map(world.foreign.pool, &elem(&1, 0)))}"

      assert {"process_definitions", _} =
               List.keyfind(world.foreign.pool, "process_definitions", 0)

      observations = G01.observe(Map.put(world, :routes, routes))

      matrix = Enum.count(observations, &(&1.shape == :missing))
      assert matrix == length(routes) * length(world.callers)
      assert Enum.any?(observations, &match?({:foreign, _}, &1.shape))
      assert Enum.any?(observations, &(&1.expected == :deny))
      assert Enum.any?(observations, &(&1.expected == :allow))

      violations = G01.violations(observations, ctx(world))
      details = Map.new(violations, &{G01.ratchet_line(&1), elem(&1, 4)})
      found = violations |> Enum.map(&G01.ratchet_line/1) |> Enum.uniq() |> Enum.sort()
      pinned = G01.read_ratchet() |> Enum.sort()

      new = found -- pinned
      gone = pinned -- found

      assert new == [] and gone == [],
             "G-01 ratchet #{G01.ratchet_path()} differs.\n" <>
               "New violations (a new hole, or a new narrowing to review and pin):\n  " <>
               Enum.map_join(new, "\n  ", &"#{&1}    -- #{details[&1]}") <>
               "\nPinned lines that no longer occur (remove them):\n  " <> Enum.join(gone, "\n  ")
    end
  end
end
