Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.WritesReceiveTest do
  @moduledoc """
  GH #3615 / REQ-663 criterion 2 (tests R2a, R2b) and the tenant part of criterion 7 (X2):
  `receive_codes/3` on real provisioned tenants. `async: false`: provisioning switches the sandbox
  to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.CodesFixture

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Codes

  setup do
    {:ok, installed_tenant!("gh3615-rc")}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp tag_count(schema),
    do:
      Letflow.Repo.aggregate(from(l in Latest, where: l.entity_type == "code_tag"), :count,
        prefix: schema
      )

  defp audit_count(schema),
    do:
      Letflow.Repo.aggregate(from(e in Audit.Entry, where: like(e.action, "code.%")), :count,
        prefix: schema
      )

  defp e(value, kind \\ "barcode"), do: %{"value" => value, "kind" => kind}

  test "R2a: three values become three not_assigned records in order, one audit entry each", %{
    schema: schema
  } do
    assert {:ok, [a, b, c]} =
             Codes.receive_codes(schema, [e("A1"), e("B2", "qr"), e("C3", "epc")], opts())

    assert Enum.map([a, b, c], & &1["value"]) == ["A1", "B2", "C3"]
    assert Enum.map([a, b, c], & &1["kind"]) == ["barcode", "qr", "epc"]
    assert Enum.all?([a, b, c], &(&1["status"] == "not_assigned" and is_nil(&1["target_id"])))
    assert {:ok, ^b} = Codes.resolve(schema, "B2")
    assert tag_count(schema) == 3

    entries =
      Letflow.Repo.all(from(x in Audit.Entry, where: x.action == "code.received"), prefix: schema)

    assert Enum.sort(Enum.map(entries, & &1.resource_id)) ==
             Enum.sort([a, b, c] |> Enum.map(& &1["code_id"]))
  end

  test "R2b: every refusal names the first bad entry and writes nothing", %{schema: schema} do
    tag!(schema, "TAKEN")
    retired = tag!(schema, "GONE", %{"status" => "retired"})
    assert retired.record_id
    base_tags = tag_count(schema)
    base_audit = audit_count(schema)

    assert Codes.receive_codes(schema, [], opts()) == {:error, :batch_size}
    assert Codes.receive_codes(schema, nil, opts()) == {:error, :batch_size}
    big = for i <- 1..1001, do: e("B#{i}")
    assert Codes.receive_codes(schema, big, opts()) == {:error, :batch_size}

    cases = [
      {[e("ok1"), e("")], {:entry_invalid, 1, :value_invalid}},
      {[e("ok1"), %{"value" => 5, "kind" => "qr"}], {:entry_invalid, 1, :value_invalid}},
      {["nope"], {:entry_invalid, 0, :value_invalid}},
      {[e(<<255>>)], {:entry_invalid, 0, :value_invalid}},
      {[e("ok1"), e("ok2", "rfid")], {:entry_invalid, 1, :kind_invalid}},
      {[e("ok1"), e("ok2"), e("ok1")], {:entry_invalid, 2, :duplicate_in_batch}},
      {[e("ok1"), e("TAKEN")], {:entry_invalid, 1, :value_taken}},
      {[e("GONE")], {:entry_invalid, 0, :value_taken}}
    ]

    for {entries, expected} <- cases do
      assert Codes.receive_codes(schema, entries, opts()) == {:error, expected}
    end

    assert tag_count(schema) == base_tags
    assert audit_count(schema) == base_audit
  end

  test "R2b: values are compared exactly, case and spaces make distinct codes", %{schema: schema} do
    assert {:ok, [_, _, _]} = Codes.receive_codes(schema, [e("ab"), e("AB"), e("ab ")], opts())

    assert Codes.receive_codes(schema, [e("ab")], opts()) ==
             {:error, {:entry_invalid, 0, :value_taken}}
  end

  test "A5: the same key with another body is idempotency_key_reuse and writes nothing", %{
    schema: schema
  } do
    o = opts()
    assert {:ok, [first]} = Codes.receive_codes(schema, [e("RU1")], o)
    tags = tag_count(schema)
    audit = audit_count(schema)

    assert Codes.receive_codes(schema, [e("RU2")], o) == {:error, :idempotency_key_reuse}
    assert Codes.receive_codes(schema, [e("RU1", "qr")], o) == {:error, :idempotency_key_reuse}

    assert Codes.receive_codes(schema, [e("RU1"), e("RU3")], o) ==
             {:error, :idempotency_key_reuse}

    assert Codes.receive_codes(schema, [e("RU1")], %{o | actor_id: Ecto.UUID.generate()}) ==
             {:error, :idempotency_key_reuse}

    assert tag_count(schema) == tags
    assert audit_count(schema) == audit
    assert {:ok, [^first]} = Codes.receive_codes(schema, [e("RU1")], o)
  end

  test "A6: a shorter replay of a two-code batch is idempotency_key_reuse", %{schema: schema} do
    o = opts()
    assert {:ok, [_, _]} = Codes.receive_codes(schema, [e("RS1"), e("RS2")], o)
    assert Codes.receive_codes(schema, [e("RS1")], o) == {:error, :idempotency_key_reuse}
    assert {:ok, [_, _]} = Codes.receive_codes(schema, [e("RS1"), e("RS2")], o)
  end

  test "A4: a repeated key writes nothing new and answers the current codes", %{schema: schema} do
    o = opts()
    assert {:ok, [first]} = Codes.receive_codes(schema, [e("RP")], o)
    audit = audit_count(schema)
    assert {:ok, [^first]} = Codes.receive_codes(schema, [e("RP")], o)
    assert tag_count(schema) == 1
    assert audit_count(schema) == audit
  end

  test "X2: the same value is accepted in two tenants", %{schema: schema} do
    other = installed_tenant!("gh3615-rc2")
    assert {:ok, [_]} = Codes.receive_codes(schema, [e("SHARED")], opts())
    assert {:ok, [_]} = Codes.receive_codes(other.schema, [e("SHARED")], opts())
  end

  test "opts without an actor or a key raise ArgumentError", %{schema: schema} do
    assert_raise ArgumentError, fn -> Codes.receive_codes(schema, [e("Z")], %{}) end

    assert_raise ArgumentError, fn ->
      Codes.receive_codes(schema, [e("Z")], %{actor_id: "x", idempotency_key: "k"})
    end
  end
end
