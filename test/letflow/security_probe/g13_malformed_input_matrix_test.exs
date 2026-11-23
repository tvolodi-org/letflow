defmodule Letflow.SecurityProbe.G13MalformedInputMatrixTest do
  @moduledoc """
  G-13: the GENERATED malformed-input / no-5xx matrix over every mutating route
  of the mounted tree (gap G-13 of the team repository's `docs/security-coverage.md` §4).

  The class: a caller's own mistake -- a body the parser cannot read, a media
  type no parser claims, a body over the cap -- must answer a TYPED 4xx on
  every route. It must never answer a 5xx, never leave the caller without an
  answer, and never echo the request back.

  What this file proves:

    * the matrix is DERIVED, not written down: the route list comes from the
      compiled route table of every mounted router
      (`Letflow.Support.RouteInventory.routes/0`), so a route mounted after
      this probe was written is covered by the next run;
    * the matrix is not empty (the completeness check);
    * the real tree breaks no rule of the class;
    * the probe is not vacuous: a seeded failing case (a router shaped like the
      pipeline BEFORE T-2658) is driven through the SAME aggregate entry point
      and the SAME verdict, and the probe must catch it.

  No database and no model: the parser refuses a body BEFORE authentication,
  so the whole matrix runs against the parser surface alone. The shapes that
  reach a handler (a JSON body that is not an object) need an authenticated
  request and live in the sibling file `g13_route_no_5xx_test.exs`.

  The class table is `docs/security-probes/G-13.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag :unit
  # 10 s: this file touches NO database (plain ExUnit.Case, no tenant fixture, no
  # DataCase), so the cold-database headroom the route-level sibling needs does not
  # apply. Measured 0.7 s warm on this host; 10 s is a 14x upper bound, and it keeps
  # the file inside the runner's share of the probe budget (PROBE_BUDGET_S / the
  # number of tagged probes), which is what puts the seeded failing case in the
  # `checks` step of every backend change.
  @moduletag probe_cost_s: 10

  alias Letflow.Plugs.ApiPipeline
  alias Letflow.Support.G13Matrix
  alias Letflow.Support.G13RogueEchoRouter
  alias Letflow.Support.G13RogueRouter

  # The shapes the parser itself refuses: the refusal must be a typed 4xx.
  @refusing_shapes ~w(malformed_json not_utf8_json text_plain xml octet_stream over_cap)

  setup_all do
    {:ok, routes: G13Matrix.mutating_routes(), shapes: G13Matrix.shapes()}
  end

  describe "the inventory the matrix is generated from" do
    test "is not empty: the matrix covers the mutating routes of the mounted tree", %{
      routes: routes
    } do
      assert length(routes) > 200,
             "the mutating route list is suspiciously small: #{length(routes)}"

      assert Enum.all?(routes, &(&1.method in ["POST", "PUT", "PATCH"]))

      # Every route of the list is a real mounted route: the inventory is the
      # compiled route table, not a copy of it.
      assert Enum.all?(routes, &is_atom(&1.router))
      assert Enum.all?(routes, &String.starts_with?(&1.path, "/"))
      assert routes |> Enum.map(& &1.router) |> Enum.uniq() |> length() >= 20
    end

    test "every mutating route of the tree is in the matrix (the list is the tree's own)",
         %{routes: routes} do
      tree =
        Letflow.Support.RouteInventory.routes()
        |> Enum.filter(&(&1.method in ["POST", "PUT", "PATCH"]))
        |> Enum.map(&{&1.method, &1.path})
        |> Enum.sort()

      listed = routes |> Enum.map(&{&1.method, &1.path}) |> Enum.sort()

      assert listed == tree
    end
  end

  describe "the real tree" do
    test "breaks no rule of the class on any mutating route", %{routes: routes, shapes: shapes} do
      outcomes = G13Matrix.run(routes, shapes, G13Matrix.driver(ApiPipeline))

      violations =
        for outcome <- outcomes, outcome.violations != [], do: outcome

      assert violations == [],
             """
             #{length(violations)} matrix cell(s) break the no-5xx class:
             #{inspect(Enum.take(violations, 10), pretty: true)}
             """
    end

    test "a body the parser refuses is answered with a typed problem document", %{
      routes: routes,
      shapes: shapes
    } do
      refusing = Enum.filter(shapes, &(&1.name in @refusing_shapes))

      outcomes = G13Matrix.run(routes, refusing, G13Matrix.driver(ApiPipeline))

      refused =
        for outcome <- outcomes,
            outcome.raised,
            G13Matrix.parser_exception?(outcome.raised),
            do: outcome

      assert refused != [],
             "no route refused a malformed body at all -- the matrix proved nothing"

      for outcome <- refused do
        {expected_status, expected_exceptions} = expected_refusal!(outcome.shape)

        assert outcome.raised.__struct__ in expected_exceptions,
               """
               #{outcome.shape.name} was refused with #{inspect(outcome.raised.__struct__)},
               expected one of #{inspect(expected_exceptions)}
               """

        assert outcome.response != nil,
               "#{outcome.route.method} #{outcome.route.path} refused a body without answering"

        {status, document} = G13Matrix.problem_document(outcome.response)

        # The status the shape DEMANDS (the caps dimension: an over-cap body
        # must be answered 413, an unsupported media type 415) -- not merely
        # the status the exception happens to carry.
        assert status == expected_status,
               "#{outcome.shape.name} answered #{status}, expected #{expected_status}"

        assert status == G13Matrix.refusal_status(outcome.raised)
        assert document["status"] == status
        assert is_binary(document["title"])
        assert is_binary(document["detail"])
        assert is_binary(document["type"])
      end
    end

    test "the answer never carries the request back", %{routes: routes, shapes: shapes} do
      outcomes = G13Matrix.run(routes, shapes, G13Matrix.driver(ApiPipeline))

      for outcome <- outcomes do
        refute outcome.violations |> Enum.member?(:echoed_request),
               "#{outcome.route.method} #{outcome.route.path} echoed the request"
      end
    end
  end

  describe "the seeded failing case (the probe is not vacuous)" do
    test "the rogue router -- the pipeline as it was before T-2658 -- is caught" do
      routes = G13Matrix.mutating_routes()
      shapes = G13Matrix.shapes()

      outcomes = G13Matrix.run(routes, shapes, G13Matrix.driver(G13RogueRouter))

      violations = for outcome <- outcomes, outcome.violations != [], do: outcome

      assert violations != [],
             "the rogue router was NOT caught -- the probe cannot fail and proves nothing"

      names = violations |> Enum.map(& &1.shape.name) |> Enum.uniq() |> Enum.sort()

      assert "malformed_json" in names
      assert "text_plain" in names

      # The rogue's own defect: the refusal never became an answer, and the
      # error escaped the pipeline.
      assert Enum.all?(violations, &(&1.violations != []))
      assert Enum.any?(violations, &(&1.violations |> Enum.member?(:no_answer)))
      assert Enum.any?(violations, &(&1.violations |> Enum.member?(:untyped_refusal)))
    end

    test "the verdict itself fails on a synthetic 5xx and on a bodiless refusal" do
      violation = G13Matrix.violations(%{raised: nil, response: {500, [], "boom"}})
      assert :server_error in violation

      violation = G13Matrix.violations(%{raised: nil, response: nil})
      assert :no_answer in violation

      violation =
        G13Matrix.violations(%{
          raised: %Plug.Parsers.ParseError{},
          response: {400, [], "Bad Request"}
        })

      assert :untyped_refusal in violation

      violation =
        G13Matrix.violations(%{raised: %RuntimeError{}, response: {400, [], "Bad Request"}})

      assert :unexpected_error in violation

      # The refusal must be the one the shape demands: a body over the cap
      # refused with a parse error (400) is the WRONG refusal, even though it
      # is a typed 4xx.
      violation =
        G13Matrix.violations(%{
          raised: %Plug.Parsers.ParseError{},
          response: {400, [], "Bad Request"},
          shape: %{refusal: :too_large, canary: nil}
        })

      assert :wrong_refusal in violation
    end

    test "the echo rule spots an answer that carries the request back" do
      # The real tree never echoes, so an absence-only assertion over it holds
      # even when the rule is dead. The seeded echo router is driven through
      # the SAME aggregate entry point (`run/3`) and the SAME verdict, and the
      # rule MUST fire on it.
      routes = [hd(G13Matrix.mutating_routes())]
      shapes = Enum.filter(G13Matrix.shapes(), & &1.canary)

      assert shapes != [], "no shape carries a canary -- the echo rule cannot be probed"

      outcomes = G13Matrix.run(routes, shapes, G13Matrix.driver(G13RogueEchoRouter))

      assert outcomes != []

      for outcome <- outcomes do
        assert :echoed_request in outcome.violations,
               """
               the echo was NOT spotted on shape #{outcome.shape.name}:
               #{inspect(outcome.violations)}
               """
      end
    end

    test "the echo rule fires on a synthetic answer that carries the canary" do
      # The same rule, driven through the same aggregate entry point with a
      # driver whose answer carries the shape's own canary.
      echoing = fn _route, shape ->
        %{raised: nil, response: {400, [], "echo: " <> shape.canary}}
      end

      shape = Enum.find(G13Matrix.shapes(), &(&1.name == "malformed_json"))

      assert [outcome] =
               G13Matrix.run([hd(G13Matrix.mutating_routes())], [shape], echoing)

      assert :echoed_request in outcome.violations,
             """
             the echo was NOT spotted: #{inspect(outcome.violations)}
             """
    end
  end

  # The refusal a shape demands. A shape that expects no refusal must not have
  # been refused at all, so a refusal there is a defect of the shape list.
  defp expected_refusal!(shape) do
    case G13Matrix.expected_refusal(shape) do
      {status, exceptions} ->
        {status, exceptions}

      nil ->
        flunk("#{shape.name} expects no refusal, so it must not raise a parser exception")
    end
  end
end
