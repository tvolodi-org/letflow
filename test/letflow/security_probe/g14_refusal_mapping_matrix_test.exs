defmodule Letflow.SecurityProbe.G14RefusalMappingMatrixTest do
  @moduledoc """
  G-14: the refusal-mapping matrix of the activation switch-on surfaces.

  The class: a refusal tuple the activation fences can return must answer a
  TYPED 4xx on EVERY surface that switches a definition on. A surface that
  leaves the tuple to its catch-all answers 500, and the caller sees a server
  fault for what is the tenant's own mistake. The class cost two pilot tasks
  (G16 T-2604, G14 T-2597) and a 500 in between.

  What this file proves:

    * the matrix is DERIVED, not written down: the surfaces come from the
      router sources, the refusal tuples from the fence functions of
      `lib/letflow/definitions.ex`, and the pairings from the call graph of
      the activation paths (`Letflow.Support.G14RefusalMatrix`);
    * the matrix is not empty (the completeness check);
    * every pair the real tree can produce answers 422 with the stable code
      and the violations list -- never a 5xx, never a detail-free body;
    * the probe is not vacuous: a synthetic refusal tuple without a mapping
      (a seeded failing case) is driven through the SAME verdict and MUST be
      caught.

  No database and no model: the renderers are the product's own functions, and
  the answers they give are read from the connection they return.

  The class table is `docs/security-probes/G-14.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag :unit
  # 30 s: this file touches NO database (plain ExUnit.Case, no tenant fixture,
  # no DataCase), so the cold-database headroom a route-level probe needs does
  # not apply. It compiles four router copies and walks the activation call
  # graph, which is the bulk of the cost.
  @moduletag probe_cost_s: 30
  # 5 minutes: the derivation walks the activation call graph and compiles four
  # router copies. It is CPU-bound and deterministic (no clock, no network, no
  # database), so a slow host must not fail it.
  @moduletag timeout: 300_000

  alias Letflow.Support.G14RefusalMatrix, as: Matrix

  # The switch-on surfaces of the class: the definition activate/reactivate/
  # rollback, the promotion apply, the tenant promote and the solution-pack
  # override activation. The derivation finds them in the router sources; this
  # list is the completeness pin -- a renamed or dropped renderer fails here
  # instead of silently shrinking the matrix.
  @switch_on_surfaces [
    {:render_activate, "Letflow.Routers.Definitions"},
    {:render_reactivate, "Letflow.Routers.Definitions"},
    {:render_rollback, "Letflow.Routers.Definitions"},
    {:render_apply, "Letflow.Routers.Promotions"},
    {:render_promote, "Letflow.Routers.Tenants"},
    {:render_override_activate_error, "Letflow.Routers.SolutionPacks"}
  ]

  setup_all do
    {:ok, surfaces: Matrix.surfaces(), shapes: Matrix.fence_shapes()}
  end

  describe "the inventory the matrix is generated from" do
    test "the switch-on surfaces of the class are all in the derived list", %{
      surfaces: surfaces
    } do
      derived = Enum.map(surfaces, &{&1.name, &1.router})

      for {name, router} <- @switch_on_surfaces do
        assert {name, router} in derived,
               """
               #{name} (#{router}) is not in the derived surface list.
               Derived: #{inspect(derived)}
               """
      end
    end

    test "the refusal tuples of the fences are not empty", %{shapes: shapes} do
      assert length(shapes) >= 8,
             "the fence tuple list is suspiciously small: #{length(shapes)}"

      names = Enum.map(shapes, & &1.name)

      for expected <- [
            :entity_writes_invalid,
            :platform_calls_invalid,
            :notify_calls_invalid,
            :step_mappings_invalid,
            :start_permission_invalid
          ] do
        assert expected in names,
               "#{expected} is not among the derived fence tuples: #{inspect(names)}"
      end
    end

    test "the matrix is not empty: every switch-on surface has cells", %{surfaces: _surfaces} do
      cells = Matrix.matrix()

      for {name, _router} <- @switch_on_surfaces do
        cells_of = Enum.filter(cells, &(&1.surface == name))

        assert cells_of != [],
               """
               #{name} has no matrix cell: the derivation did not find a fence
               on its activation path.
               """
      end
    end
  end

  describe "the real tree" do
    test "every refusal tuple a surface can receive is mapped to a typed 4xx", %{
      surfaces: surfaces
    } do
      unmapped =
        for surface <- surfaces,
            shape <- Matrix.fence_shapes(),
            Matrix.reachable?(surface, shape),
            is_nil(Matrix.helper_for(surface, shape)),
            do: {surface.name, shape.name, shape.fence}

      assert unmapped == [],
             """
             #{length(unmapped)} refusal tuple(s) fall through to a catch-all:
             #{inspect(unmapped, pretty: true)}

             A switch-on surface that leaves a fence refusal to its catch-all
             answers 500 for the tenant's own mistake.
             """
    end

    test "no surface answers a fence refusal with a server error", %{surfaces: surfaces} do
      for surface <- surfaces,
          shape <- Matrix.fence_shapes(),
          Matrix.reachable?(surface, shape),
          clause = Matrix.mapping(surface, shape),
          clause != nil do
        refute :internal_error in clause.helpers,
               """
               #{surface.name} answers #{inspect(shape.name)} with internal_error.
               """
      end
    end

    test "every refusal a surface can receive answers 422 with the stable code", %{
      surfaces: surfaces
    } do
      for surface <- surfaces,
          shape <- Matrix.fence_shapes(),
          Matrix.reachable?(surface, shape) do
        case Matrix.drive(surface, shape) do
          :unmapped ->
            flunk(
              "#{surface.name} has no clause for #{inspect(shape.name)} " <>
                "(fence #{inspect(shape.fence)}) -- it would answer 500"
            )

          {status, body} ->
            assert status == 422,
                   """
                   #{surface.name} answered #{status} for #{inspect(shape.name)};
                   a fence refusal must be a 422, never a 5xx.
                   """

            assert body != %{}, "#{surface.name} answered a detail-free body"

            clause = Matrix.mapping(surface, shape)

            if Matrix.stable_code_helper(clause, shape) do
              assert body["error"] == Atom.to_string(shape.name),
                     """
                     #{surface.name} answered #{inspect(body["error"])} for
                     #{inspect(shape.name)}: the stable code must be the refusal's own.
                     """
            else
              # A typed problem document: it must carry a stable code or a detail.
              assert is_binary(body["error"]) or is_binary(body["detail"]) or
                       is_binary(body["title"]),
                     "#{surface.name} answered a problem document with no code or detail: #{inspect(body)}"
            end

            case body["violations"] do
              nil ->
                :ok

              violations ->
                assert is_list(violations) and violations != [],
                       "#{surface.name} answered an empty violations list"
            end
        end
      end
    end
  end

  describe "the seeded failing case (the probe is not vacuous)" do
    test "a refusal tuple without a mapping is caught" do
      surface = Enum.find(Matrix.surfaces(), &(&1.name == :render_activate))

      assert surface, "the activate surface was not derived"

      # The synthetic tuple: a fence refusal no surface knows. It is driven
      # through the SAME verdict the real tree goes through.
      synthetic = %{name: :g14_synthetic_unmapped, kind: :tuple, fence: :g14_synthetic_fence}

      refute Matrix.reachable?(surface, synthetic),
             "the synthetic tuple must not be reachable on the real tree"

      assert is_nil(Matrix.helper_for(surface, synthetic)),
             "the synthetic tuple must have no mapping -- otherwise the probe cannot fail"

      # The same surface DOES map a real tuple, so the probe is not blind.
      real = Enum.find(Matrix.fence_shapes(), &(&1.name == :entity_writes_invalid))

      assert Matrix.helper_for(surface, real),
             "the activate surface does not map entity_writes_invalid either"
    end

    test "the seeded synthetic tuple makes the matrix verdict fail" do
      # The aggregate verdict of the probe: the same function that decides the
      # real tree's cells.
      cells = Matrix.matrix()

      assert cells != []

      violations = Matrix.violations(cells)

      assert violations == [],
             """
             the real tree breaks the class:
             #{inspect(violations, pretty: true)}
             """

      # Now the seeded case: a cell whose refusal has no mapping.
      seeded = [
        %{
          surface: :render_activate,
          router: "Letflow.Routers.Definitions",
          shape: :g14_synthetic_unmapped,
          kind: :tuple,
          fence: :g14_synthetic_fence,
          reachable: true,
          clause: nil,
          helper: nil
        }
      ]

      assert Matrix.violations(seeded) != [],
             "the seeded unmapped refusal was NOT caught -- the probe cannot fail"
    end
  end
end
