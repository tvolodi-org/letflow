defmodule Letflow.RecordTriggers.RunnerTest do
  @moduledoc """
  REQ-628 slice T-4 part A / GH #3507 (decision 0067 D3/D5/D7): `Letflow.RecordTriggers.Runner`.
  Test ids follow the design: A (prepare_run), B (input and redaction), C (reads, sandbox), D2-D4
  (output checks). The runner is a stub that records its input; one test (C5) runs the real sandbox.
  `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  alias Letflow.RecordTriggers.Runner
  alias Letflow.RecordTriggerRunFixture, as: R
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    schema = R.tenant!("r628r")
    record_id = R.record!(schema, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})
    {:ok, schema: schema, record_id: record_id}
  end

  defp lines_out(lines), do: R.ok(%{"writes" => lines})

  defp update_line(fields),
    do: %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => fields}

  defp run!(schema, record_id, manifest \\ nil, attrs \\ []) do
    rule = R.publish!(schema, manifest)
    row = R.claimed_row!(schema, rule, record_id, attrs)
    {rule, row, Runner.run(row, schema)}
  end

  defp stub_input do
    assert_received {:stub_run, _source, input, opts, in_tx?}
    {input, opts, in_tx?}
  end

  describe "A: prepare_run" do
    test "A1 the run uses the row's pin and returns the validated lines", %{
      schema: s,
      record_id: id
    } do
      R.reply(lines_out([update_line(%{"note" => "N2"})]))

      assert {_rule, _row, {:ok, [line]}} = run!(s, id)

      assert line == %{
               index: 0,
               entity_type: R.type_a(),
               mode: "update_self",
               fields: %{"note" => "N2"},
               external_ref: nil
             }
    end

    test "A2 each prepare_run rejection is a closed dead code and the sandbox never starts", %{
      schema: s,
      record_id: id
    } do
      R.reply(lines_out([]))
      rule = R.publish!(s)

      absent = R.claimed_row!(s, rule, id, script_version: 99)
      assert Runner.run(absent, s) == {:dead, "script_unavailable"}

      wrong_sha = R.claimed_row!(s, rule, id, script_sha256: String.duplicate("b", 64))
      assert Runner.run(wrong_sha, s) == {:dead, "pin_mismatch"}

      revoked = R.publish!(s)
      F.revoke_raw!(s, revoked)
      assert Runner.run(R.claimed_row!(s, revoked, id), s) == {:dead, "script_revoked"}

      wrong_kind =
        Letflow.RecordTriggersFixture.script!(s, "service_task", :published, R.manifest())

      assert Runner.run(R.claimed_row!(s, wrong_kind, id), s) == {:dead, "pin_mismatch"}

      open = R.publish!(s, R.manifest(%{"output_schema" => %{"type" => "object"}}))
      assert Runner.run(R.claimed_row!(s, open, id), s) == {:dead, "script_rejected"}

      P.kill_switch!(s, true)
      assert Runner.run(R.claimed_row!(s, rule, id), s) == {:dead, "script_rejected"}

      refute_received {:stub_run, _, _, _, _}
    end

    test "A3 the T-3 stub is gone and the default run is run_row/2" do
      refute File.read!("lib/letflow/record_triggers/worker.ex") =~ "mark_done_stub"
      assert File.read!("lib/letflow/record_triggers/worker.ex") =~ "else: &run_row/2"
    end

    test "A4 the tenant comes from the schema argument, not the row" do
      src = File.read!("lib/letflow/record_triggers/runner.ex")
      assert src =~ "tenant_id_for_schema_name(prefix)"
      refute src =~ "row.tenant"
    end
  end

  describe "B: input build and redaction" do
    test "B1 B3 only schema-named fields, plus event, source_seq and record_seq", %{
      schema: s,
      record_id: id
    } do
      R.reply(lines_out([]))
      assert {_, _, {:ok, []}} = run!(s, id)
      {input, _opts, _in_tx?} = stub_input()

      assert input["record"] == %{"id" => id, "label" => "L1"}
      assert input["event"] == "updated"
      assert input["source_seq"] == 7
      assert is_integer(input["record_seq"])
      assert Enum.sort(Map.keys(input)) == ~w(event record record_seq source_seq)
    end

    test "B2 a restricted field is omitted unless named AND the publisher may see it", %{
      schema: s,
      record_id: id
    } do
      P.restrict_field!(s, R.type_a(), "note")
      R.reply(lines_out([]))

      props = %{"label" => %{"type" => "string"}, "note" => %{"type" => "string"}}

      manifest =
        R.manifest(
          %{
            "input_schema" => %{"type" => "object", "properties" => props},
            "restricted_inputs" => [
              %{
                "name" => "note",
                "from" => [%{"entity_type" => R.type_a(), "field" => "note"}]
              }
            ],
            "output_schema" => %{
              "type" => "object",
              "properties" => %{"writes" => %{"type" => "array"}},
              "additionalProperties" => false
            }
          },
          [update_line_decl("note")]
        )

      # A publisher who is no user: fail closed, note omitted.
      assert {_, _, {:ok, []}} = run!(s, id, manifest)
      {input, _, _} = stub_input()
      assert input["record"] == %{"id" => id, "label" => "L1"}

      # Not named in restricted_inputs at all: omitted even for an admin publisher.
      plain =
        R.manifest(%{"input_schema" => %{"type" => "object", "properties" => props}}, [
          update_line_decl("label")
        ])

      assert {_, _, {:ok, []}} = run!(s, id, plain)
      {input, _, _} = stub_input()
      refute Map.has_key?(input["record"], "note")
    end

    test "B2b an admin publisher with the permission receives the restricted field", %{
      schema: s,
      record_id: id
    } do
      P.restrict_field!(s, R.type_a(), "note")
      P.seed_roles!(s)
      admin = P.admin!(s)
      R.reply(lines_out([]))

      props = %{"label" => %{"type" => "string"}, "note" => %{"type" => "string"}}

      manifest =
        R.manifest(
          %{
            "input_schema" => %{"type" => "object", "properties" => props},
            "restricted_inputs" => [
              %{
                "name" => "note",
                "from" => [%{"entity_type" => R.type_a(), "field" => "note"}]
              }
            ]
          },
          [update_line_decl("note")]
        )

      rule = R.publish!(s, manifest, publisher: admin)

      row = R.claimed_row!(s, rule, id)
      assert {:ok, []} = Runner.run(row, s)
      {input, _, _} = stub_input()
      assert input["record"]["note"] == "N1"
    end

    test "B4 deleted event, missing record and a record of another type give the same term", %{
      schema: s,
      record_id: id
    } do
      R.reply(lines_out([]))

      other = R.record!(s, R.type_b(), %{"label" => "O"})

      for {attrs, rec} <- [
            {[event: :deleted], id},
            {[], Ecto.UUID.generate()},
            {[], other}
          ] do
        assert {_, _, {:ok, []}} = run!(s, rec, nil, attrs)
        {input, _, _} = stub_input()
        assert input["record"] == nil
        assert input["record_seq"] == nil
        assert Enum.sort(Map.keys(input)) == ~w(event record record_seq source_seq)
      end
    end

    test "B5 a run changes no column of the outbox row", %{schema: s, record_id: id} do
      R.reply(lines_out([]))
      {_rule, row, {:ok, []}} = run!(s, id)
      assert R.fetch(s, row.id) == row
    end
  end

  describe "C: reads and sandbox" do
    test "C1 C2 a declared read arrives in input[reads]; the sandbox runs outside a transaction",
         %{schema: s, record_id: id} do
      other = R.record!(s, R.type_b(), %{"label" => "from-read"})
      P.flag!(s, R.type_b())
      R.reply(lines_out([]))

      read = P.id_read("rd", R.type_b(), ["label"])

      manifest =
        R.manifest(%{
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"label" => %{"type" => "string"}, "cid" => %{"type" => "string"}}
          },
          "reads" => [read]
        })

      # the id comes from the record's own `cid` field
      cid_id = R.record!(s, R.type_a(), %{"label" => "L", "cid" => other})
      assert {_, _, {:ok, []}} = run!(s, cid_id, manifest)
      {input, _, in_tx?} = stub_input()

      assert input["reads"] == %{"rd" => [%{"id" => other, "label" => "from-read"}]}
      refute in_tx?
      _ = id
    end

    test "C3 an unknown id gives the same empty read as any miss", %{schema: s} do
      P.flag!(s, R.type_b())
      R.reply(lines_out([]))
      read = P.id_read("rd", R.type_b(), ["label"])

      manifest =
        R.manifest(%{
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"cid" => %{"type" => "string"}}
          },
          "reads" => [read]
        })

      miss = R.record!(s, R.type_a(), %{"cid" => Ecto.UUID.generate()})
      assert {_, _, {:ok, []}} = run!(s, miss, manifest)
      {input, _, _} = stub_input()
      assert input["reads"] == %{"rd" => []}
    end

    test "C4 ctx carries the row id as instance and token and occurred_at as now", %{
      schema: s,
      record_id: id
    } do
      R.reply(lines_out([]))
      {_rule, row, {:ok, []}} = run!(s, id)
      {_input, opts, _} = stub_input()

      assert opts[:tenant] == s

      assert opts[:ctx] == %{
               instance_id: row.id,
               node_id: "record_trigger",
               token_id: row.id,
               now: row.occurred_at
             }
    end

    test "C5 the real sandbox runs a script and its output becomes lines", %{
      schema: s,
      record_id: id
    } do
      Application.delete_env(:letflow, :record_trigger_script_runner)

      source = """
      return { writes = { { entity_type = "r628_item", mode = "update_self", fields = { note = ctx.input.record.label .. "!" } } } }
      """

      manifest = R.manifest()
      rule = F.published!(s, "r628real", source, manifest, hook_kind: "entity_event")
      row = R.claimed_row!(s, rule, id)

      assert {:ok, [%{fields: %{"note" => "L1!"}, mode: "update_self"}]} = Runner.run(row, s)
    end
  end

  describe "D: output checks" do
    test "D2 a non-map, a $ key and a schema failure are output_invalid", %{
      schema: s,
      record_id: id
    } do
      for reply <- [
            R.ok("text"),
            R.ok(%{"writes" => [], "$x" => 1}),
            R.ok(%{"writes" => "not a list"}),
            R.ok(%{"undeclared" => 1})
          ] do
        R.reply(reply)
        assert {_, _, {:dead, "output_invalid"}} = run!(s, id)
      end
    end

    test "D3 undeclared type, mode, field, too many lines, wrong self type are output_invalid", %{
      schema: s,
      record_id: id
    } do
      bad = [
        [%{"entity_type" => "nope", "mode" => "create", "fields" => %{"label" => "x"}}],
        [
          %{
            "entity_type" => R.type_b(),
            "mode" => "upsert_by_external_ref",
            "fields" => %{"label" => "x"}
          }
        ],
        [update_line(%{"label" => "x"})],
        [
          update_line(%{"note" => "1"}),
          update_line(%{"note" => "2"}),
          update_line(%{"note" => "3"})
        ],
        [%{"entity_type" => R.type_b(), "mode" => "update_self", "fields" => %{"label" => "x"}}],
        [Map.put(update_line(%{"note" => "1"}), "managed_by", "x")]
      ]

      for lines <- bad do
        R.reply(lines_out(lines))
        assert {_, _, {:dead, "output_invalid"}} = run!(s, id)
      end
    end

    test "D3b upsert needs an external_ref", %{schema: s, record_id: id} do
      decl = %{
        "entity_type" => R.type_b(),
        "mode" => "upsert_by_external_ref",
        "fields" => ["label"]
      }

      manifest = R.manifest(%{}, [decl])

      line = %{
        "entity_type" => R.type_b(),
        "mode" => "upsert_by_external_ref",
        "fields" => %{"label" => "x"}
      }

      R.reply(lines_out([line]))
      assert {_, _, {:dead, "output_invalid"}} = run!(s, id, manifest)

      ref = %{"system" => "erp", "id" => "1"}
      R.reply(lines_out([Map.put(line, "external_ref", ref)]))
      assert {_, _, {:ok, [%{external_ref: ^ref}]}} = run!(s, id, manifest)
    end

    test "D4 a widening output is refused before the sandbox starts", %{schema: s, record_id: id} do
      P.restrict_field!(s, R.type_a(), "note")
      R.reply(lines_out([]))

      manifest =
        R.manifest(
          %{
            "restricted_inputs" => [
              %{
                "name" => "label",
                "from" => [%{"entity_type" => R.type_a(), "field" => "note"}]
              }
            ]
          },
          [%{"entity_type" => R.type_b(), "mode" => "create", "fields" => ["label"]}]
        )

      assert {_, _, {:dead, "script_output_restriction_widened"}} = run!(s, id, manifest)
      refute_received {:stub_run, _, _, _, _}
    end

    test "D7 script_busy is retriable; script_failed and a raised runner are dead", %{
      schema: s,
      record_id: id
    } do
      R.reply({:error, :script_busy, %{}})
      assert {_, _, {:retry, "script_busy"}} = run!(s, id)

      R.reply({:error, :script_failed, %{}})
      assert {_, _, {:dead, "script_failed"}} = run!(s, id)

      R.reply(fn _input -> raise "secret detail" end)
      assert {_, _, {:dead, "script_error"}} = run!(s, id)
    end
  end

  defp update_line_decl(field),
    do: %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => [field]}
end
