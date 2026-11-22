defmodule Letflow.SecurityProbe.G05AuditRowSchemaTest do
  @moduledoc """
  G-05's real-PostgreSQL half: the physical `audit_entries` shape, person/system actor rows,
  required fields and a canary proving excluded/redacted payload values do not reach storage.

  `audit_entries.actor_kind` (T-2588, D-0094 decision (d)) landed on main: the writer derives
  the kind from the actor id -- a UUID names a person, anything else does not. D1 pins the
  physical column and D2 the persisted `user`/`system` values; the matrix probe (A1) checks a
  call site that states a kind against the actor it names.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity.User
  alias Letflow.Secrets.Redaction
  alias Letflow.TenantFixture

  @moduletag :security_probe
  @moduletag probe_cost_s: 20

  @actor_id "26310000-0000-4000-8000-000000000001"
  @resource_id "26310000-0000-4000-8000-000000000002"
  @canary "g05-payload-must-not-be-stored"

  @expected_columns %{
    "action" => {"NO", "character varying"},
    "actor_id" => {"YES", "uuid"},
    "actor_kind" => {"YES", "character varying"},
    "after_state" => {"YES", "jsonb"},
    "before_state" => {"YES", "jsonb"},
    "chain_hash" => {"NO", "character varying"},
    "id" => {"NO", "uuid"},
    "inserted_at" => {"NO", "timestamp without time zone"},
    "prev_chain_hash" => {"YES", "character varying"},
    "resource_id" => {"NO", "character varying"},
    "resource_type" => {"NO", "character varying"},
    "tenant_id" => {"NO", "uuid"},
    "timestamp" => {"NO", "timestamp without time zone"},
    "trace_id" => {"YES", "character varying"}
  }

  defp tenant!(suffix) do
    TenantFixture.provisioned_tenant!(slug_prefix: "g05-#{suffix}")
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        actor_id: nil,
        action: "security_probe.g05",
        resource_type: "security_probe",
        resource_id: @resource_id,
        before_state: nil,
        after_state: %{"safe" => "value"},
        trace_id: "g05-trace"
      },
      overrides
    )
  end

  defp stored_field(entry, key), do: Map.get(Map.from_struct(entry), key)

  test "D1: the physical row has exactly the reviewed columns, types and nullability" do
    fx = tenant!("schema")

    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable, data_type " <>
          "FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'audit_entries'",
        [fx.schema_name]
      )

    actual = Map.new(rows, fn [name, nullable, type] -> {name, {nullable, type}} end)
    assert actual == @expected_columns

    assert Entry.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             Map.keys(actual) |> Enum.sort()

    for field <- [:id, :tenant_id, :action, :resource_type, :resource_id, :timestamp, :chain_hash] do
      assert field in Entry.__schema__(:fields)
    end
  end

  test "D2: person and system writes retain actor id/kind and all generated required fields" do
    fx = tenant!("actors")

    assert {:ok, %Entry{} = person} =
             Audit.insert_entry(Repo, attrs(%{actor_id: @actor_id}), fx.schema_name)

    assert {:ok, %Entry{} = system} =
             Audit.insert_entry(
               Repo,
               attrs(%{
                 actor_id: nil,
                 resource_id: "26310000-0000-4000-8000-000000000003",
                 after_state: nil
               }),
               fx.schema_name
             )

    assert person.actor_id == @actor_id
    assert system.actor_id == nil

    for entry <- [person, system] do
      assert entry.tenant_id == fx.tenant_id
      assert entry.action == "security_probe.g05"
      assert entry.resource_type == "security_probe"
      assert is_binary(entry.resource_id)
      assert %DateTime{} = entry.timestamp
      assert entry.chain_hash =~ ~r/^[0-9a-f]{64}$/
      assert Repo.get(Entry, entry.id, prefix: fx.schema_name) == entry
    end

    assert system.prev_chain_hash == person.chain_hash
    assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)

    assert :actor_kind in Entry.__schema__(:fields)
    assert stored_field(person, :actor_kind) == "user"
    assert stored_field(system, :actor_kind) == "system"
  end

  test "D3: excluded and recursively redacted payload canaries never reach the stored row" do
    fx = tenant!("redaction")

    state =
      %User{id: @actor_id, username: "g05-user", password_hash: @canary}
      |> Audit.struct_state([:password_hash])
      |> Map.put(
        "nested",
        Redaction.redact_map(%{"items" => [%{"client_secret" => @canary}], "safe" => "kept"})
      )

    assert {:ok, %Entry{} = entry} =
             Audit.insert_entry(Repo, attrs(%{after_state: state}), fx.schema_name)

    stored = Repo.get!(Entry, entry.id, prefix: fx.schema_name)
    refute Map.has_key?(stored.after_state, "password_hash")
    assert stored.after_state["nested"]["items"] == [%{"client_secret" => "[REDACTED]"}]
    assert stored.after_state["nested"]["safe"] == "kept"

    %{rows: [[raw_state]]} =
      Repo.query!(
        ~s(SELECT after_state::text FROM "#{fx.schema_name}".audit_entries WHERE id = $1),
        [Ecto.UUID.dump!(entry.id)]
      )

    refute raw_state =~ @canary
  end
end
