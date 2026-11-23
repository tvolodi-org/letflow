defmodule Letflow.SecurityProbe.G05AuditWriterMatrixTest do
  @moduledoc """
  G-05 mechanical audit-writer by caller probe. M1/M2 pin the complete generated matrix;
  A1 checks actor id/kind consistency; R1 and P1 check required fields and plaintext literal
  payloads; W1 closes direct writes around `Letflow.Audit`; W2/W3 anchor the aggregate that
  W1 reads, so the rule cannot look nowhere. N1-N17 are seeded failing variants.
  The real database-row half is `g05_audit_row_schema_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Letflow.TestSupport.SecurityProbe.G05

  @moduletag :security_probe
  # Pure source scan, no database: it joins the no-DB unit tier, so it runs in every
  # checks step even before the operator's tagged `security_probe` hook exists.
  @moduletag :unit
  @moduletag probe_cost_s: 20

  # The baseline lives beside the probe module, not under test/fixtures/: the shipped-definition
  # scans read every file under test/fixtures/ and refuse the string "reminder_", which a real
  # audit-writer call site (Letflow.Engine.record_reminder_fired/3) legitimately contains.
  @matrix "test/support/security_probe/g05_audit_writer_matrix.txt"

  # The seeded failing case in the tree, read by the aggregate the real-tree rule uses.
  # It is text, not a compiled module (test/fixtures/ is not on the compile path).
  @rogue_root "test/fixtures/security_probes/g05"

  setup_all do
    sources = G05.sources()

    {:ok,
     sources: sources, entries: G05.scan_sources(sources).entries, expected: File.read!(@matrix)}
  end

  test "M1: every audit writer call equals the reviewed caller matrix", %{
    entries: entries,
    expected: expected
  } do
    assert G05.matrix_drift(entries, expected) == []
  end

  test "M2: the real inventory is non-empty and covers both central writers", %{
    entries: entries,
    expected: expected
  } do
    assert byte_size(expected) > 10_000
    assert length(entries) > 100

    assert Enum.map(entries, & &1.writer) |> Enum.uniq() |> Enum.sort() ==
             [:append_multi, :insert_entry]

    assert entries |> Enum.map(& &1.path) |> Enum.uniq() |> length() > 50
  end

  test "A1: a stated actor kind agrees with the actor the call site names", %{entries: entries} do
    assert G05.actor_violations(entries) == []
  end

  test "R1: every statically readable call supplies actor, action and resource fields", %{
    entries: entries
  } do
    assert G05.required_field_violations(entries) == []
    assert Enum.count(entries, &is_list(&1.fields)) > 100
  end

  test "P1: no before/after literal stores a plaintext sensitive value", %{entries: entries} do
    assert G05.payload_violations(entries) == []
  end

  test "W1: no caller bypasses Audit with an Entry write, a table-named bulk write or raw INSERT",
       %{sources: sources} do
    assert G05.violations(sources) == []
  end

  test "W2: the aggregate reads every production file, so the rule cannot look nowhere", %{
    sources: sources
  } do
    expected = Path.wildcard("lib/**/*.{ex,exs}") |> length()

    assert length(sources) == expected
    assert length(sources) > 100
    assert G05.scan_sources(sources).paths == Enum.map(sources, &elem(&1, 0))
  end

  test "W3 non-vacuity: the aggregate finds the seeded rogue writer in the fixture tree" do
    sources = G05.sources(@rogue_root)

    assert length(sources) == 1
    assert [{_path, _source}] = sources

    violations = G05.violations(sources)

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() == [
             :rogue_attribute_write,
             :rogue_bulk_write,
             :rogue_multi_write
           ]

    assert Enum.map(violations, &elem(&1, 4)) |> Enum.sort() == [
             :insert_all,
             :insert_all,
             :multi_insert
           ]

    # The central call the fixture hides behind an import is still a matrix row.
    assert G05.scan_sources(sources).entries |> Enum.map(& &1.caller) == [
             {:rogue_central_call, 3}
           ]
  end

  test "N1 non-vacuity: deleting one real caller makes the matrix fail", %{
    entries: entries,
    expected: expected
  } do
    broken = List.delete_at(entries, 0)
    assert [{:missing, line}] = G05.matrix_drift(broken, expected)
    assert line =~ "insert_entry/3" or line =~ "append_multi/4"
  end

  test "N2 non-vacuity: a person-driven import that stores a nil actor is unclassified drift" do
    source = """
    defmodule Rogue.Import do
      alias Letflow.Audit

      def import(multi, user_id) do
        attrs = %{
          actor_id: nil,
          action: "definition.create",
          resource_type: "definition",
          resource_id: user_id,
          before_state: nil,
          after_state: %{"name" => "imported"}
        }

        Audit.append_multi(multi, :audit, attrs, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/rogue_import.ex", source).entries
    assert [%{actor_class: "nobody", caller: {:import, 2}}] = entries
    assert [{:added, line}] = G05.matrix_drift(entries, "")
    assert line =~ "Rogue.Import.import/2"
    assert line =~ "actor=nobody"
  end

  test "N3 non-vacuity: missing actor and resource fields are rejected" do
    source = """
    defmodule Rogue.Fields do
      alias Letflow.Audit
      def write(repo), do: Audit.insert_entry(repo, %{action: "definition.create"}, "tenant")
    end
    """

    entries = G05.scan_source("synthetic/fields.ex", source).entries
    violations = G05.required_field_violations(entries)

    assert Enum.map(violations, &elem(&1, 2)) |> Enum.sort() ==
             [:actor_id, :resource_id, :resource_type]
  end

  test "N4 non-vacuity: mismatched actor ids and kinds are rejected" do
    source = """
    defmodule Rogue.Actors do
      alias Letflow.Audit

      def person(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: nil,
          actor_kind: "user",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def system(repo, actor_id, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: actor_id,
          actor_kind: "system",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/actors.ex", source).entries
    codes = entries |> G05.actor_violations() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert codes == [:system_kind_with_actor_id, :user_kind_without_user_actor]
  end

  test "N5 non-vacuity: nested plaintext secrets fail; redaction and mechanism labels pass" do
    source = """
    defmodule Rogue.Payload do
      alias Letflow.Audit

      def write(repo, actor, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: actor.user_id,
          action: "identity.changed",
          resource_type: "user",
          resource_id: resource_id,
          before_state: %{"nested" => %{"access_token" => "g05-canary"}},
          after_state: %{"password" => "g05-canary"}
        }, "tenant")
      end

      def compliant(repo, actor, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: actor.user_id,
          action: "identity.changed",
          resource_type: "user",
          resource_id: resource_id,
          before_state: %{"token" => "[REDACTED]"},
          after_state: %{"credential" => Map.get(actor, :credential)}
        }, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/payload.ex", source).entries
    violations = G05.payload_violations(entries)

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() ==
             ["access_token", "password"]

    refute Enum.any?(violations, fn {_code, identity, _field, _key} ->
             identity =~ "compliant"
           end)
  end

  test "N6 detector self-check: renamed aliases, pipes and local attrs maps are seen" do
    source = """
    defmodule Synthetic.Compliant do
      alias Letflow.Audit, as: Trail

      def write(multi, actor_id, resource_id) do
        attrs = %{
          actor_id: actor_id,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id,
          before_state: nil,
          after_state: %{"name" => "safe"}
        }

        multi |> Trail.append_multi(:audit, attrs, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/compliant.ex", source).entries
    assert [%{writer: :append_multi, actor_class: "caller"}] = entries
    assert G05.required_field_violations(entries) == []
    assert G05.actor_violations(entries) == []
    assert G05.payload_violations(entries) == []
  end

  test "N7 non-vacuity: direct Ecto and raw-SQL audit writers are rejected" do
    source = """
    defmodule Rogue.DirectWrite do
      alias Letflow.Audit.Entry
      alias Letflow.Repo

      def ecto do
        %Entry{} |> Entry.changeset(%{}) |> Repo.insert()
      end

      def sql do
        Repo.query("INSERT INTO audit_entries (action) VALUES ('definition.create')")
      end
    end
    """

    violations = G05.violations([{"synthetic/direct.ex", source}])

    assert Enum.map(violations, &elem(&1, 4)) |> Enum.sort() == [:insert, :raw_sql]
  end

  test "N8 non-vacuity: literal/dynamic apply and captures cannot bypass the matrix" do
    source = """
    defmodule Rogue.Invocation do
      alias Letflow.Audit, as: Trail

      def applied(repo, actor_id, resource_id) do
        attrs = %{
          actor_id: actor_id,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }

        apply(Trail, :insert_entry, [repo, attrs, "tenant"])
      end

      def dynamic(repo, operation, attrs), do: apply(Trail, operation, [repo, attrs, "tenant"])
      def captured, do: &Trail.append_multi/4
    end
    """

    entries = G05.scan_source("synthetic/invocations.ex", source).entries

    assert Enum.map(entries, & &1.writer) |> Enum.sort() == [
             :append_multi,
             :dynamic,
             :insert_entry
           ]

    assert Enum.map(entries, & &1.actor_class) |> Enum.sort() == [
             "caller",
             "computed",
             "computed"
           ]

    assert length(G05.matrix_drift(entries, "")) == 3
  end

  test "N12 non-vacuity: the actor classes follow the landed model and a stated kind must agree" do
    source = """
    defmodule Rogue.Actors do
      alias Letflow.Audit

      def nobody(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: nil,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def named_person(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: "26310000-0000-4000-8000-000000000001",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def sentinel(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: "00000000-0000-0000-0000-000000000002",
          action: "task.remind",
          resource_type: "task",
          resource_id: resource_id
        }, "tenant")
      end

      def from_the_caller(repo, actor_id, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: actor_id,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def claims_a_person(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: nil,
          actor_kind: "user",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def claims_the_system(repo, actor_id, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: actor_id,
          actor_kind: "system",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end

      def claims_something(repo, resource_id) do
        Audit.insert_entry(repo, %{
          actor_id: nil,
          actor_kind: "robot",
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/actor_classes.ex", source).entries
    classes = Map.new(entries, fn entry -> {elem(entry.caller, 0), entry.actor_class} end)

    assert classes[:nobody] == "nobody"
    assert classes[:named_person] == "person"
    assert classes[:sentinel] == "sentinel"
    assert classes[:from_the_caller] == "caller"

    codes = entries |> G05.actor_violations() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert codes == [
             :system_kind_with_actor_id,
             :unknown_actor_kind,
             :user_kind_without_user_actor
           ]
  end

  test "N9 non-vacuity: the qualified Kernel.apply form cannot bypass the matrix" do
    source = """
    defmodule Rogue.Qualified do
      alias Letflow.Audit, as: Trail

      def qualified(repo, actor_id, resource_id) do
        attrs = %{
          actor_id: actor_id,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }

        Kernel.apply(Trail, :insert_entry, [repo, attrs, "tenant"])
      end
    end
    """

    entries = G05.scan_source("synthetic/qualified.ex", source).entries

    assert [%{writer: :insert_entry, actor_class: "caller"}] = entries
    assert G05.required_field_violations(entries) == []
    assert [{:added, line}] = G05.matrix_drift(entries, "")
    assert line =~ "Rogue.Qualified.qualified/3"
  end

  test "N10 non-vacuity: a bulk audit-table write is refused by table name or schema alias" do
    source = """
    defmodule Rogue.BulkWrite do
      alias Letflow.Audit.Entry
      alias Letflow.Repo

      def by_table_name(rows, prefix) do
        Repo.insert_all("audit_entries", rows, prefix: prefix)
      end

      def by_schema_alias(rows, prefix) do
        Repo.insert_all(Entry, rows, prefix: prefix)
      end

      def by_qualified_schema(rows, prefix) do
        Repo.insert_all(Letflow.Audit.Entry, rows, prefix: prefix)
      end

      def unrelated_table(rows, prefix) do
        Repo.insert_all("ledger_entry", rows, prefix: prefix)
      end
    end
    """

    violations = G05.violations([{"synthetic/bulk_write.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() ==
             [:by_qualified_schema, :by_schema_alias, :by_table_name]

    assert Enum.map(violations, &elem(&1, 4)) |> Enum.uniq() == [:insert_all]
    refute Enum.any?(violations, &(&1 |> elem(3) == :unrelated_table))
  end

  test "N11 non-vacuity: a repo variable and an interpolated table name cannot bypass W1" do
    source = """
    defmodule Rogue.Interpolated do
      alias Letflow.Repo

      def via_repo_variable(repo, rows, prefix) do
        repo.insert_all("audit_entries", rows, prefix: prefix)
      end

      def via_interpolated_name(prefix, rows) do
        Repo.insert_all("\#{prefix}.audit_entries", rows)
      end

      def via_interpolated_sql(prefix) do
        Repo.query!("INSERT INTO \#{prefix}.audit_entries (action) VALUES ('definition.create')")
      end

      def unrelated_interpolated_name(prefix, rows) do
        Repo.insert_all("\#{prefix}.ledger_entry", rows)
      end
    end
    """

    violations = G05.violations([{"synthetic/interpolated.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() ==
             [:via_interpolated_name, :via_interpolated_sql, :via_repo_variable]

    refute Enum.any?(violations, &(&1 |> elem(3) == :unrelated_interpolated_name))
  end

  test "N13 non-vacuity: a central writer reached through an import is still a matrix row" do
    source = """
    defmodule Rogue.Imported do
      import Letflow.Audit

      def write(repo, actor_id, resource_id) do
        insert_entry(repo, %{
          actor_id: actor_id,
          action: "definition.create",
          resource_type: "definition",
          resource_id: resource_id
        }, "tenant")
      end
    end
    """

    entries = G05.scan_source("synthetic/imported.ex", source).entries

    assert [%{writer: :insert_entry, actor_class: "caller"}] = entries
    assert G05.required_field_violations(entries) == []
    assert G05.actor_violations(entries) == []
    assert G05.violations([{"synthetic/imported.ex", source}]) == []
  end

  test "N14 non-vacuity: an import cannot smuggle a bulk write past the rule" do
    source = """
    defmodule Rogue.ImportedBulk do
      import Letflow.Audit
      alias Letflow.Repo

      def write(rows, prefix) do
        Repo.insert_all(Entry, rows, prefix: prefix)
      end
    end
    """

    violations = G05.violations([{"synthetic/imported_bulk.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) == [:write]
    assert Enum.map(violations, &elem(&1, 4)) == [:insert_all]
  end

  test "N15 non-vacuity: the Elixir root marker and a file-scope alias both resolve" do
    source = """
    alias Letflow.Audit.Entry
    alias Letflow.Repo

    defmodule Rogue.Rooted do
      def by_file_scope_alias(rows, prefix) do
        Repo.insert_all(Entry, rows, prefix: prefix)
      end

      def by_root_marker(rows, prefix) do
        Repo.insert_all(Elixir.Audit.Entry, rows, prefix: prefix)
      end

      def by_qualified_root_marker(rows, prefix) do
        Repo.insert_all(Elixir.Letflow.Audit.Entry, rows, prefix: prefix)
      end

      def unrelated_table(rows, prefix) do
        Repo.insert_all("ledger_entry", rows, prefix: prefix)
      end
    end
    """

    violations = G05.violations([{"synthetic/rooted.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() == [
             :by_file_scope_alias,
             :by_qualified_root_marker,
             :by_root_marker
           ]

    refute Enum.any?(violations, &(&1 |> elem(3) == :unrelated_table))
  end

  test "N16 non-vacuity: a table name held in a module attribute is read" do
    source = """
    defmodule Rogue.Attribute do
      alias Letflow.Repo
      @audit_table "audit_entries"

      def write(rows, prefix) do
        Repo.insert_all(@audit_table, rows, prefix: prefix)
      end

      def unrelated_table(rows, prefix) do
        Repo.insert_all("ledger_entry", rows, prefix: prefix)
      end
    end
    """

    violations = G05.violations([{"synthetic/attribute.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) == [:write]
    assert Enum.map(violations, &elem(&1, 4)) == [:insert_all]
  end

  test "N17 non-vacuity: an Ecto.Multi that carries the audit schema is refused" do
    source = """
    defmodule Rogue.Multi do
      alias Letflow.Audit.Entry

      def write(rows) do
        Ecto.Multi.insert(:audit_entry, Entry, rows)
      end

      def piped(rows) do
        Ecto.Multi.new() |> Ecto.Multi.insert(:audit_entry, Entry, rows)
      end

      def unrelated(rows) do
        Ecto.Multi.insert(:record, Other, rows)
      end
    end
    """

    violations = G05.violations([{"synthetic/multi.ex", source}])

    assert Enum.map(violations, &elem(&1, 3)) |> Enum.sort() == [:piped, :write]
    assert Enum.map(violations, &elem(&1, 4)) |> Enum.uniq() == [:multi_insert]
    refute Enum.any?(violations, &(&1 |> elem(3) == :unrelated))
  end

  test "W4: the tree holds exactly one audit schema module, so the suffix rule is anchored" do
    modules =
      Path.wildcard("lib/**/*.{ex,exs}")
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/^\s*defmodule\s+([A-Z][\w.]*)\s+do/, File.read!(path),
          capture: :all_but_first
        )
      end)
      |> Enum.map(&hd/1)

    assert Enum.filter(modules, &String.ends_with?(&1, ".Audit.Entry")) == ["Letflow.Audit.Entry"]
  end
end
