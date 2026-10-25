defmodule Letflow.IntegrationMappingsTest do
  @moduledoc """
  REQ-565 slice 1 (GH #3201): `Letflow.IntegrationMappings` -- the pure `apply_mapping/2`
  (T-A1), definition validation (T-V*), inert text (T-I*) and the per-tenant store (T-S*, T-C1).
  `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.IntegrationMappings, as: IM
  alias Letflow.TenantFixture

  defp defn(rules, extra \\ %{}),
    do: Map.merge(%{"name" => "m", "direction" => "outbound", "rules" => rules}, extra)

  defp invalid(attrs), do: IM.validate_definition(attrs)
  defp from(path, to \\ "x"), do: %{"from" => path, "to" => to}
  defp const(v, to \\ "x"), do: %{"const" => v, "to" => to}

  describe "T-A1 apply_mapping/2 (pure, table driven)" do
    @payload %{
      "order" => %{"id" => 7, "lines" => [%{"sku" => "A"}, %{"sku" => "B"}], "note" => nil},
      "n" => 1
    }

    @cases [
      {"from nested", [%{"from" => "order.id", "to" => "id"}], %{"id" => 7}},
      {"from array index", [%{"from" => "order.lines.1.sku", "to" => "sku"}], %{"sku" => "B"}},
      {"index out of range leaves key out", [%{"from" => "order.lines.5.sku", "to" => "sku"}],
       %{}},
      {"non-digit segment on a list is missing", [%{"from" => "order.lines.x", "to" => "y"}],
       %{}},
      {"missing path leaves key out",
       [%{"from" => "nope.deeper", "to" => "y"}, %{"from" => "n", "to" => "n"}], %{"n" => 1}},
      {"present nil is copied", [%{"from" => "order.note", "to" => "note"}], %{"note" => nil}},
      {"const string", [%{"const" => "hi", "to" => "x"}], %{"x" => "hi"}},
      {"const number", [%{"const" => 3.5, "to" => "x"}], %{"x" => 3.5}},
      {"const boolean", [%{"const" => false, "to" => "x"}], %{"x" => false}},
      {"const null", [%{"const" => nil, "to" => "x"}], %{"x" => nil}},
      {"nested to builds objects",
       [%{"from" => "n", "to" => "a.b.c"}, %{"const" => "k", "to" => "a.d"}],
       %{"a" => %{"b" => %{"c" => 1}, "d" => "k"}}},
      {"digit to segment is an object key", [%{"from" => "n", "to" => "a.0"}],
       %{"a" => %{"0" => 1}}},
      {"unnamed source fields are absent", [%{"from" => "n", "to" => "n"}], %{"n" => 1}},
      {"required present", [%{"from" => "n", "to" => "n", "required" => true}], %{"n" => 1}},
      {"empty rules", [], %{}}
    ]

    for {name, rules, expected} <- @cases do
      test name do
        assert {:ok, unquote(Macro.escape(expected))} ==
                 IM.apply_mapping(%{rules: unquote(Macro.escape(rules))}, @payload)
      end
    end

    test "required missing returns the 0-based rule index and no value" do
      rules = [from("n", "n"), Map.put(from("order.zzz", "z"), "required", true)]
      assert {:error, {:required_missing, 1}} == IM.apply_mapping(%{rules: rules}, @payload)
    end
  end

  describe "T-V validation: 422 cases (pure function)" do
    test "name boundaries 0 / 1 / 100 / 101 and non-binary" do
      assert {:error, {:invalid, :name}} = invalid(defn([], %{"name" => ""}))
      assert {:ok, _} = invalid(defn([], %{"name" => "a"}))
      assert {:ok, _} = invalid(defn([], %{"name" => String.duplicate("a", 100)}))

      assert {:error, {:invalid, :name}} =
               invalid(defn([], %{"name" => String.duplicate("a", 101)}))

      assert {:error, {:invalid, :name}} = invalid(defn([], %{"name" => 5}))
    end

    test "direction" do
      assert {:error, {:invalid, :direction}} = invalid(defn([], %{"direction" => "sideways"}))
      assert {:ok, _} = invalid(defn([], %{"direction" => "inbound"}))
    end

    test "100 rules ok, 101 refused" do
      rules = fn n -> for i <- 1..n, do: const("v", "k#{i}") end
      assert {:ok, _} = invalid(defn(rules.(100)))
      assert {:error, {:invalid, :too_many_rules}} = invalid(defn(rules.(101)))
      assert {:error, {:invalid, :rules}} = invalid(defn("nope"))
    end

    test "path length 200 ok, 201 refused (to and from)" do
      ok = String.duplicate("a", 200)
      bad = String.duplicate("a", 201)
      assert {:ok, _} = invalid(defn([from(ok)]))
      assert {:error, {:invalid, :path_length}} = invalid(defn([from(bad)]))
      assert {:error, {:invalid, :path_length}} = invalid(defn([const("v", bad)]))
    end

    test "8 segments ok, 9 refused" do
      assert {:ok, _} = invalid(defn([from("a.b.c.d.e.f.g.h")]))
      assert {:error, {:invalid, :path_depth}} = invalid(defn([from("a.b.c.d.e.f.g.h.i")]))
      assert {:error, {:invalid, :path_depth}} = invalid(defn([const("v", "a.b.c.d.e.f.g.h.i")]))
    end

    test "rule shape: neither or both of from/const, missing to, non-map, bad const, required" do
      for rule <- [
            %{"to" => "x"},
            %{"to" => "x", "from" => "a", "const" => 1},
            %{"from" => "a"},
            "str",
            const(%{"a" => 1}),
            const([1]),
            Map.put(from("a"), "required", "yes"),
            Map.put(const("v"), "required", true),
            %{"to" => 5, "from" => "a"}
          ] do
        assert {:error, {:invalid, :rule_shape}} = invalid(defn([rule])), inspect(rule)
      end
    end

    test "a const of nil counts as present (not neither)" do
      assert {:ok, _} = invalid(defn([const(nil)]))
      assert {:error, {:invalid, :rule_shape}} = invalid(defn([Map.put(const(nil), "from", "a")]))
    end

    test "unknown rule key" do
      assert {:error, {:invalid, :unknown_rule_key}} =
               invalid(defn([Map.put(from("a"), "expr", "1")]))
    end

    test "bad segment characters and empty segments" do
      for p <- ["a..b", "a b", "a/b", ".a", "a.", "", "a[0]", "é"] do
        assert {:error, {:invalid, :path_segment}} = invalid(defn([from(p)])), inspect(p)
      end
    end

    test "duplicate and prefix to paths refused; sibling prefixes in a segment are fine" do
      assert {:error, {:invalid, :to_conflict}} = invalid(defn([const(1, "a"), const(2, "a")]))
      assert {:error, {:invalid, :to_conflict}} = invalid(defn([const(1, "a"), const(2, "a.b")]))
      assert {:error, {:invalid, :to_conflict}} = invalid(defn([const(1, "a.b"), const(2, "a")]))
      assert {:ok, _} = invalid(defn([const(1, "a.b"), const(2, "a.bc"), const(3, "a.c")]))
    end

    test "unknown top-level keys, a tenant_id included, are dropped" do
      assert {:ok, out} = invalid(defn([], %{"tenant_id" => "x", "zzz" => 1}))
      assert Enum.sort(Map.keys(out)) == ["direction", "name", "rules"]
    end

    test "non-map definition" do
      assert {:error, {:invalid, _}} = invalid(nil)
    end
  end

  describe "T-I inert text" do
    @inert ["\#{1+1}", "{{x}}", "$(x)"]

    test "T-I1 stored verbatim as a const and applied unchanged" do
      for s <- @inert do
        assert {:ok, %{"rules" => [%{"const" => ^s}] = rules}} = invalid(defn([const(s)]))
        assert {:ok, %{"x" => ^s}} = IM.apply_mapping(%{rules: rules}, %{})
      end
    end

    test "T-I2 refused in a from path" do
      for s <- @inert ++ ["$.a[?(@.b)]"] do
        assert {:error, {:invalid, :path_segment}} = invalid(defn([from(s)])), s
      end
    end

    test "T-I3 no evaluation, sandbox or dynamic apply in the source" do
      for file <- [
            "lib/letflow/integration_mappings.ex",
            "lib/letflow/integration_mappings/mapping.ex"
          ] do
        src = File.read!(file)
        # code only: drop the moduledoc, which names what is NOT used
        code = Regex.replace(~r/@moduledoc """.*?"""/s, src, "")

        for banned <- ["Code.eval", "Sandbox", "Lua", ":erlang.apply", "Code.string_to"] do
          refute code =~ banned, "#{file} contains #{banned}"
        end
      end
    end
  end

  describe "T-S store, scoping, audit" do
    setup do
      {:ok,
       a: TenantFixture.provisioned_tenant!(slug_prefix: "r565-a"),
       b: TenantFixture.provisioned_tenant!(slug_prefix: "r565-b")}
    end

    test "T-S1 two tenants, same name, each sees only its own", %{a: a, b: b} do
      assert {:ok, ma} = IM.create(defn([const("A")], %{"name" => "same"}), nil, a.schema_name)
      assert {:ok, mb} = IM.create(defn([const("B")], %{"name" => "same"}), nil, b.schema_name)
      assert Enum.map(IM.list(a.schema_name), & &1.id) == [ma.id]
      assert Enum.map(IM.list(b.schema_name), & &1.id) == [mb.id]
      assert {:error, :not_found} = IM.get(ma.id, b.schema_name)
      assert {:error, :not_found} = IM.get(mb.id, a.schema_name)
      assert {:error, :not_found} = IM.delete(ma.id, nil, b.schema_name)
      assert {:ok, %{tenant_id: tid}} = IM.get(ma.id, a.schema_name)
      assert tid == a.tenant_id
    end

    test "duplicate name: 422 and one row, no second audit entry", %{a: a} do
      assert {:ok, _} = IM.create(defn([]), nil, a.schema_name)
      assert {:error, {:invalid, :name_taken}} = IM.create(defn([const(1)]), nil, a.schema_name)
      assert length(IM.list(a.schema_name)) == 1
      assert length(audit(a)) == 1
    end

    test "T-S2 every Repo data call in the context passes prefix:" do
      lines =
        "lib/letflow/integration_mappings.ex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/Repo\.(all|get|insert|update|delete|one|query)/))

      assert length(lines) >= 5
      for l <- lines, do: assert(l =~ "prefix: prefix", l)
    end

    test "T-S3 / T-C1 columns, tenant_id NOT NULL, unique name index, no credential column", %{
      a: a
    } do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'integration_mappings'",
          [a.schema_name]
        )

      cols = Map.new(rows, fn [c, n] -> {c, n} end)

      assert Enum.sort(Map.keys(cols)) ==
               ~w(direction id inserted_at name rules tenant_id updated_at updated_by)

      assert cols["tenant_id"] == "NO"
      refute Enum.any?(Map.keys(cols), &(&1 =~ ~r/secret|key|token|password|credential/))

      %{rows: idx} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = 'integration_mappings_name_index'",
          [a.schema_name]
        )

      assert [[index_def]] = idx
      assert index_def =~ "UNIQUE"
    end

    test "T-C1 moduledoc says a const is never a secret" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(IM)
      assert doc =~ "never a secret"
    end

    test "audit entries carry identity only, never rules or consts", %{a: a} do
      marker = "CONST-MARKER-9f3"
      actor = Ecto.UUID.generate()
      {:ok, m} = IM.create(defn([const(marker)]), actor, a.schema_name)

      {:ok, _} =
        IM.update(m.id, defn([const(marker)], %{"name" => "renamed"}), actor, a.schema_name)

      {:ok, _} = IM.delete(m.id, actor, a.schema_name)

      entries = audit(a)
      assert Enum.sort(Enum.map(entries, & &1.action)) == ["create", "delete", "update"]
      assert Enum.all?(entries, &(&1.actor_id == actor and &1.resource_id == m.id))
      refute inspect(entries) =~ marker
      refute inspect(entries) =~ "rules"
    end
  end

  defp audit(tenant) do
    {:ok, %{items: items}} =
      Audit.list_entries(%{
        prefix: tenant.schema_name,
        page_size: 100,
        resource_type: "integration_mapping"
      })

    items
  end
end
