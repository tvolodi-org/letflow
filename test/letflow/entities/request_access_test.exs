defmodule Letflow.Entities.RequestAccessTest do
  @moduledoc """
  GH #2700 -- unit tests for `Letflow.Entities.RequestAccess.check/4` (the one
  gate for a caller's query-shaped request): step order, constant work, the
  `exempt?` rule and fail-closed behaviour. HTTP-level behaviour lives in
  `test/letflow/routers/entities_type_access_joins_test.exs`.
  Spec: `test/specs/GH2700-type-access.md` (T-17).

  Definitions only (no promoted tables): the gate reads definitions, grants and
  restrictions, never record tables.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.RequestAccess
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @denied {:error, :entity_type_not_found}

  # -- fixtures -------------------------------------------------------------

  defp tenant! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "ra", display_name: "RequestAccess")

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "ra-#{Ecto.UUID.generate()}",
        display_name: "RA",
        email: "ra-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    t = %{schema: tenant.schema_name, user_id: user.id}

    define!(t, %{
      name: "q",
      display_name: "Q",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    define!(t, %{
      name: "tag",
      display_name: "Tag",
      fields: [%{name: "label", type: :string, queried: true}]
    })

    define!(t, %{
      name: "q_tag",
      display_name: "QTag",
      fields: [%{name: "q_id", type: :string}, %{name: "tag_id", type: :string}],
      foreign_keys: [
        %{name: "fk_q", field: "q_id", references_entity: "q"},
        %{name: "fk_tag", field: "tag_id", references_entity: "tag"}
      ]
    })

    define!(t, %{
      name: "child",
      display_name: "Child",
      fields: [%{name: "q_id", type: :string}],
      foreign_keys: [%{name: "child_fk", field: "q_id", references_entity: "q"}]
    })

    define!(t, %{
      name: "other",
      display_name: "Other",
      fields: [%{name: "o", type: :string, queried: true}]
    })

    t
  end

  defp define!(t, definition) do
    {:ok, d} =
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: definition, created_by: t.user_id},
        t.schema
      )

    {:ok, _} = Definitions.activate_definition(d.name, t.user_id, "go-live", t.schema)
    :ok
  end

  defp restrict_type!(t, entity_type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema
    )
  end

  defp restrict_field!(t, entity_type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema
    )
  end

  defp principal(t), do: %{user_id: t.user_id, prefix: t.schema}

  defp check(t, request, kind \\ :row, exempt? \\ false),
    do: RequestAccess.check(principal(t), kind, request, %{exempt?: exempt?})

  defp direct(type, fk), do: %{entity_type: type, fk: fk}
  defp through(type, via, fk), do: %{entity_type: type, through: via, fk: fk}

  # SQL strings of every query the test process runs inside `fun`
  defp capture_sql(fun) do
    id = "gh2700-ra-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:letflow, :repo, :query],
        fn _event, _m, %{query: sql}, _cfg ->
          if self() == parent and is_binary(sql), do: send(parent, {:sql, sql})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:sql, sql} -> drain([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # one `fk_defs/2` read per type starts with an `artifact_activations` lookup, found or
  # not (a MISSING type stops there; a found one goes on to `entity_definitions`)
  defp definition_reads(sqls), do: Enum.count(sqls, &(&1 =~ "artifact_activations"))

  # -- tests ----------------------------------------------------------------

  describe "unrestricted tenant" do
    test "a visible request reaches the field guard and returns its result" do
      t = tenant!()
      request = %{entity_type: "q", join: [direct("child", "child_fk")]}

      assert {:ok, %{sets: sets, exempted: []}} = check(t, request)
      assert Map.has_key?(sets, "q")
      assert Map.has_key?(sets, "child")
    end
  end

  describe "T-17 every position is gated; denied and absent are the same exit" do
    test "primary, direct target, far target and through each refuse when denied, identically to an absent type" do
      t = tenant!()

      cases = [
        {"q", %{entity_type: "q"}, %{entity_type: "ghost"}},
        {"child", %{entity_type: "q", join: [direct("child", "child_fk")]},
         %{entity_type: "q", join: [direct("ghost", "child_fk")]}},
        {"tag", %{entity_type: "q", join: [through("tag", "q_tag", "fk_tag")]},
         %{entity_type: "q", join: [through("ghost", "q_tag", "fk_tag")]}},
        {"q_tag", %{entity_type: "q", join: [through("tag", "q_tag", "fk_tag")]},
         %{entity_type: "q", join: [through("tag", "ghost", "fk_tag")]}}
      ]

      for {restricted, denied_request, absent_request} <- cases do
        Repo.delete_all("entity_type_restrictions", prefix: t.schema)
        restrict_type!(t, restricted)

        assert check(t, denied_request) == @denied, "denied #{restricted}"
        assert check(t, absent_request) == @denied, "absent twin of #{restricted}"
        assert check(t, denied_request, :aggregate) == @denied
      end
    end

    test "a wrong fk on a denied target, and a wrong earlier fk plus an absent later target, are the same refusal" do
      t = tenant!()
      restrict_type!(t, "tag")

      # a VISIBLE target with a wrong fk is not the gate's refusal: the type
      # gate passes and the relation error comes from the field guard's walk
      refute check(t, %{entity_type: "q", join: [direct("child", "bogus_fk")]}) == @denied

      denied =
        check(t, %{
          entity_type: "q",
          join: [direct("child", "bogus_fk"), through("tag", "q_tag", "fk_tag")]
        })

      absent =
        check(t, %{
          entity_type: "q",
          join: [direct("child", "bogus_fk"), through("ghost", "q_tag", "fk_tag")]
        })

      assert denied == @denied
      assert absent == @denied
    end

    test "another user's grant does not lift the denial for the caller" do
      t = tenant!()
      restrict_type!(t, "child")

      other =
        %User{}
        |> Ecto.Changeset.change(%{
          username: "ra-other-#{Ecto.UUID.generate()}",
          display_name: "RA2",
          email: "ra-other-#{Ecto.UUID.generate()}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: t.schema)

      Repo.insert_all(
        "user_entity_type_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(other.id),
            entity_type: "child",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: t.schema
      )

      request = %{entity_type: "q", join: [direct("child", "child_fk")]}
      assert check(t, request) == @denied

      assert {:ok, _} =
               RequestAccess.check(%{user_id: other.id, prefix: t.schema}, :row, request, %{
                 exempt?: false
               })
    end
  end

  describe "T-17 ordering" do
    test "a join-shape error beats a denied type" do
      t = tenant!()
      restrict_type!(t, "child")

      five = for i <- 1..5, do: direct("child#{i}", "fk")
      assert check(t, %{entity_type: "q", join: five}) == {:error, {:too_many_joins, 5}}

      dup = [direct("child", "child_fk"), direct("child", "child_fk")]

      assert check(t, %{entity_type: "q", join: dup}) ==
               {:error, {:duplicate_join_target, "child"}}

      deep = [Map.put(direct("child", "child_fk"), :join, [])]
      assert check(t, %{entity_type: "q", join: deep}) == {:error, :join_depth_exceeded}
    end

    test "a denied type beats a restricted field; with the type visible the field guard refuses" do
      t = tenant!()
      restrict_field!(t, "q", "stem")
      request = %{entity_type: "q", filters: [%{field: "stem", op: :eq, value: 1}]}

      assert check(t, request) == {:error, :request_field_restricted}

      restrict_type!(t, "q")
      assert check(t, request) == @denied
    end

    test "exempt? is forwarded only to the field step and never lifts a type denial" do
      t = tenant!()
      restrict_field!(t, "q", "stem")
      request = %{entity_type: "q", filters: [%{field: "stem", op: :eq, value: 1}]}

      assert {:error, :request_field_restricted} = check(t, request, :row, false)
      assert {:ok, %{exempted: [_ref]}} = check(t, request, :row, true)

      restrict_type!(t, "q")
      assert check(t, request, :row, true) == @denied
      assert check(t, request, :row, false) == @denied
    end

    test "an error from the denied-set read refuses (never default-allow)" do
      t = tenant!()

      bad = %{
        user_id: t.user_id,
        prefix: "tenant_missing_#{Ecto.UUID.generate() |> String.replace("-", "")}"
      }

      assert {:error, :invalid_schema_name} =
               RequestAccess.check(bad, :row, %{entity_type: "q"}, %{exempt?: false})
    end

    test "a malformed or unwalked request fails closed and never raises" do
      t = tenant!()

      for request <- [
            %{entity_type: "q", having: 1},
            %{entity_type: "q", join: "child"},
            %{entity_type: "q", join: [%{fk: "x"}]},
            %{entity_type: "q", join: [:nope]},
            %{entity_type: "q", join: [%{entity_type: "child", through: 7}]},
            %{entity_type: "q", join: [%{fk: "x"} | for(i <- 1..5, do: direct("c#{i}", "f"))]}
          ] do
        assert check(t, request) == {:error, :request_clause_unwalked}, inspect(request)
      end
    end
  end

  describe "T-17 constant work (R1): a definition read for EVERY distinct type, no short-circuit" do
    test "denied-first, absent-first, denied-middle and absent-last refuse with the same number of definition reads" do
      t = tenant!()
      restrict_type!(t, "q")
      restrict_type!(t, "tag")

      denied_first =
        %{
          entity_type: "q",
          join: [direct("child", "child_fk"), through("other", "q_tag", "fk_tag")]
        }

      absent_first =
        %{
          entity_type: "ghost",
          join: [direct("child", "child_fk"), through("other", "q_tag", "fk_tag")]
        }

      # 4 distinct types each: primary, child, q_tag/other
      denied_mid = %{
        entity_type: "other",
        join: [direct("child", "child_fk"), through("tag", "q_tag", "fk_tag")]
      }

      absent_last = %{
        entity_type: "other",
        join: [direct("child", "child_fk"), through("ghost", "q_tag", "fk_tag")]
      }

      reads =
        for request <- [denied_first, absent_first, denied_mid, absent_last] do
          {result, sqls} = capture_sql(fn -> check(t, request) end)
          assert result == @denied
          definition_reads(sqls)
        end

      assert [n, n, n, n] = reads
      # one read per distinct type (4 distinct types in each request)
      assert n == 4
    end

    test "a request whose only denied type is the last still reads every earlier type" do
      t = tenant!()
      restrict_type!(t, "other")

      request = %{
        entity_type: "q",
        join: [direct("child", "child_fk"), through("other", "q_tag", "fk_tag")]
      }

      {result, sqls} = capture_sql(fn -> check(t, request) end)
      assert result == @denied
      assert definition_reads(sqls) == 4
    end
  end
end
