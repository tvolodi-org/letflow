defmodule Letflow.Routers.EntitiesDecimalStrictReadsTest do
  @moduledoc """
  GH #2654 PR-2 -- the reads side of `decimal_strict` over HTTP
  (`lib/letflow/design/gh2654-decimal-exact-strings.md` sections 2.6-2.8, decision 0060):
  record bodies / query items / export render a strict decimal as its canonical string
  (S1, S5, S10), filters compare exactly (S6), keyset cursors order numerically and a
  tampered cursor is a 400 (C1), aggregates over a strict field are exact (S7). Each
  surface has a NON-strict twin that must stay byte-identical (numbers in, numbers out).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "GH-2654 decimal strict reads tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2654r-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2654 reads user",
        email: "gh2654r-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    ctx = %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }

    seed_active!(ctx, "ledger", [
      %{
        name: "qty",
        type: :decimal,
        decimal_precision: 10,
        decimal_scale: 2,
        decimal_strict: true,
        queried: true
      },
      # strict but NOT queried: the renderer must take its specs from the definition
      %{
        name: "hidden",
        type: :decimal,
        decimal_precision: 10,
        decimal_scale: 2,
        decimal_strict: true
      },
      %{name: "note", type: :string, queried: true}
    ])

    seed_active!(ctx, "plain", [
      %{
        name: "amount",
        type: :decimal,
        decimal_precision: 10,
        decimal_scale: 2,
        queried: true
      },
      %{name: "note", type: :string, queried: true}
    ])

    ctx
  end

  defp seed_active!(ctx, name, fields) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: name, display_name: String.capitalize(name), fields: fields},
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "go", ctx.schema_name)
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp post_record(ctx, type, field_values),
    do: request(:post, "/api/v1/entities/records/#{type}", ctx, %{"field_values" => field_values})

  defp insert!(ctx, type, field_values) do
    conn = post_record(ctx, type, field_values)
    assert conn.status == 201, conn.resp_body
    body_of(conn)["record_id"]
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)
  defp aggregate(ctx, body), do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp export(ctx, type),
    do: request(:post, "/api/v1/entities/records/#{type}/export", ctx, %{})

  defp qtys(conn) do
    assert conn.status == 200, conn.resp_body
    Enum.map(body_of(conn)["items"], & &1["field_values"]["qty"])
  end

  defp filter_ledger(ctx, op, value),
    do:
      query(ctx, %{
        "entity_type" => "ledger",
        "filters" => [%{"field" => "qty", "op" => op, "value" => value}],
        "sort" => [%{"field" => "qty", "dir" => "asc"}]
      })

  # Overwrites the stored field_values everywhere the row lives (the shared projection and,
  # when the type has one, its per-type table) -- a state the strict write path can never
  # produce (design 2.6: the defensive decoder is unreachable by contract).
  defp force_stored!(ctx, type, record_id, values) do
    schema = ctx.schema_name

    {1, _} =
      Repo.update_all(
        from(r in Latest, where: r.entity_type == ^type and r.record_id == ^record_id),
        [set: [field_values: values]],
        prefix: schema
      )

    {:ok, table} = TenantProvisioning.table_name_for_entity_type(type)

    if TenantProvisioning.entity_table_exists?(schema, table) do
      Repo.query!(
        ~s(UPDATE "#{schema}"."#{table}" SET field_values = $1 WHERE record_id = $2),
        [values, Ecto.UUID.dump!(record_id)]
      )
    end

    :ok
  end

  describe "S1 / S5 -- record bodies, query items and export render strict decimals as strings" do
    test "create response, query items and export all carry the canonical string; the non-strict twin keeps numbers" do
      ctx = tenant_ctx("gh2654r-s1")

      created = post_record(ctx, "ledger", %{"qty" => "2.5", "hidden" => 7, "note" => "a"})
      assert body_of(created)["field_values"]["qty"] == "2.50"
      assert body_of(created)["field_values"]["hidden"] == "7.00"

      insert!(ctx, "plain", %{"amount" => 2.5, "note" => "a"})

      conn = query(ctx, %{"entity_type" => "ledger"})

      assert [%{"field_values" => %{"qty" => "2.50", "hidden" => "7.00"}}] =
               body_of(conn)["items"]

      plain = query(ctx, %{"entity_type" => "plain"})
      assert [%{"field_values" => %{"amount" => 2.5}}] = body_of(plain)["items"]

      exported = export(ctx, "ledger")

      assert [%{"field_values" => %{"qty" => "2.50", "hidden" => "7.00"}}] =
               body_of(exported)["records"]

      exported_plain = export(ctx, "plain")
      assert [%{"field_values" => %{"amount" => 2.5}}] = body_of(exported_plain)["records"]
    end

    test "update and delete responses render the strict field too" do
      ctx = tenant_ctx("gh2654r-s1b")
      id = insert!(ctx, "ledger", %{"qty" => "1"})

      updated =
        request(:put, "/api/v1/entities/records/ledger/#{id}", ctx, %{
          "field_values" => %{"qty" => 4}
        })

      assert updated.status == 200, updated.resp_body
      assert body_of(updated)["field_values"]["qty"] == "4.00"

      deleted = request(:delete, "/api/v1/entities/records/ledger/#{id}", ctx)
      assert deleted.status == 200, deleted.resp_body
      assert body_of(deleted)["field_values"]["qty"] == "4.00"
    end
  end

  describe "FieldGrants -- a restricted strict field stays redacted" do
    test "the renderer neither unmasks nor crashes on the redaction sentinel" do
      ctx = tenant_ctx("gh2654r-fg", ["TASK_WORKER"])

      seed_active!(ctx, "vault", [
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true,
          queried: true
        },
        %{
          name: "secret",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true
        }
      ])

      {:ok, _} =
        Letflow.Entities.Records.create_record(
          %{
            entity_type: "vault",
            field_values: %{"qty" => "1.5", "secret" => "99.9"},
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "vault",
            field_name: "secret",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema_name
      )

      conn = query(ctx, %{"entity_type" => "vault"})
      assert conn.status == 200, conn.resp_body
      assert [%{"field_values" => values}] = body_of(conn)["items"]
      assert values["qty"] == "1.50"
      refute inspect(values) =~ "99"
      refute values["secret"] == "99.90"
    end
  end

  describe "S10 -- the defensive decoder (a stored number under a strict field)" do
    test "renders the legacy number as the padded string, even for a field that is not queried" do
      ctx = tenant_ctx("gh2654r-s10")
      id = insert!(ctx, "ledger", %{"qty" => "1.00"})
      force_stored!(ctx, "ledger", id, %{"qty" => 2.5, "hidden" => 3, "note" => "x"})

      conn = query(ctx, %{"entity_type" => "ledger"})

      assert [%{"field_values" => %{"qty" => "2.50", "hidden" => "3.00", "note" => "x"}}] =
               body_of(conn)["items"]

      assert [%{"field_values" => %{"hidden" => "3.00"}}] =
               body_of(export(ctx, "ledger"))["records"]
    end

    test "an unparseable stored value passes through untouched; nothing raises" do
      ctx = tenant_ctx("gh2654r-s10b")
      id = insert!(ctx, "ledger", %{"qty" => "1.00"})
      force_stored!(ctx, "ledger", id, %{"qty" => "n/a", "hidden" => %{"x" => 1}})

      conn = export(ctx, "ledger")
      assert conn.status == 200

      assert [%{"field_values" => %{"qty" => "n/a", "hidden" => %{"x" => 1}}}] =
               body_of(conn)["records"]
    end
  end

  describe "S6 -- filters compare exactly" do
    test "string and integer literals on eq / gt / gte / lt / neq / in / not_in" do
      ctx = tenant_ctx("gh2654r-s6")
      for q <- ["2.50", "10.00", "0.10", "7"], do: insert!(ctx, "ledger", %{"qty" => q})

      assert qtys(filter_ledger(ctx, "eq", "2.50")) == ["2.50"]
      assert qtys(filter_ledger(ctx, "eq", "2.5")) == ["2.50"]
      assert qtys(filter_ledger(ctx, "eq", 10)) == ["10.00"]
      assert qtys(filter_ledger(ctx, "gt", "2.4999")) == ["2.50", "7.00", "10.00"]
      assert qtys(filter_ledger(ctx, "gte", "7")) == ["7.00", "10.00"]
      assert qtys(filter_ledger(ctx, "lt", "2.50")) == ["0.10"]
      assert qtys(filter_ledger(ctx, "neq", "2.50")) == ["0.10", "7.00", "10.00"]
      assert qtys(filter_ledger(ctx, "in", ["2.5", 10])) == ["2.50", "10.00"]
      assert qtys(filter_ledger(ctx, "not_in", ["2.5", "10"])) == ["0.10", "7.00"]
    end

    test "a float literal, a non-grammar string or an injection attempt is a 422 that does not echo the value" do
      ctx = tenant_ctx("gh2654r-s6b")
      insert!(ctx, "ledger", %{"qty" => "2.50"})

      for bad <- [2.5, "1; DROP TABLE x", "1e3", " 1", "NaN", true, %{"a" => 1}, nil] do
        conn = filter_ledger(ctx, "eq", bad)
        assert conn.status == 422, inspect(bad)
        assert conn.resp_body =~ "qty"
        refute conn.resp_body =~ "DROP"
      end

      conn = filter_ledger(ctx, "in", ["2.50", 1.5])
      assert conn.status == 422
    end

    test "the non-strict twin is unchanged: a number literal matches" do
      ctx = tenant_ctx("gh2654r-s6c")
      insert!(ctx, "plain", %{"amount" => 2.5})

      conn =
        query(ctx, %{
          "entity_type" => "plain",
          "filters" => [%{"field" => "amount", "op" => "eq", "value" => 2.5}]
        })

      assert [%{"field_values" => %{"amount" => 2.5}}] = body_of(conn)["items"]
    end
  end

  describe "C1 / sort / cursor" do
    test "a keyset cursor over a strict field pages in numeric order (10.00 after 7.00 and 2.50)" do
      ctx = tenant_ctx("gh2654r-c1")

      for q <- ["2.50", "10.00", "0.10", "7.00", "100.00"],
          do: insert!(ctx, "ledger", %{"qty" => q})

      page = fn cursor ->
        conn =
          query(ctx, %{
            "entity_type" => "ledger",
            "sort" => [%{"field" => "qty", "dir" => "asc"}],
            "page_size" => 2,
            "cursor" => cursor
          })

        assert conn.status == 200, conn.resp_body
        body = body_of(conn)
        {Enum.map(body["items"], & &1["field_values"]["qty"]), body["next_cursor"]}
      end

      {p1, c1} = page.(nil)
      {p2, c2} = page.(c1)
      {p3, c3} = page.(c2)
      assert p1 ++ p2 ++ p3 == ["0.10", "2.50", "7.00", "10.00", "100.00"]
      assert c3 == nil
    end

    test "a non-strict decimal field holding floats round-trips across pages" do
      ctx = tenant_ctx("gh2654r-c1b")
      for a <- [66.6666, 2.5, 100.25, 0.5], do: insert!(ctx, "plain", %{"amount" => a})

      page = fn cursor ->
        conn =
          query(ctx, %{
            "entity_type" => "plain",
            "sort" => [%{"field" => "amount", "dir" => "asc"}],
            "page_size" => 2,
            "cursor" => cursor
          })

        assert conn.status == 200, conn.resp_body
        body = body_of(conn)
        {Enum.map(body["items"], & &1["field_values"]["amount"]), body["next_cursor"]}
      end

      {p1, c1} = page.(nil)
      {p2, _} = page.(c1)
      assert p1 ++ p2 == [0.5, 2.5, 66.6666, 100.25]
    end

    test "a tampered decimal cursor component is a 400, never a crash (any decimal field)" do
      ctx = tenant_ctx("gh2654r-c1c")
      for q <- ["1.00", "2.00", "3.00"], do: insert!(ctx, "ledger", %{"qty" => q})
      for a <- [1.5, 2.5, 3.5], do: insert!(ctx, "plain", %{"amount" => a})

      for {type, field} <- [{"ledger", "qty"}, {"plain", "amount"}] do
        first =
          query(ctx, %{
            "entity_type" => type,
            "sort" => [%{"field" => field, "dir" => "asc"}],
            "page_size" => 1
          })

        cursor = body_of(first)["next_cursor"]
        assert is_binary(cursor)

        {:ok, raw} = Base.url_decode64(cursor, padding: false)
        [head, rest] = String.split(raw, "EQ:", parts: 2)
        [ts, json] = String.split(rest, ":", parts: 2)
        [_value | tail] = Jason.decode!(json)

        for bad <- ["abc", "1; DROP", "", "NaN", "1e", "--1"] do
          tampered =
            Base.url_encode64(head <> "EQ:" <> ts <> ":" <> Jason.encode!([bad | tail]),
              padding: false
            )

          conn =
            query(ctx, %{
              "entity_type" => type,
              "sort" => [%{"field" => field, "dir" => "asc"}],
              "page_size" => 1,
              "cursor" => tampered
            })

          assert conn.status == 400, "#{type} #{inspect(bad)} -> #{conn.status} #{conn.resp_body}"
        end
      end
    end
  end

  describe "S7 -- aggregates over a strict field" do
    test "ten times 0.10 sums to exactly 1.00; min / max / group_by are padded; avg is as Postgres computes it" do
      ctx = tenant_ctx("gh2654r-s7")
      for _ <- 1..10, do: insert!(ctx, "ledger", %{"qty" => "0.10", "note" => "n"})

      conn =
        aggregate(ctx, %{
          "entity_type" => "ledger",
          "aggregates" => [
            %{"fn" => "sum", "field" => "qty"},
            %{"fn" => "min", "field" => "qty"},
            %{"fn" => "max", "field" => "qty"},
            %{"fn" => "avg", "field" => "qty"},
            %{"fn" => "count"}
          ],
          "group_by" => [%{"field" => "qty"}]
        })

      assert conn.status == 200, conn.resp_body
      assert %{"results" => [entry]} = body_of(conn)
      assert entry["group"] == %{"qty" => "0.10"}
      values = entry["values"]
      assert values["sum_qty"] == "1.00"
      assert values["min_qty"] == "0.10"
      assert values["max_qty"] == "0.10"
      assert Decimal.equal?(Decimal.new(values["avg_qty"]), Decimal.new("0.10"))
      assert values["count_none"] == 10
    end

    test "a sum of strict values is scale-padded and a null aggregate stays null" do
      ctx = tenant_ctx("gh2654r-s7b")

      empty =
        aggregate(ctx, %{
          "entity_type" => "ledger",
          "aggregates" => [%{"fn" => "sum", "field" => "qty"}]
        })

      assert [%{"values" => %{"sum_qty" => nil}}] = body_of(empty)["results"]

      insert!(ctx, "ledger", %{"qty" => 3})
      insert!(ctx, "ledger", %{"qty" => "4.5"})

      conn =
        aggregate(ctx, %{
          "entity_type" => "ledger",
          "aggregates" => [%{"fn" => "sum", "field" => "qty"}]
        })

      assert [%{"values" => %{"sum_qty" => "7.50"}}] = body_of(conn)["results"]
    end

    test "the non-strict twin is unchanged: the sum is Postgres' own, not scale-padded" do
      ctx = tenant_ctx("gh2654r-s7c")
      insert!(ctx, "plain", %{"amount" => 2.5})
      insert!(ctx, "plain", %{"amount" => 2.5})

      conn =
        aggregate(ctx, %{
          "entity_type" => "plain",
          "aggregates" => [%{"fn" => "sum", "field" => "amount"}]
        })

      assert [%{"values" => %{"sum_amount" => "5.0"}}] = body_of(conn)["results"]
    end
  end
end
