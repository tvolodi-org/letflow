defmodule Letflow.Definitions.ModuleWritesLedgerTest do
  @moduledoc """
  REQ-684 criterion 7: the activation checks for posting lines (decision 0073 A2, D-L12) in
  `Letflow.Definitions.ModuleWrites.violations/6`. The definition is a bare map without a stamp,
  so no database is read; only the ledger codes are compared (the stamp refusals are not the
  subject here).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ModuleWrites

  @ledger_codes [
    :module_writes_too_many_ledger_postings,
    :module_writes_duplicate_ledger_posting,
    :module_writes_ledger_on_service_task
  ]

  defp line(handler, note \\ "n"),
    do: %{
      "module" => "fixture_ledger_post",
      "handler" => handler,
      "args" => %{"note" => %{"const" => note}}
    }

  defp graph_node(type), do: %Graph.Node{id: "n1", node_type: type, attributes: %{}}

  defp ledger_codes(type, writes, entity_write_count \\ 0) do
    type
    |> graph_node()
    |> ModuleWrites.violations(writes, %{}, entity_write_count, [], "tenant_x")
    |> Enum.filter(&(&1.code in @ledger_codes))
    |> Enum.map(&{&1.code, &1.index})
  end

  test "T-AC-01 more than two posting lines: one violation at the third posting line" do
    writes = [line("post_alpha"), line("post_beta"), line("post_alpha"), line("post_beta")]

    # only two ledger ids exist in the fixture, so the third and fourth lines also repeat an id
    assert ledger_codes(:HUMAN_TASK, writes) == [
             {:module_writes_too_many_ledger_postings, 2},
             {:module_writes_duplicate_ledger_posting, 2},
             {:module_writes_duplicate_ledger_posting, 3}
           ]
  end

  test "T-AC-01b the third posting line, not the third line, carries the index" do
    writes = [
      line("plain"),
      line("post_alpha"),
      line("plain"),
      line("post_beta"),
      line("plain"),
      line("post_alpha")
    ]

    assert {:module_writes_too_many_ledger_postings, 5} in ledger_codes(:HUMAN_TASK, writes)
  end

  test "T-AC-02 the same registration twice is a duplicate at the second line" do
    assert ledger_codes(:HUMAN_TASK, [line("post_alpha"), line("post_alpha")]) ==
             [{:module_writes_duplicate_ledger_posting, 1}]
  end

  test "T-AC-03 a HUMAN_TASK with one posting line activates" do
    assert ledger_codes(:HUMAN_TASK, [line("post_alpha")]) == []
    assert ledger_codes(:HUMAN_TASK, [line("post_beta")]) == []
  end

  test "T-AC-04 two posting lines of different ledger ids activate" do
    assert ledger_codes(:HUMAN_TASK, [line("post_alpha"), line("post_beta")]) == []
    assert ledger_codes(:HUMAN_TASK, [line("post_beta"), line("post_alpha")]) == []
  end

  test "T-AC-05 one posting line plus any number of plain lines activates" do
    writes = [line("post_alpha") | List.duplicate(line("plain"), 19)]
    assert length(writes) == 20
    assert ledger_codes(:HUMAN_TASK, writes) == []
    assert ledger_codes(:HUMAN_TASK, List.duplicate(line("plain"), 5)) == []
  end

  test "T-AC-06 a posting line on a SERVICE_TASK is refused at its own index" do
    assert ledger_codes(:SERVICE_TASK, [line("plain"), line("post_alpha")]) ==
             [{:module_writes_ledger_on_service_task, 1}]
  end

  test "T-AC-07 two posting lines of different ids on a SERVICE_TASK: the code twice, nothing else" do
    assert ledger_codes(:SERVICE_TASK, [line("post_alpha"), line("post_beta")]) ==
             [
               {:module_writes_ledger_on_service_task, 0},
               {:module_writes_ledger_on_service_task, 1}
             ]
  end

  test "T-AC-08 a SERVICE_TASK with only plain lines is not refused for ledger reasons" do
    assert ledger_codes(:SERVICE_TASK, [line("plain"), line("plain")]) == []
  end

  # REQ-688 (M-1..M-4): the consent flag lifts the SERVICE_TASK refusal.
  defp consent_codes(consent, writes) do
    attributes = if consent == :absent, do: %{}, else: %{"ledger_post_consent" => consent}

    %Graph.Node{id: "svc", node_type: :SERVICE_TASK, attributes: attributes}
    |> ModuleWrites.violations(writes, %{}, 0, [], "tenant_x")
    |> Enum.filter(&(&1.code in @ledger_codes))
    |> Enum.map(&{&1.code, &1.index})
  end

  test "M-1 a SERVICE_TASK posting line (one or two) with the flag true is accepted" do
    assert consent_codes(true, [line("plain"), line("post_alpha")]) == []
    assert consent_codes(true, [line("post_alpha"), line("post_beta")]) == []
  end

  test "M-2 anything but the boolean true still refuses (false, text, number, absent)" do
    for flag <- [false, "true", 1, nil, :absent] do
      assert consent_codes(flag, [line("post_alpha")]) ==
               [{:module_writes_ledger_on_service_task, 0}],
             "flag #{inspect(flag)}"
    end
  end

  test "M-3 the flag does not lift the posting limits on a SERVICE_TASK" do
    assert consent_codes(true, [line("post_alpha"), line("post_alpha")]) ==
             [{:module_writes_duplicate_ledger_posting, 1}]

    three = [line("post_alpha"), line("post_beta"), line("post_alpha")]
    assert {:module_writes_too_many_ledger_postings, 2} in consent_codes(true, three)
  end

  test "M-4 the flag on a non-posting node, and on a HUMAN_TASK, is ignored" do
    assert consent_codes(true, [line("plain")]) == []

    node = %Graph.Node{
      id: "ht",
      node_type: :HUMAN_TASK,
      attributes: %{"ledger_post_consent" => true}
    }

    assert [] ==
             node
             |> ModuleWrites.violations([line("post_alpha")], %{}, 0, [], "tenant_x")
             |> Enum.filter(&(&1.code in @ledger_codes))
  end

  test "M-5 ledger_consent_nodes lists sorted consented SERVICE posting nodes only" do
    consented = fn id, flag, type ->
      node = %Graph.Node{id: id, node_type: type, attributes: %{"ledger_post_consent" => flag}}
      {node, [line("post_alpha")]}
    end

    declared = [
      consented.("b", true, :SERVICE_TASK),
      consented.("a", true, :SERVICE_TASK),
      consented.("c", false, :SERVICE_TASK),
      consented.("d", true, :HUMAN_TASK),
      {%Graph.Node{
         id: "e",
         node_type: :SERVICE_TASK,
         attributes: %{"ledger_post_consent" => true}
       }, [line("plain")]}
    ]

    assert ModuleWrites.ledger_consent_nodes(declared) == ["a", "b"]
  end

  test "T-AC-09 an unresolved handler or module adds no ledger code" do
    ghost = %{line("post_alpha") | "handler" => "ghost"}
    other = %{line("post_alpha") | "module" => "fixture_ledger"}
    assert ledger_codes(:HUMAN_TASK, [ghost, ghost, ghost, other]) == []
    assert ledger_codes(:SERVICE_TASK, [ghost]) == []
  end

  test "T-AC-10 the declarative entity_writes count offsets the index" do
    assert ledger_codes(:HUMAN_TASK, [line("post_alpha"), line("post_alpha")], 3) ==
             [{:module_writes_duplicate_ledger_posting, 4}]

    assert ledger_codes(:SERVICE_TASK, [line("post_beta")], 2) == [
             {:module_writes_ledger_on_service_task, 2}
           ]
  end

  test "T-AC-11 non-list writes and malformed lines never raise" do
    for writes <- [
          nil,
          :x,
          "w",
          %{},
          [nil],
          [:x],
          [%{}],
          [%{"module" => 1, "handler" => 2}],
          [[]],
          [%{"module" => "fixture_ledger_post"}]
        ] do
      assert ledger_codes(:HUMAN_TASK, writes) == []
      assert ledger_codes(:SERVICE_TASK, writes) == []
    end
  end

  test "T-AC-12 the rejected code is not introduced under lib/letflow/definitions" do
    for path <- Path.wildcard("lib/letflow/definitions/**/*.ex") do
      refute File.read!(path) =~ "module_writes_multiple_ledger_postings", path
    end
  end

  test "the run-time line check stays shared and does not know the ledger codes" do
    {:ok, source} = File.read("lib/letflow/definitions/module_writes.ex")
    [_, line_violations_body] = String.split(source, "def line_violations(", parts: 2)
    [body | _] = String.split(line_violations_body, "defp cap_violations", parts: 2)
    refute body =~ "ledger"
  end
end
