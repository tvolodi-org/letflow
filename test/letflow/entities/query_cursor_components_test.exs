defmodule Letflow.Entities.QueryCursorComponentsTest do
  @moduledoc """
  GH #2844 -- `Letflow.Entities.Query.Cursor` resume-key component decoding.

  A crafted (hand-minted) cursor component that does not fit the sort field's
  Postgres type -- an integer beyond int64, a string with a NUL byte -- used to
  reach the query and surface as a Postgrex/DBConnection error (HTTP 500)
  instead of the existing `{:error, :invalid_cursor}`. See
  `test/specs/GH-2844.md` for the AC -> test table.

  Drives the real path (`Cursor.paginate/5` against real Postgres), minting
  cursors the way `Cursor.build_next_cursor/2` does.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  import Ecto.Query

  @int64_max 9_223_372_036_854_775_807
  @int64_min -9_223_372_036_854_775_808

  @rows [
    %{
      "name" => "a:one",
      "age" => 10,
      "score" => 1.5,
      "qty" => "1.50",
      "born" => "2020-01-01",
      "seen" => "2020-01-01T00:00:00Z",
      "flag" => false
    },
    %{
      "name" => "b:ünï",
      "age" => 20,
      "score" => 2.5,
      "qty" => "2.50",
      "born" => "2021-02-02",
      "seen" => "2021-02-02T10:00:00Z",
      "flag" => false
    },
    %{
      "name" => "c 日本",
      "age" => 30,
      "score" => 3.5,
      "qty" => "3.50",
      "born" => "2022-03-03",
      "seen" => "2022-03-03T12:30:00Z",
      "flag" => true
    }
  ]

  setup do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2844-cursor",
        display_name: "GH-2844 Cursor Component Test Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    assert {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)

    definition = %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "name", type: :string, required: true, queried: true},
        %{name: "age", type: :integer, queried: true},
        %{
          name: "score",
          type: :decimal,
          queried: true,
          decimal_precision: 10,
          decimal_scale: 2
        },
        %{
          name: "qty",
          type: :decimal,
          queried: true,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true
        },
        %{name: "born", type: :date, queried: true},
        %{name: "seen", type: :datetime, queried: true},
        %{name: "flag", type: :boolean, queried: true}
      ]
    }

    assert {:ok, ed} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, _} =
             Definitions.activate_definition(ed.name, Ecto.UUID.generate(), "go-live", schema)

    for values <- @rows do
      assert {:ok, %{record: _}} =
               Records.create_record(
                 %{
                   entity_type: "widget",
                   field_values: values,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )
    end

    assert {:ok, allowlist} = Allowlist.load("widget", schema)
    %{schema: schema, allowlist: allowlist}
  end

  # Mints "EQ:<mint_time_us>:<resume_key_json>" from raw JSON text, so a test can
  # carry bytes Jason.encode! would refuse (invalid UTF-8).
  defp mint_json(resume_key_json) do
    Cursor.cursor_prefix()
    |> Pagination.build_raw_cursor(System.system_time(:microsecond), resume_key_json)
    |> Pagination.encode_cursor()
  end

  defp mint(components), do: mint_json(Jason.encode!(components))

  defp page(ctx, field, cursor) do
    request = %{entity_type: "widget", sort: [%{field: field, dir: :asc}]}
    assert {:ok, compiled} = Compiler.compile(request, ctx.schema, :all)

    Cursor.paginate(
      request,
      compiled,
      ctx.allowlist,
      %{page_size: 10, cursor: cursor},
      ctx.schema
    )
  end

  defp page_all(ctx, field, dir) do
    request = %{entity_type: "widget", sort: [%{field: field, dir: dir}]}
    assert {:ok, compiled} = Compiler.compile(request, ctx.schema, :all)
    do_page_all(ctx, request, compiled, nil, [])
  end

  defp do_page_all(ctx, request, compiled, cursor, acc) do
    assert {:ok, pg} =
             Cursor.paginate(
               request,
               compiled,
               ctx.allowlist,
               %{page_size: 1, cursor: cursor},
               ctx.schema
             )

    acc = acc ++ Enum.map(pg.items, & &1.field_values["name"])

    case pg.next_cursor do
      nil -> acc
      next -> do_page_all(ctx, request, compiled, next, acc)
    end
  end

  defp id, do: Ecto.UUID.generate()

  describe "AC1 -- integer component outside int64 answers :invalid_cursor" do
    for {label, value} <- [
          {"int64 max + 1", @int64_max + 1},
          {"int64 min - 1", @int64_min - 1},
          {"huge positive float 1.0e30", 1.0e30},
          {"huge negative float -1.0e30", -1.0e30},
          {"float just above int64 max (9.3e18)", 9.3e18}
        ] do
      test "#{label} -> {:error, :invalid_cursor}", ctx do
        assert page(ctx, "age", mint([unquote(value), id()])) == {:error, :invalid_cursor}
      end
    end

    test "huge integer literal in the JSON text (not float-formatted) -> :invalid_cursor", ctx do
      json = "[100000000000000000000000000000000000000, \"#{id()}\"]"
      assert page(ctx, "age", mint_json(json)) == {:error, :invalid_cursor}
    end
  end

  describe "AC2 -- string component with NUL / invalid UTF-8 answers :invalid_cursor" do
    test "NUL byte inside a string sort component", ctx do
      assert page(ctx, "name", mint(["ab" <> <<0>> <> "cd", id()])) == {:error, :invalid_cursor}
    end

    test "lone NUL string component", ctx do
      assert page(ctx, "name", mint([<<0>>, id()])) == {:error, :invalid_cursor}
    end

    test "invalid UTF-8 bytes in a string sort component (raw JSON text)", ctx do
      json = "[\"" <> <<255, 254>> <> "\", \"#{id()}\"]"
      refute String.valid?(json)
      assert page(ctx, "name", mint_json(json)) == {:error, :invalid_cursor}
    end

    test "lone surrogate escape in a string sort component", ctx do
      json = ~s(["\\ud800", "#{id()}"])
      assert page(ctx, "name", mint_json(json)) == {:error, :invalid_cursor}
    end

    test "NUL byte in the id (tie-break) component", ctx do
      assert page(ctx, "name", mint(["a", "abc" <> <<0>> <> "def"])) == {:error, :invalid_cursor}
    end

    test "invalid UTF-8 in the id (tie-break) component (raw JSON text)", ctx do
      json = "[\"a\", \"" <> <<255, 254>> <> "\"]"
      assert page(ctx, "name", mint_json(json)) == {:error, :invalid_cursor}
    end
  end

  describe "AC2b -- type-confused components (same catch-all clause) answer :invalid_cursor" do
    test "string component for an :integer sort field", ctx do
      assert page(ctx, "age", mint(["abc", id()])) == {:error, :invalid_cursor}
    end

    test "string component for a :boolean sort field", ctx do
      assert page(ctx, "flag", mint(["maybe", id()])) == {:error, :invalid_cursor}
    end

    test "boolean component for a :decimal sort field (Postgrex Numeric FunctionClauseError)",
         ctx do
      assert page(ctx, "score", mint([true, id()])) == {:error, :invalid_cursor}
    end

    test "boolean component for a :string sort field", ctx do
      assert page(ctx, "name", mint([true, id()])) == {:error, :invalid_cursor}
    end
  end

  describe "AC3 -- valid cursors are unchanged (round trip across pages)" do
    test "integer: pages in order, one row per page", ctx do
      assert page_all(ctx, "age", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "integer descending", ctx do
      assert page_all(ctx, "age", :desc) == ["c 日本", "b:ünï", "a:one"]
    end

    test "string incl. ':' and non-ASCII", ctx do
      assert page_all(ctx, "name", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "decimal", ctx do
      assert page_all(ctx, "score", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "decimal (strict field, string-valued)", ctx do
      assert page_all(ctx, "qty", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "date", ctx do
      assert page_all(ctx, "born", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "datetime (ISO string with ':' components)", ctx do
      assert page_all(ctx, "seen", :asc) == ["a:one", "b:ünï", "c 日本"]
    end

    test "boolean (ties broken by record_id, no row lost or repeated)", ctx do
      names = page_all(ctx, "flag", :asc)
      assert Enum.sort(names) == Enum.sort(Enum.map(@rows, & &1["name"]))
      assert List.last(names) == "c 日本"
    end

    test "int64 max as a hand-minted component is accepted: nothing sorts after it", ctx do
      assert {:ok, pg} = page(ctx, "age", mint([@int64_max, id()]))
      assert pg.items == []
    end

    test "int64 min as a hand-minted component is accepted: every row sorts after it", ctx do
      assert {:ok, pg} = page(ctx, "age", mint([@int64_min, id()]))
      assert length(pg.items) == 3
    end

    test "an in-range float for an :integer field keeps its truncating behaviour", ctx do
      assert {:ok, pg} = page(ctx, "age", mint([15.0, id()]))
      assert Enum.map(pg.items, & &1.field_values["age"]) == [20, 30]
    end

    test "string component containing ':' and unicode is accepted verbatim", ctx do
      assert {:ok, pg} = page(ctx, "name", mint(["b:ünï", id()]))
      assert is_list(pg.items)
    end
  end

  describe "AC4 -- malformed decimal / date / datetime components still answer :invalid_cursor" do
    for v <- ["abc", "NaN", "Infinity", "1e99999", ""] do
      test "decimal #{inspect(v)}", ctx do
        assert page(ctx, "score", mint([unquote(v), id()])) == {:error, :invalid_cursor}
      end
    end

    for v <- ["abc", "NaN", "1e99999"] do
      test "strict decimal #{inspect(v)}", ctx do
        assert page(ctx, "qty", mint([unquote(v), id()])) == {:error, :invalid_cursor}
      end
    end

    for v <- ["not-a-date", "2020-13-45", "2020-02-30", "", 20_200_101] do
      test "date #{inspect(v)}", ctx do
        assert page(ctx, "born", mint([unquote(v), id()])) == {:error, :invalid_cursor}
      end
    end

    for v <- ["garbage", "2020-01-01", "2020-01-01T25:00:00Z", "", 12_345] do
      test "datetime #{inspect(v)}", ctx do
        assert page(ctx, "seen", mint([unquote(v), id()])) == {:error, :invalid_cursor}
      end
    end

    test "integer given null / list / object", ctx do
      for bad <- [nil, [1], %{"a" => 1}] do
        assert page(ctx, "age", mint([bad, id()])) == {:error, :invalid_cursor}
      end
    end
  end

  describe "probe -- extreme-but-parseable date / datetime components" do
    # Recorded in the spec rather than asserted as a bug: a component Elixir
    # parses but Postgres cannot represent would be the same defect class as AC1.
    for {label, field, v} <- [
          {"date year 0000", "born", "0000-01-01"},
          {"date year 9999", "born", "9999-12-31"},
          {"datetime year 0000", "seen", "0000-01-01T00:00:00Z"},
          {"datetime year 9999", "seen", "9999-12-31T23:59:59Z"},
          {"datetime with offset", "seen", "2020-01-01T00:00:00+05:00"}
        ] do
      test "#{label} does not raise", ctx do
        result = page(ctx, unquote(field), mint([unquote(v), id()]))
        assert match?({:ok, _}, result) or result == {:error, :invalid_cursor}
      end
    end
  end
end
