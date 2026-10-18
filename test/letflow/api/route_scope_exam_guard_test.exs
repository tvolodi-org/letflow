defmodule Letflow.Api.RouteScopeExamGuardTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, ruling SEC-518-R1 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.6, 3.7; spec
  `test/specs/REQ-518-2c-i-a.md`, T-C15 walk half): the additive route-walk rule
  `{:exam_route_reclassified, row}` of `Letflow.Api.RouteScope.audit_routes/2`.

  The literal `:all` at the three exam data-access helpers is safe only because EVERY route
  mounted by the exam module is `:tenant_wide` (a scoped principal is refused before exam code
  runs). The rule fails the walk when any route under `/modules/exam` is any other class:

    * the real table has exam routes and none is flagged;
    * a real exam route re-declared `:filter`, `:self_service`, `{:resolver, _}` or `:admin_plane`
      is flagged (and the rule does not hide the other rules' errors);
    * a route ADDED later under `/modules/exam/...` is covered, not only the eight current ones;
    * a route exactly at the bare prefix `/modules/exam` is covered (SEC 2c-i-a F-2), and a
      sibling prefix such as `/modules/examx/...` or a non-module route is NOT flagged.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  setup_all do
    routes = RouteInventory.routes()
    {:ok, routes: routes, snapshot: RouteInventory.read_snapshot()}
  end

  defp exam_rows(routes), do: Enum.filter(routes, &String.starts_with?(&1.path, "/modules/exam/"))

  defp exam_errors(errors), do: Enum.filter(errors, &match?({:exam_route_reclassified, _}, &1))

  # a default-sourced :tenant_wide row (listed in the seeded snapshot) or a declared row
  defp seeded(path, class) do
    %{
      router: Letflow.Modules.Exam.Router,
      method: "GET",
      path: path,
      key: :ExamSessionRead,
      declared: class,
      class: class,
      source: :declared
    }
  end

  describe "the real table" do
    test "has the exam routes, all :tenant_wide, and none is flagged", %{
      routes: routes,
      snapshot: snapshot
    } do
      exam = exam_rows(routes)

      assert length(exam) >= 8
      assert Enum.all?(exam, &(&1.class == :tenant_wide))
      assert exam_errors(RouteScope.audit_routes(routes, snapshot)) == []
    end
  end

  describe "a re-declared exam route is flagged" do
    for class <- [
          :filter,
          :self_service,
          {:resolver, {Letflow.Api.RouteScope, :class_of}},
          :admin_plane
        ] do
      test "a real exam route turned #{inspect(class)}", %{routes: routes, snapshot: snapshot} do
        class = unquote(Macro.escape(class))
        [target | _] = exam_rows(routes)

        swapped =
          Enum.map(
            routes,
            &if(&1 == target,
              do: %{&1 | class: class, source: :declared, declared: class},
              else: &1
            )
          )

        errors = exam_errors(RouteScope.audit_routes(swapped, snapshot))

        assert [{:exam_route_reclassified, %{path: path, class: ^class}}] = errors
        assert path == target.path
      end
    end

    test "the rule is additive: the snapshot rules still report their own errors alongside", %{
      routes: routes,
      snapshot: snapshot
    } do
      [target | _] = exam_rows(routes)

      swapped =
        Enum.map(
          routes,
          &if(&1 == target,
            do: %{&1 | class: :filter, source: :declared, declared: :filter},
            else: &1
          )
        )

      errors = RouteScope.audit_routes(swapped, snapshot)

      assert Enum.any?(errors, &match?({:exam_route_reclassified, %{class: :filter}}, &1))
      assert Enum.any?(errors, &match?({:unexpected_filter_route, %{class: :filter}}, &1))
      assert Enum.any?(errors, &match?({:stale_snapshot, _}, &1))
    end

    test "every exam route is covered: re-declaring each one in turn is flagged exactly once", %{
      routes: routes,
      snapshot: snapshot
    } do
      for target <- exam_rows(routes) do
        swapped =
          Enum.map(
            routes,
            &if(&1 == target,
              do: %{&1 | class: :self_service, source: :declared, declared: :self_service},
              else: &1
            )
          )

        assert [{:exam_route_reclassified, row}] =
                 exam_errors(RouteScope.audit_routes(swapped, snapshot))

        assert row.path == target.path and row.method == target.method
      end
    end
  end

  describe "a route added later" do
    test "a NEW route under /modules/exam/ declared :filter is flagged", %{
      routes: routes,
      snapshot: snapshot
    } do
      new_route = seeded("/modules/exam/brand-new-report", :filter)

      assert [{:exam_route_reclassified, ^new_route}] =
               exam_errors(RouteScope.audit_routes(routes ++ [new_route], snapshot))
    end

    test "a new exam route left as :tenant_wide (declared) is fine", %{
      routes: routes,
      snapshot: snapshot
    } do
      ok = seeded("/modules/exam/brand-new-report", :tenant_wide)

      assert exam_errors(RouteScope.audit_routes(routes ++ [ok], snapshot)) == []
    end

    test "a route exactly at the bare prefix /modules/exam is covered too (SEC 2c-i-a F-2)", %{
      routes: routes,
      snapshot: snapshot
    } do
      bare = seeded("/modules/exam", :filter)

      assert [{:exam_route_reclassified, ^bare}] =
               exam_errors(RouteScope.audit_routes(routes ++ [bare], snapshot))
    end
  end

  describe "the rule is exact about the module prefix" do
    test "a sibling prefix, another module and a core route of the same class are not flagged", %{
      routes: routes,
      snapshot: snapshot
    } do
      others = [
        seeded("/modules/examx/things", :filter),
        seeded("/modules/exam-two/things", :filter),
        seeded("/modules/other/exam/things", :filter),
        seeded("/exam/things", :filter)
      ]

      assert exam_errors(RouteScope.audit_routes(routes ++ others, snapshot)) == []
    end
  end
end
