defmodule Letflow.SecurityProbe.G01RouteRoleMatrixTest do
  @moduledoc """
  G-01 of the team repo's `docs/security-coverage.md` §4: the generated
  real-HTTP **route x role x tenant x request-shape** matrix, with
  foreign/missing byte identity and no-write assertions. The generator, the
  oracle and the rules live in `Letflow.SecurityProbe.G01`; the class table is
  `docs/security-probes/G-01.md`.

  The real-tree matrix itself runs in the shard files
  `test/letflow/security_probe/g01_matrix_shard_<i>_test.exs`
  (`Letflow.SecurityProbe.G01Case.run_shard!/1`): every route of the
  inventory, for every role, through the full `Letflow.Router` pipeline with a
  real API token; every id route again with each real id of a populated
  foreign tenant; every mutating id route again with each own id of the
  company tenant (the write path). Each shard's violations must equal the
  ratchet lines of its routes in `test/fixtures/security_probes/g01/ratchet.txt`
  exactly: a new violation fails (a new hole), and so does a ratchet line
  that no longer occurs (a fixed finding must leave the file, so the ratchet
  only tightens).

  This file holds what the shards rest on. Non-vacuity: the rogue router
  (`Letflow.SecurityProbe.G01RogueRouter`) goes through the SAME
  `G01.observe/1` and `G01.violations/2` and must trip every rule M1..M8;
  completeness: the inventory, the role list and the oracle are not empty, a
  shard file exists for every shard index and together the shards hold every
  matrix route, and every ratchet line names a matrix route.

  Deterministic: fixed ids, sorted routes, roles and pool, every request in a
  rolled-back transaction (no order dependence), no clock, no network.
  `async: false`: the platform-tenant pin and the two feature flags are
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.SecurityProbe.G01
  alias Letflow.SecurityProbe.G01Case
  alias Letflow.SecurityProbe.G01RogueRouter

  @moduletag :security_probe
  @moduletag probe_cost_s: 8
  @moduletag timeout: 300_000

  @shard_glob "test/letflow/security_probe/g01_matrix_shard_*_test.exs"

  defp roles, do: G01Case.roles()

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
    test "M1..M8 each name a rogue route" do
      world = G01Case.world!(install: false)
      G01RogueRouter.put_foreign(world.foreign)
      G01RogueRouter.put_own(world.own)
      world = %{world | plug: G01RogueRouter, prefix: ""}
      routes = G01RogueRouter.routes()

      observations = G01.observe(Map.put(world, :routes, routes))
      found = G01.violations(observations, G01Case.ctx(world))
      by_rule = Enum.group_by(found, &elem(&1, 0), &{elem(&1, 2), elem(&1, 3)})

      assert world.foreign.pool != []
      assert {"GET", "/rogue/items"} in Map.get(by_rule, :M1, [])
      assert {"POST", "/rogue/items"} in Map.get(by_rule, :M2, [])
      assert {"GET", "/rogue/locked"} in Map.get(by_rule, :M3, [])
      assert {"GET", "/rogue/items/:id"} in Map.get(by_rule, :M4, [])
      assert {"POST", "/rogue/items"} in Map.get(by_rule, :M5, [])
      assert {"GET", "/rogue/items/:id/owner"} in Map.get(by_rule, :M6, [])
      assert {"GET", "/rogue/crash"} in Map.get(by_rule, :M7, [])
      assert {"PATCH", "/rogue/definitions/:id"} in Map.get(by_rule, :M8, [])

      # The ratchet comparison the real tree uses fails on these lines.
      lines = Enum.map(found, &G01.ratchet_line/1)
      refute MapSet.subset?(MapSet.new(lines), MapSet.new(G01.read_ratchet()))
    end
  end

  describe "the privileged body reaches the write path (T-2588 anchor)" do
    # The definition write routes of `Letflow.Routers.Definitions`, by policy
    # key (the solution-pack routes share `:DefinitionsCreate` but take a pack,
    # not a graph). The matrix shards send the
    # same body to every mutating route; this test pins that, for the routes
    # T-2588 was about, the body is not refused before the platform-call
    # tenant check (`Letflow.Definitions` `check_platform_call_tenant/2`): a
    # body the route refuses at validation would leave M8 vacuous there.
    @write_keys [:DefinitionsCreate, :DefinitionsUpdate, :DefinitionsPatch]

    test "a company TENANT_ADMIN's platform_call graph is refused by the tenant check" do
      world = G01Case.world!(install: false)

      routes =
        Enum.filter(
          G01.matrix_routes(),
          &(&1.key in @write_keys and &1.router == Letflow.Routers.Definitions)
        )

      assert length(routes) == length(@write_keys)

      admin = Enum.filter(world.callers, &(&1.label == "A TENANT_ADMIN"))

      world = %{world | callers: admin} |> Map.put(:routes, routes)
      observations = G01.observe(world)

      # POST /definitions has no id (its :missing shape is the write); PUT and
      # PATCH reach their draft through the own shape.
      writes =
        Enum.filter(observations, fn o ->
          (o.shape == :missing and not G01.param_route?(o.path)) or
            o.shape == {:own, "process_definitions"}
        end)

      assert length(writes) == length(@write_keys)

      for o <- writes do
        assert o.resp.status == 422, "#{o.method} #{o.path} answered #{o.resp.status}"
        assert %{"error" => "platform_calls_invalid"} = Jason.decode!(o.resp.body)
      end

      assert [] ==
               Enum.filter(
                 G01.violations(observations, G01Case.ctx(world)),
                 &(elem(&1, 0) == :M8)
               )
    end
  end

  describe "the shards cover the matrix" do
    test "a shard file exists for every shard index, and every shard has routes" do
      indexes =
        @shard_glob
        |> Path.wildcard()
        |> Enum.map(fn file ->
          assert File.read!(file) =~ "@moduletag :security_probe", "#{file} is not tagged"
          [_all, i] = Regex.run(~r/G01Case\.run_shard!\((\d+)\)/, File.read!(file))
          String.to_integer(i)
        end)
        |> Enum.sort()

      assert indexes == Enum.to_list(0..(G01.shard_count() - 1))

      shards = Enum.map(indexes, &G01.shard_routes/1)
      assert Enum.all?(shards, &(&1 != []))
      assert Enum.sort(List.flatten(shards)) == Enum.sort(G01.matrix_routes())
    end

    test "every ratchet line names a matrix route" do
      keys = MapSet.new(G01.matrix_routes(), &{&1.method, &1.path})
      orphans = Enum.reject(G01.read_ratchet(), &MapSet.member?(keys, G01.ratchet_route(&1)))
      assert orphans == [], "ratchet lines naming no matrix route: #{inspect(orphans)}"
    end
  end
end
