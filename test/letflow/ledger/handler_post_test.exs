defmodule Letflow.Ledger.HandlerPostTest do
  @moduledoc """
  REQ-685 criteria 1 and 3: `HandlerWrites.post/3`, the build bookkeeping, `Capability.mint/4` and the
  deferred refusal. Build-time problems are stored, never raised: the step is still appended and
  the refusal is released at run time, after authority (an authorised subject sees the typed
  code at the Multi level, `{:error, step, reason, changes}`).
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Ecto.Multi
  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.StepSource
  alias Letflow.Ledger.Capability
  alias Letflow.LedgerPostFixture, as: Fx

  defp one_line_case(slug, posting_extra \\ %{}, arg_extra \\ %{}) do
    posting = Fx.posting("receipt", "a", "5", posting_extra)
    Fx.case!(slug, [Fx.post_line("post_alpha", posting, arg_extra)])
  end

  defp refusal(result) do
    assert {:error, {:line, _key, :ledger_post}, reason, _changes} = result
    reason
  end

  test "HP-1 post/3 outside a handler call, and with a hand-built context, is invalid_context" do
    ctx = %HandlerContext{
      prefix: "tenant_" <> String.duplicate("0", 32),
      instance_id: Ecto.UUID.generate(),
      origin: {:task, Ecto.UUID.generate()},
      node_id: "ht",
      definition_id: Ecto.UUID.generate(),
      definition_version: "1",
      line_index: 0,
      actor_id: Ecto.UUID.generate(),
      subject_id: Ecto.UUID.generate(),
      activator_id: Ecto.UUID.generate(),
      handler: %{module_id: "fixture_ledger_post", name: "post_alpha", targets: ["fxlp_note"]}
    }

    assert {:error, :invalid_context} = HandlerWrites.post(Multi.new(), ctx, %{})
    assert {:error, :invalid_context} = HandlerWrites.post(Multi.new(), :not_a_context, %{})
    assert {:error, :invalid_context} = HandlerWrites.post(:not_a_multi, ctx, %{})
  end

  test "HP-2 one posting appends one {:line, key, :ledger_post} step in the call's key range" do
    ctx = one_line_case("req685-hp2")

    assert {:ok, changes} = Fx.run_lines(ctx, [receipt_line()])
    key = StepSource.call_key(0) + 1
    assert {:planned, %Capability{}} = changes[{:line, key, :ledger_post}]

    assert %{"fixture_ledger_post" => %{duplicate: false, posting_seq: 1}} =
             changes[{:ledger_write, :all}]

    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  defp receipt_line, do: Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5"))

  test "HP-3 48 create/3 calls and one post/3 build and commit (49 slots)" do
    ctx = one_line_case("req685-hp3", %{}, %{"before" => 47, "skip_note" => false})
    assert {:ok, _} = Fx.complete(ctx)
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  test "HP-4 49 create/3 calls and one post/3 hit the existing budget refusal" do
    ctx = one_line_case("req685-hp4", %{}, %{"before" => 48, "skip_note" => false})
    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} = Fx.complete(ctx)
    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "HP-5 a second post/3 in one call is a deferred refusal and nothing is committed" do
    ctx = one_line_case("req685-hp5", %{}, %{"twice" => true})

    assert {:ledger_contract, :too_many_postings} =
             refusal(Fx.run_lines(ctx, [twice(receipt_line())]))

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  defp twice(line), do: put_in(line, ["args", "twice"], %{"const" => true})

  describe "HP-7..13 build-time problems are released as typed refusals for an authorised subject" do
    @cases [
      {"unknown cause", %{"cause" => "bogus"}, :invalid_posting, :unknown_cause},
      {"wrong slot format", nil, :invalid_posting, :slot_invalid},
      {"foreign ledger id", %{"ledger_id" => "other_ledger"}, :invalid_posting,
       :ledger_id_invalid},
      {"over-long document id", %{"document_id" => String.duplicate("d", 200)}, :invalid_posting,
       :text_field},
      {"event time too old",
       %{"device_id" => "dev1", "client_seq" => 1, "client_event_time" => "2001-01-01T00:00:00Z"},
       :event_time_too_old, nil},
      {"bad reason from the policy", %{"explode" => "bad_reason"}, :invalid_posting, :unspecified}
    ]

    for {name, extra, code, reason} <- @cases do
      test "#{name}" do
        extra = unquote(Macro.escape(extra))
        ctx = one_line_case("req685-hp7")

        posting =
          case extra do
            nil ->
              %{"legs" => [%{"k" => ["a", "not-a-uuid"], "quantity" => "5", "unit_ref" => "u1"}]}

            extra ->
              extra
          end

        line = Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5", posting))

        assert {:ledger_refused, unquote(code), _wire, details} =
                 refusal(Fx.run_lines(ctx, [line]))

        if unquote(reason), do: assert(details.reason == unquote(reason))
        assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
      end
    end

    test "a policy that returns another code, raises, exits or throws is a forbidden refusal without text" do
      ctx = one_line_case("req685-hp8")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for kind <- ["other_code", "not_a_tuple", "raise", "exit", "throw"] do
            line =
              Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5", %{"explode" => kind}))

            assert {:ledger_denied, :declare_refused} = refusal(Fx.run_lines(ctx, [line]))
          end
        end)

      refute log =~ "secret"
    end
  end

  test "HP-14 the size caps are checked before declare/2 is called" do
    ctx = one_line_case("req685-hp14")
    legs = for i <- 1..201, do: %{"k" => ["a#{i}", ""], "quantity" => "1", "unit_ref" => "u1"}
    # `explode: raise` would be a declare_refused if declare/2 were reached
    posting = Fx.posting("receipt", "a", "5", %{"legs" => legs, "explode" => "raise"})

    assert {:ledger_refused, :invalid_posting, _, %{reason: :posting_shape}} =
             refusal(Fx.run_lines(ctx, [Fx.post_line("post_alpha", posting)]))
  end

  describe "Capability.mint/4" do
    defp handler_ctx(overrides \\ %{}) do
      struct!(
        HandlerContext,
        Map.merge(
          %{
            prefix: "tenant_" <> String.duplicate("a", 32),
            instance_id: Ecto.UUID.generate(),
            origin: {:task, Ecto.UUID.generate()},
            node_id: "ht",
            definition_id: Ecto.UUID.generate(),
            definition_version: "1",
            line_index: 0,
            actor_id: Ecto.UUID.generate(),
            subject_id: Ecto.UUID.generate(),
            activator_id: Ecto.UUID.generate(),
            credential: :oidc,
            handler: %{
              module_id: "fixture_ledger_post",
              name: "post_alpha",
              targets: ["fxlp_note"]
            }
          },
          overrides
        )
      )
    end

    test "HP-15 returns the capability with the four new keys and every REQ-621 key" do
      ctx = handler_ctx()
      build = %{posting: %{ledger_id: "x"}, command: %{client_op_id: "o"}, deferred_refusal: nil}
      assert {:ok, %Capability{} = cap} = Capability.mint(ctx, "alpha", build, "task:1:ht:21")

      assert cap.prefix == ctx.prefix
      assert cap.subject_id == ctx.subject_id
      assert cap.actor_id == ctx.actor_id
      assert cap.origin == ctx.origin
      assert cap.instance_id == ctx.instance_id
      assert cap.credential == :oidc
      assert cap.deferred_refusal == nil
      assert cap.origin_key == "task:1:ht:21"
      assert cap.registration_name == "alpha"
      assert cap.registration.ledger_ids == ["fixture_ledger_post"]
    end

    test "HP-16 prefix, subject and credential keys of a command change nothing" do
      ctx = handler_ctx(%{credential: nil})

      command = %{
        client_op_id: "o",
        prefix: "tenant_" <> String.duplicate("b", 32),
        subject_id: "evil",
        credential: :oidc,
        origin: {:task, "x"}
      }

      build = %{posting: nil, command: command, deferred_refusal: nil}
      assert {:ok, cap} = Capability.mint(ctx, "alpha", build, "k")
      assert cap.prefix == ctx.prefix
      assert cap.subject_id == ctx.subject_id
      assert cap.credential == nil
      assert cap.origin == ctx.origin
    end

    test "an unknown registration or a malformed context is invalid_context" do
      build = %{posting: nil, command: %{}, deferred_refusal: nil}
      assert {:error, :invalid_context} = Capability.mint(handler_ctx(), "nope", build, "k")
      assert {:error, :invalid_context} = Capability.mint(%{}, "alpha", build, "k")
    end
  end

  test "HP-17 only capability.ex builds a Capability in lib/" do
    sources =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
      |> Map.new(&{&1, File.read!(&1)})

    literal = ~r/%(Letflow\.Ledger\.)?Capability\{|struct!?\(Capability/
    assert for({file, src} <- sources, src =~ literal, do: file) == []

    builds = for {file, src} <- sources, src =~ "%__MODULE__{", do: file
    assert "lib/letflow/ledger/capability.ex" in builds

    assert Enum.all?(Map.keys(sources), fn file ->
             file == "lib/letflow/ledger/capability.ex" or
               not (sources[file] =~ ~r/defmodule Letflow\.Ledger\.Capability\b/)
           end)
  end

  test "HP-18 a problem found at build time still appends the step and raises no build error" do
    ctx = one_line_case("req685-hp18")
    line = Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5", %{"cause" => "bogus"}))

    assert {:error, {:line, _, :ledger_post}, {:ledger_refused, _, _, _}, changes} =
             Fx.run_lines(ctx, [line])

    refute Enum.any?(Map.keys(changes), &match?({:line, _, :build}, &1))
  end
end
