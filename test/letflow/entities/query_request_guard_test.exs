defmodule Letflow.Entities.Query.RequestGuardTest do
  @moduledoc """
  GH #2697 PR 1 -- unit tests for `Letflow.Entities.Query.RequestGuard` (the
  pure restricted-field request walker), `Compiler.join_relations/3` and
  `Letflow.Entities.FieldPolicy`. HTTP-level behaviour lives in
  `test/letflow/routers/entities_query_restricted_walker_test.exs`.
  Spec: `test/specs/GH2697-query-restricted.md`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.FieldPolicy
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Query.RequestGuard
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp sentinel, do: FieldGrants.redacted_sentinel()

  defp set(fields), do: MapSet.new(fields)

  # ---------------------------------------------------------------------------
  # registry + typespec tripwire (T-26, unit half)
  # ---------------------------------------------------------------------------

  defp typespec_keys(module, type_name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    {_kind, {^type_name, {:type, _, :map, fields}, _args}} =
      Enum.find(types, fn {_kind, {name, _form, _args}} -> name == type_name end)

    fields
    |> Enum.map(fn {:type, _, kind, [{:atom, _, key}, _value]}
                   when kind in [:map_field_exact, :map_field_assoc] ->
      key
    end)
    |> Enum.sort()
  end

  describe "registry (T-26)" do
    test "registry keys are exactly the documented key sets" do
      assert Enum.sort(RequestGuard.registry_keys(:row)) ==
               Enum.sort([:entity_type, :filters, :sort, :join])

      assert Enum.sort(RequestGuard.registry_keys(:aggregate)) ==
               Enum.sort([:entity_type, :aggregates, :group_by, :filters, :join])
    end

    test "every key of Types.query_request is in the :row registry, and vice versa" do
      assert typespec_keys(Letflow.Entities.Query.Types, :query_request) ==
               Enum.sort(RequestGuard.registry_keys(:row))
    end

    test "every key of Compiler.aggregate_request is in the :aggregate registry, and vice versa" do
      assert typespec_keys(Compiler, :aggregate_request) ==
               Enum.sort(RequestGuard.registry_keys(:aggregate))
    end

    test "an unknown kind has no registry (FunctionClauseError, not a silent empty list)" do
      assert_raise FunctionClauseError, fn -> apply(RequestGuard, :registry_keys, [:other]) end
    end
  end

  # ---------------------------------------------------------------------------
  # field_refs/3, pure (no join -> no I/O)
  # ---------------------------------------------------------------------------

  describe "field_refs/3 walks every position (no join)" do
    test "row: filters then sort refs, tagged with the primary and the clause" do
      request = %{
        entity_type: "answer_option",
        filters: [%{field: "a", op: :eq, value: 1}, %{field: "b", op: :eq, value: 2}],
        sort: [%{field: "c", dir: :asc}],
        join: []
      }

      assert {:ok, refs} = RequestGuard.field_refs(request, :row, "unused")

      assert refs == [
               %{entity_type: "answer_option", field: "a", clause: :filter},
               %{entity_type: "answer_option", field: "b", clause: :filter},
               %{entity_type: "answer_option", field: "c", clause: :sort}
             ]
    end

    test "aggregate: filters, group_by and measure fields; a count target contributes none" do
      request = %{
        entity_type: "t",
        aggregates: [%{fn: :count}, %{fn: :sum, field: "m"}],
        group_by: [%{field: "g"}],
        filters: [%{field: "f", op: :eq, value: 1}]
      }

      assert {:ok, refs} = RequestGuard.field_refs(request, :aggregate, "unused")

      assert Enum.sort_by(refs, & &1.field) == [
               %{entity_type: "t", field: "f", clause: :filter},
               %{entity_type: "t", field: "g", clause: :group_by},
               %{entity_type: "t", field: "m", clause: :aggregate_measure}
             ]
    end

    test "only entity_type -> no refs; nil and empty clause lists -> no refs" do
      assert {:ok, []} = RequestGuard.field_refs(%{entity_type: "t"}, :row, "p")

      assert {:ok, []} =
               RequestGuard.field_refs(
                 %{entity_type: "t", filters: [], sort: [], join: []},
                 :row,
                 "p"
               )

      assert {:ok, []} =
               RequestGuard.field_refs(%{entity_type: "t", filters: nil, sort: nil}, :row, "p")
    end
  end

  describe "T-27 fail closed on anything unwalked" do
    test "an unlisted key -> :request_clause_unwalked (row)" do
      for key <- [:having, :distinct, :search, :unredacted, :group_by, :aggregates] do
        request = Map.put(%{entity_type: "t", filters: []}, key, [])

        assert {:error, :request_clause_unwalked} = RequestGuard.field_refs(request, :row, "p"),
               "row request carrying #{key} must not be walked as if known"
      end
    end

    test "an unlisted key -> :request_clause_unwalked (aggregate)" do
      for key <- [:having, :distinct, :search, :sort] do
        request = Map.put(%{entity_type: "t", aggregates: []}, key, [])

        assert {:error, :request_clause_unwalked} =
                 RequestGuard.field_refs(request, :aggregate, "p")
      end
    end

    test "the key check runs before any ref is produced even when other clauses are fine" do
      request = %{entity_type: "t", filters: [%{field: "ok", op: :eq, value: 1}], having: 1}
      assert {:error, :request_clause_unwalked} = RequestGuard.field_refs(request, :row, "p")
    end

    test "a string-keyed or malformed element fails closed" do
      for bad <- [
            %{entity_type: "t", filters: [%{"field" => "x"}]},
            %{entity_type: "t", filters: [%{op: :eq}]},
            %{entity_type: "t", filters: [%{field: :atom_not_binary}]},
            %{entity_type: "t", sort: ["x"]},
            %{entity_type: "t", filters: "not-a-list"},
            %{entity_type: "t", join: "not-a-list"}
          ] do
        assert {:error, :request_clause_unwalked} = RequestGuard.field_refs(bad, :row, "p")
      end

      assert {:error, :request_clause_unwalked} =
               RequestGuard.field_refs(%{entity_type: "t", aggregates: ["x"]}, :aggregate, "p")

      assert {:error, :request_clause_unwalked} =
               RequestGuard.field_refs(%{entity_type: "t", group_by: [%{}]}, :aggregate, "p")
    end

    test "no entity_type, a non-binary entity_type, or an unknown kind fails closed" do
      assert {:error, :request_clause_unwalked} = RequestGuard.field_refs(%{}, :row, "p")

      assert {:error, :request_clause_unwalked} =
               RequestGuard.field_refs(%{entity_type: :t}, :row, "p")

      assert {:error, :request_clause_unwalked} =
               RequestGuard.field_refs(%{entity_type: "t"}, :bogus, "p")
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2700 T-14 / T-15 -- request_entity_types/2 and the registry
  # classification tripwire. Spec: test/specs/GH2700-type-access.md
  # ---------------------------------------------------------------------------

  describe "GH #2700 T-14 request_entity_types/2" do
    test "primary only, direct, through (both names), in request order" do
      assert {:ok, ["p"]} = RequestGuard.request_entity_types(%{entity_type: "p"}, :row)

      assert {:ok, ["p", "j"]} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", join: [%{entity_type: "j", fk: "f"}]},
                 :row
               )

      assert {:ok, ["p", "t", "far"]} =
               RequestGuard.request_entity_types(
                 %{
                   entity_type: "p",
                   join: [%{entity_type: "far", through: "t", fk: "f"}]
                 },
                 :row
               )

      assert {:ok, ["p"]} =
               RequestGuard.request_entity_types(%{entity_type: "p", join: []}, :aggregate)
    end

    test "duplicates are removed and the primary stays first" do
      assert {:ok, ["p", "t", "far", "j"]} =
               RequestGuard.request_entity_types(
                 %{
                   entity_type: "p",
                   join: [
                     %{entity_type: "far", through: "t", fk: "f"},
                     %{entity_type: "j", through: "t", fk: "g"}
                   ]
                 },
                 :row
               )

      # the primary named again as a join target is not listed twice
      assert {:ok, ["p", "j"]} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", join: [%{entity_type: "p", through: "j", fk: "f"}]},
                 :row
               )
    end

    test "aggregate kind is walked with its own registry" do
      assert {:ok, ["p", "j"]} =
               RequestGuard.request_entity_types(
                 %{
                   entity_type: "p",
                   aggregates: [%{fn: :count}],
                   join: [%{entity_type: "j", fk: "f"}]
                 },
                 :aggregate
               )

      # :aggregates is not a :row key
      assert {:error, :request_clause_unwalked} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", aggregates: [%{fn: :count}]},
                 :row
               )
    end

    test "malformed shapes return :request_clause_unwalked and never raise" do
      for bad <- [
            %{entity_type: "p", join: "j"},
            %{entity_type: "p", join: [%{fk: "f"}]},
            %{entity_type: "p", join: ["j"]},
            %{entity_type: "p", join: [%{entity_type: :j, fk: "f"}]},
            %{entity_type: "p", join: [%{entity_type: "j", through: :t, fk: "f"}]},
            %{entity_type: "p", join: [%{entity_type: "j", through: nil, fk: "f"}]},
            %{entity_type: "p", having: 1},
            %{entity_type: "p", join: nil, distinct: true},
            %{join: [%{entity_type: "j", fk: "f"}]},
            %{entity_type: :p},
            %{}
          ] do
        assert {:error, :request_clause_unwalked} =
                 RequestGuard.request_entity_types(bad, :row),
               inspect(bad)
      end

      assert {:error, :request_clause_unwalked} =
               RequestGuard.request_entity_types(%{entity_type: "p"}, :bogus)
    end

    test "walk precedes the shape check: a malformed element TOGETHER WITH too many / duplicate joins is unwalked, not a crash" do
      too_many = for i <- 1..5, do: %{entity_type: "j#{i}", fk: "f"}

      assert {:error, :request_clause_unwalked} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", join: [%{fk: "no_entity_type"} | too_many]},
                 :row
               )

      assert {:error, :request_clause_unwalked} =
               RequestGuard.request_entity_types(
                 %{
                   entity_type: "p",
                   join: [%{fk: "x"}, %{entity_type: "j", fk: "f"}, %{entity_type: "j", fk: "f"}]
                 },
                 :row
               )

      assert {:error, :request_clause_unwalked} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", join: [:not_a_map | too_many]},
                 :row
               )
    end

    test "well-formed shape errors come after the walk, through Compiler.join_entity_types/1" do
      too_many = for i <- 1..5, do: %{entity_type: "j#{i}", fk: "f"}

      assert {:error, {:too_many_joins, 5}} =
               RequestGuard.request_entity_types(%{entity_type: "p", join: too_many}, :row)

      assert {:error, {:duplicate_join_target, "j"}} =
               RequestGuard.request_entity_types(
                 %{
                   entity_type: "p",
                   join: [%{entity_type: "j", fk: "f"}, %{entity_type: "j", fk: "g"}]
                 },
                 :row
               )

      assert {:error, :join_depth_exceeded} =
               RequestGuard.request_entity_types(
                 %{entity_type: "p", join: [%{entity_type: "j", fk: "f", join: []}]},
                 :row
               )
    end

    test "Compiler.join_entity_types/1 is pure: shape errors, then [through, entity_type] per clause" do
      assert {:ok, []} = Compiler.join_entity_types([])

      assert {:ok, ["t", "far", "j"]} =
               Compiler.join_entity_types([
                 %{entity_type: "far", through: "t", fk: "f"},
                 %{entity_type: "j", fk: "g"}
               ])

      assert {:error, {:duplicate_join_target, "j"}} =
               Compiler.join_entity_types([
                 %{entity_type: "j", fk: "f"},
                 %{entity_type: "j", fk: "g"}
               ])
    end
  end

  describe "GH #2700 T-15 registry classification tripwire" do
    test "every registry key of both kinds is classified as carrying or not carrying entity types" do
      for kind <- [:row, :aggregate], key <- RequestGuard.registry_keys(kind) do
        assert RequestGuard.entity_type_class(key) in [:carries_entity_types, :no_entity_types],
               "registry key #{inspect(key)} (#{kind}) has no entity-type classification"
      end
    end

    test "the classification is the documented one" do
      assert RequestGuard.entity_type_class(:entity_type) == :carries_entity_types
      assert RequestGuard.entity_type_class(:join) == :carries_entity_types

      for key <- [:filters, :sort, :group_by, :aggregates] do
        assert RequestGuard.entity_type_class(key) == :no_entity_types
      end
    end

    test "a synthetic extra key is unclassified, so the tripwire would fail for it" do
      assert RequestGuard.entity_type_class(:synthetic_new_clause) == :unclassified

      refute RequestGuard.entity_type_class(:synthetic_new_clause) in [
               :carries_entity_types,
               :no_entity_types
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # restriction_entity_types/2, restricted_refs/2, check/2
  # ---------------------------------------------------------------------------

  describe "restriction_entity_types/2" do
    test "primary + governing entity of each ref + every join target, distinct" do
      refs = [
        %{entity_type: "child", field: "fk", clause: :join_on},
        %{entity_type: "p", field: "x", clause: :filter}
      ]

      request = %{
        entity_type: "p",
        join: [%{entity_type: "child", fk: "f"}, %{entity_type: "other", fk: "g"}]
      }

      assert Enum.sort(RequestGuard.restriction_entity_types(refs, request)) ==
               ["child", "other", "p"]

      assert RequestGuard.restriction_entity_types([], %{entity_type: "p"}) == ["p"]
    end
  end

  describe "check/2 and restricted_refs/2" do
    @ref %{entity_type: "p", field: "secret", clause: :filter}

    test "ok when no ref is a member of its entity's set" do
      assert :ok = RequestGuard.check([@ref], %{"p" => set(["other"])})
      assert :ok = RequestGuard.check([], %{})
    end

    test "error when any ref is a member; restricted_refs returns exactly those" do
      ok_ref = %{entity_type: "p", field: "fine", clause: :sort}
      sets = %{"p" => set(["secret"])}

      assert {:error, :request_field_restricted} = RequestGuard.check([ok_ref, @ref], sets)
      assert RequestGuard.restricted_refs([ok_ref, @ref], sets) == [@ref]
    end

    test "membership is per governing entity, never the primary's set by default" do
      ref = %{entity_type: "child", field: "secret", clause: :join_on}

      # secret restricted on p only: a child-governed ref must NOT be refused
      assert :ok = RequestGuard.check([ref], %{"p" => set(["secret"]), "child" => set([])})
      # and restricted on child: refused
      assert {:error, :request_field_restricted} =
               RequestGuard.check([ref], %{"p" => set([]), "child" => set(["secret"])})
    end

    test "T-28 a ref whose entity type has no loaded set fails closed" do
      assert {:error, :request_field_restricted} = RequestGuard.check([@ref], %{})

      assert {:error, :request_field_restricted} =
               RequestGuard.check([@ref], %{"someone_else" => set([])})

      assert RequestGuard.restricted_refs([@ref], %{}) == [@ref]
    end

    test "exact string membership: a differently-cased name is not a member" do
      assert :ok =
               RequestGuard.check([%{@ref | field: "SECRET"}], %{"p" => set(["secret"])})
    end
  end

  # ---------------------------------------------------------------------------
  # DB-backed: join_relations/3, field_refs with join, FieldPolicy
  # ---------------------------------------------------------------------------

  defp tenant! do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "rg", display_name: "Guard Unit")

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "rg-#{Ecto.UUID.generate()}",
        display_name: "RG",
        email: "rg-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    %{schema: tenant.schema_name, user_id: user.id, tenant: tenant}
  end

  defp user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "rg2-#{Ecto.UUID.generate()}",
      display_name: "RG2",
      email: "rg2-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
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

  # Definitions only: join_relations/3 reads fk_defs, never tables.
  defp m2m!(t) do
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
  end

  describe "Compiler.join_relations/3" do
    setup do
      t = tenant!()
      m2m!(t)
      {:ok, t: t}
    end

    test "empty joins -> {:ok, []} with no definition reads needed", %{t: t} do
      assert {:ok, []} = Compiler.join_relations([], "does_not_exist", t.schema)
    end

    test "direct join, declaring side = join target: one hop owned by the TARGET", %{t: t} do
      joins = [%{entity_type: "child", fk: "child_fk"}]

      assert {:ok, [%{exposed_key: "child", hops: [hop]}]} =
               Compiler.join_relations(joins, "q", t.schema)

      assert hop == %{owner_entity_type: "child", fk_field: "q_id"}
    end

    test "direct join, declaring side = primary: one hop owned by the PRIMARY", %{t: t} do
      joins = [%{entity_type: "q", fk: "child_fk"}]

      assert {:ok, [%{exposed_key: "q", hops: [hop]}]} =
               Compiler.join_relations(joins, "child", t.schema)

      assert hop == %{owner_entity_type: "child", fk_field: "q_id"}
    end

    test "through join: two hops in order [near, far], both owned by the through entity",
         %{t: t} do
      joins = [%{entity_type: "tag", through: "q_tag", fk: "fk_tag"}]

      assert {:ok, [%{exposed_key: "tag", hops: [near, far]}]} =
               Compiler.join_relations(joins, "q", t.schema)

      assert near == %{owner_entity_type: "q_tag", fk_field: "q_id"}
      assert far == %{owner_entity_type: "q_tag", fk_field: "tag_id"}
    end

    test "unknown fk name -> {:field_not_allowed, name}", %{t: t} do
      assert {:error, {:field_not_allowed, "nope"}} =
               Compiler.join_relations([%{entity_type: "child", fk: "nope"}], "q", t.schema)
    end

    test "through entity with no fk to the primary -> :no_through_relation", %{t: t} do
      assert {:error, {:no_through_relation, "q_tag", "child"}} =
               Compiler.join_relations(
                 [%{entity_type: "tag", through: "q_tag", fk: "fk_tag"}],
                 "child",
                 t.schema
               )
    end

    test "nonexistent primary with a through join -> :entity_type_not_found (never a distinguishing 422)",
         %{t: t} do
      assert {:error, :entity_type_not_found} =
               Compiler.join_relations(
                 [%{entity_type: "tag", through: "q_tag", fk: "fk_tag"}],
                 "ghost",
                 t.schema
               )
    end

    test "nonexistent primary with a direct join -> :entity_type_not_found",
         %{t: t} do
      assert {:error, :entity_type_not_found} =
               Compiler.join_relations(
                 [%{entity_type: "child", fk: "child_fk"}],
                 "ghost",
                 t.schema
               )
    end

    test "join shape is checked first: over-wide and duplicate-target requests", %{t: t} do
      wide = for i <- 1..5, do: %{entity_type: "child#{i}", fk: "child_fk"}
      assert {:error, {:too_many_joins, 5}} = Compiler.join_relations(wide, "q", t.schema)

      dup = [%{entity_type: "child", fk: "child_fk"}, %{entity_type: "child", fk: "child_fk"}]

      assert {:error, {:duplicate_join_target, "child"}} =
               Compiler.join_relations(dup, "q", t.schema)
    end

    test "field_refs/3 turns hops into :join_on refs governed by the DECLARING entity", %{t: t} do
      request = %{entity_type: "q", join: [%{entity_type: "tag", through: "q_tag", fk: "fk_tag"}]}

      assert {:ok, refs} = RequestGuard.field_refs(request, :row, t.schema)

      assert refs == [
               %{entity_type: "q_tag", field: "q_id", clause: :join_on},
               %{entity_type: "q_tag", field: "tag_id", clause: :join_on}
             ]

      request = %{entity_type: "q", join: [%{entity_type: "child", fk: "child_fk"}]}
      assert {:ok, [ref]} = RequestGuard.field_refs(request, :row, t.schema)
      assert ref == %{entity_type: "child", field: "q_id", clause: :join_on}
    end

    test "field_refs/3 propagates a join error unchanged", %{t: t} do
      request = %{entity_type: "q", join: [%{entity_type: "child", fk: "nope"}]}

      assert {:error, {:field_not_allowed, "nope"}} =
               RequestGuard.field_refs(request, :row, t.schema)
    end
  end

  # ---------------------------------------------------------------------------
  # T-40 FieldPolicy
  # ---------------------------------------------------------------------------

  defp restrict!(t, entity_type, field) do
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

  defp grant!(t, user_id, entity_type, field) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema
    )
  end

  describe "T-40 FieldPolicy" do
    setup do
      t = tenant!()
      restrict!(t, "p", "secret")
      {:ok, t: t, principal: %{user_id: t.user_id, prefix: t.schema}}
    end

    test "redact_with_sets/3 (pure): sentinels exactly the keys in that entity's set", _ctx do
      sets = %{"p" => set(["secret"]), "q" => set(["other"])}
      fv = %{"secret" => 1, "other" => 2, "plain" => 3}

      assert FieldPolicy.redact_with_sets(sets, "p", fv) ==
               %{"secret" => sentinel(), "other" => 2, "plain" => 3}

      assert FieldPolicy.redact_with_sets(sets, "q", fv) ==
               %{"secret" => 1, "other" => sentinel(), "plain" => 3}
    end

    test "redact_with_sets/3 on an entity type with no loaded set raises (never passes through)" do
      assert_raise KeyError, fn -> FieldPolicy.redact_with_sets(%{}, "p", %{"secret" => 1}) end
    end

    test "restriction_set/2 honours the caller's own grant, not another user's", %{
      t: t,
      principal: principal
    } do
      assert {:ok, set} = FieldPolicy.restriction_set(principal, "p")
      assert MapSet.member?(set, "secret")

      other = user!(t.schema)
      grant!(t, other.id, "p", "secret")
      assert {:ok, set} = FieldPolicy.restriction_set(principal, "p")
      assert MapSet.member?(set, "secret")

      grant!(t, t.user_id, "p", "secret")
      assert {:ok, set} = FieldPolicy.restriction_set(principal, "p")
      refute MapSet.member?(set, "secret")
    end

    test "redact/3 sentinels exactly the restricted keys and passes the rest", %{
      principal: principal
    } do
      assert {:ok, %{"secret" => s, "plain" => 3}} =
               FieldPolicy.redact(principal, "p", %{"secret" => 1, "plain" => 3})

      assert s == sentinel()
    end

    test "check_request/4 and redact/3 agree on membership (refused <=> redacted)", %{
      t: t,
      principal: principal
    } do
      request = %{entity_type: "p", filters: [%{field: "secret", op: :eq, value: 1}]}

      for granted? <- [false, true] do
        if granted?, do: grant!(t, t.user_id, "p", "secret")

        {:ok, redacted} = FieldPolicy.redact(principal, "p", %{"secret" => 1})

        refused? =
          FieldPolicy.check_request(principal, :row, request, %{exempt?: false}) ==
            {:error, :request_field_restricted}

        assert refused? == (redacted["secret"] == sentinel())
        assert refused? == not granted?
      end
    end

    test "load_sets/2 keys by entity type, de-duplicates, and fails closed on a loader error",
         %{principal: principal} do
      assert {:ok, sets} = FieldPolicy.load_sets(principal, ["p", "p", "q"])
      assert Map.keys(sets) |> Enum.sort() == ["p", "q"]
      assert MapSet.member?(sets["p"], "secret")
      assert MapSet.size(sets["q"]) == 0

      assert {:error, :invalid_schema_name} =
               FieldPolicy.load_sets(%{principal | prefix: "not_a_tenant_schema"}, ["p"])
    end

    test "check_request/4: restricted -> error; exempt? true returns the refs in :exempted",
         %{principal: principal} do
      request = %{
        entity_type: "p",
        filters: [%{field: "secret", op: :eq, value: 1}],
        sort: [%{field: "plain", dir: :asc}]
      }

      assert {:error, :request_field_restricted} =
               FieldPolicy.check_request(principal, :row, request, %{exempt?: false})

      assert {:ok, %{exempted: [ref], sets: sets}} =
               FieldPolicy.check_request(principal, :row, request, %{exempt?: true})

      assert ref == %{entity_type: "p", field: "secret", clause: :filter}
      assert MapSet.member?(sets["p"], "secret")
    end

    test "check_request/4: nothing restricted -> exempted [] whatever exempt? says",
         %{principal: principal} do
      request = %{entity_type: "p", filters: [%{field: "plain", op: :eq, value: 1}]}

      for exempt? <- [false, true] do
        assert {:ok, %{exempted: [], sets: %{"p" => _}}} =
                 FieldPolicy.check_request(principal, :row, request, %{exempt?: exempt?})
      end
    end

    test "check_request/4: exempt? is REQUIRED (no default) and must be a boolean", %{
      principal: principal
    } do
      request = %{entity_type: "p"}

      assert_raise FunctionClauseError, fn ->
        apply(FieldPolicy, :check_request, [principal, :row, request, %{}])
      end

      assert_raise FunctionClauseError, fn ->
        apply(FieldPolicy, :check_request, [principal, :row, request, %{exempt?: nil}])
      end
    end

    test "check_request/4: an unwalked key is an error even with exempt?: true", %{
      principal: principal
    } do
      request = %{entity_type: "p", having: 1}

      assert {:error, :request_clause_unwalked} =
               FieldPolicy.check_request(principal, :row, request, %{exempt?: true})
    end

    test "check_request/4 :aggregate walks group_by and measure against the primary's set", %{
      principal: principal
    } do
      for request <- [
            %{entity_type: "p", aggregates: [%{fn: :count}], group_by: [%{field: "secret"}]},
            %{entity_type: "p", aggregates: [%{fn: :sum, field: "secret"}]}
          ] do
        assert {:error, :request_field_restricted} =
                 FieldPolicy.check_request(principal, :aggregate, request, %{exempt?: false})
      end
    end

    test "check_request/4 with a join governs the fk by the declaring entity's set", %{
      t: t,
      principal: principal
    } do
      m2m!(t)
      restrict!(t, "child", "q_id")

      # declaring side = child (join target): refused although nothing is restricted on "q"
      request = %{entity_type: "q", join: [%{entity_type: "child", fk: "child_fk"}]}

      assert {:error, :request_field_restricted} =
               FieldPolicy.check_request(principal, :row, request, %{exempt?: false})

      assert {:ok, %{exempted: [%{entity_type: "child", field: "q_id", clause: :join_on}]}} =
               FieldPolicy.check_request(principal, :row, request, %{exempt?: true})

      # a through join whose near hop is the restricted child.q_id? not involved -> ok
      through = %{entity_type: "q", join: [%{entity_type: "tag", through: "q_tag", fk: "fk_tag"}]}

      assert {:ok, %{exempted: []}} =
               FieldPolicy.check_request(principal, :row, through, %{exempt?: false})
    end
  end
end
