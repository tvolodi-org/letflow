defmodule Letflow.Ledger.OfflineFieldsTest do
  @moduledoc """
  REQ-621 / GH #3469 part C, criterion 7: T-OFF-1 a..g. Offline fields stored, the digest covers
  them, the event time rules (future / lateness, checked under the counter lock) and
  `client_seq_conflict`. Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Digest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Repo

  @uuid_cols ~w(id reverses_entry_id actor_id subject_id bpm_instance_id bpm_task_id bpm_definition_id)a

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!()}
  end

  defp receipt(schema, command, opts \\ []) do
    Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)], [{:command, command} | opts])
  end

  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp refused(result, code) do
    case result do
      {:error, {:ledger_refused, ^code, wire, details}} ->
        assert wire == Atom.to_string(code)
        details

      other ->
        flunk("expected ledger_refused #{inspect(code)}, got: #{inspect(other)}")
    end
  end

  defp invalid(result, reason) do
    assert %{leg_no: nil, reason: ^reason} = refused(result, :invalid_posting)
  end

  defp entry_rows(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT posting_seq, event_time, posting_time, device_id, client_seq, client_event_time FROM "#{schema}".ledger_entry ORDER BY posting_seq|
      )

    rows
  end

  describe "T-OFF-1" do
    test "a online posting stores nulls and event_time equals posting_time", %{schema: schema} do
      Fx.post!(receipt(schema, %{}))
      assert [[1, event, posting, nil, nil, nil]] = entry_rows(schema)
      assert event == posting
    end

    test "b offline posting stores the fields, covers them in the digest, late one gets next seq",
         %{schema: schema} do
      Fx.post!(receipt(schema, %{}))
      client_time = ago(3600)

      cmd = %{device_id: "dev-1", client_seq: 7, client_event_time: iso(client_time)}
      assert %{posting_seq: 2} = Fx.post!(receipt(schema, cmd))

      assert [_, [2, event, posting, "dev-1", 7, stored_client]] = entry_rows(schema)
      assert DateTime.compare(event, stored_client) == :eq
      assert DateTime.compare(stored_client, DateTime.truncate(client_time, :microsecond)) == :eq
      assert DateTime.compare(event, posting) == :lt

      assert_digest_matches(schema, 2)
    end

    test "b2 a DateTime and a non-UTC offset are accepted", %{schema: schema} do
      t = ago(600)
      cmd1 = %{device_id: "d", client_seq: 1, client_event_time: t}
      assert {:ok, _} = Fx.post_tx(receipt(schema, cmd1))

      shifted = t |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      shifted = String.replace(shifted, ~r/Z\z/, "+01:00")
      cmd2 = %{device_id: "d", client_seq: 2, client_event_time: shifted}
      assert {:ok, _} = Fx.post_tx(receipt(schema, cmd2))

      assert [[_, e1 | _], [_, e2 | _]] = entry_rows(schema)
      assert DateTime.compare(e1, DateTime.truncate(t, :microsecond)) == :eq
      assert DateTime.compare(e2, DateTime.truncate(t, :microsecond)) == :eq
    end

    test "c client_seq_conflict, per subject, lower seq after higher posts, same op is duplicate",
         %{schema: schema} do
      subject = Ecto.UUID.generate()
      cmd = %{device_id: "dev-1", client_seq: 5}

      first = receipt(schema, cmd, subject_id: subject)
      assert {:ok, %{duplicate: false}} = Fx.post_tx(first)

      other_op = receipt(schema, cmd, subject_id: subject)
      assert %{} == refused(Fx.post_tx(other_op), :client_seq_conflict)
      assert Fx.count(schema, "ledger_entry") == 1

      # the 409 wire code of the conflict is its own code
      assert {:error, {:ledger_refused, :client_seq_conflict, "client_seq_conflict", %{}}} =
               Fx.post_tx(receipt(schema, cmd, subject_id: subject))

      # another subject, same device and seq
      assert {:ok, %{duplicate: false}} = Fx.post_tx(receipt(schema, cmd))

      # a lower seq after a higher one
      lower = receipt(schema, %{device_id: "dev-1", client_seq: 2}, subject_id: subject)
      assert {:ok, %{duplicate: false}} = Fx.post_tx(lower)

      # the same op and payload twice
      assert {:ok, %{duplicate: true}} = Fx.post_tx(first)
      assert {:ok, %{duplicate: true}} = Fx.post_tx(first)
    end

    test "c2 a retry with other offline values is idempotency_key_reuse", %{schema: schema} do
      first = receipt(schema, %{device_id: "dev-1", client_seq: 5})
      assert {:ok, _} = Fx.post_tx(first)
      changed = %{first | command: Map.put(first.command, :client_seq, 6)}

      assert {:error, {:ledger_refused, :idempotency_key_reuse, _, _}} = Fx.post_tx(changed)
    end

    test "d incomplete combinations and bad device or seq are invalid_posting", %{schema: schema} do
      post = fn cmd -> Fx.post_tx(receipt(schema, cmd)) end

      invalid(post.(%{device_id: "d1"}), :offline_fields_incomplete)
      invalid(post.(%{client_seq: 1}), :offline_fields_incomplete)
      invalid(post.(%{client_event_time: iso(ago(60))}), :offline_fields_incomplete)
      invalid(post.(%{device_id: "bad id", client_seq: 1}), :device_id_invalid)
      invalid(post.(%{device_id: String.duplicate("d", 65), client_seq: 1}), :device_id_invalid)
      invalid(post.(%{device_id: "", client_seq: 1}), :device_id_invalid)
      invalid(post.(%{device_id: "d1", client_seq: -1}), :client_seq_invalid)
      invalid(post.(%{device_id: "d1", client_seq: "1"}), :client_seq_invalid)

      invalid(
        post.(%{device_id: "d1", client_seq: 9_223_372_036_854_775_808}),
        :client_seq_invalid
      )

      invalid(
        Fx.post_tx(receipt(schema, %{}, posting: %{device_id: "d1"})),
        :posting_shape
      )

      invalid(
        Fx.post_tx(receipt(schema, %{}, posting: %{client_seq: 1})),
        :posting_shape
      )

      assert Fx.count(schema, "ledger_entry") == 0
    end

    test "e future and lateness margins; a refusal writes nothing", %{schema: schema} do
      Fx.post!(receipt(schema, %{}))
      at = fn secs -> DateTime.utc_now() |> DateTime.add(secs, :second) |> iso() end

      post = fn seq, secs ->
        cmd = %{device_id: "dev-e", client_seq: seq, client_event_time: at.(secs)}
        Fx.post_tx(receipt(schema, cmd))
      end

      assert {:ok, _} = post.(1, 290)
      assert {:ok, _} = post.(2, -(96 * 3600 - 60))
      assert Fx.last_seq(schema) == 3

      # refusals run inside one transaction that rolls back after reading the counter
      {result, seq, entries} =
        observed_refusal(schema, fn ->
          cmd = %{device_id: "dev-e", client_seq: 3, client_event_time: at.(310)}
          Ledger.post(receipt(schema, cmd))
        end)

      assert %{} == refused(result, :event_time_in_future)
      assert seq == 3
      assert entries == 3

      {result, seq, entries} =
        observed_refusal(schema, fn ->
          cmd = %{device_id: "dev-e", client_seq: 4, client_event_time: at.(-(96 * 3600 + 60))}
          Ledger.post(receipt(schema, cmd))
        end)

      assert %{} == refused(result, :event_time_too_old)
      assert seq == 3
      assert entries == 3
      assert Fx.last_seq(schema) == 3
    end

    test "e2 a duplicate of an accepted late posting is not event_time_too_old", %{schema: schema} do
      tight = Fx.registration() |> Map.put(:max_event_lateness_hours, 1)
      time = iso(ago(3000))

      cap =
        receipt(schema, %{device_id: "d", client_seq: 1, client_event_time: time},
          registration: tight
        )

      assert {:ok, %{duplicate: false}} = Fx.post_tx(cap)

      # the same capability keeps being a duplicate even after the lateness window has "passed"
      stale = %{cap | registration: Map.put(tight, :max_event_lateness_hours, 1)}
      assert {:ok, %{duplicate: true}} = Fx.post_tx(stale)
    end

    test "e3 max_event_lateness_hours must be an integer in 1..8760", %{schema: schema} do
      for bad <- [nil, 0, 8761, "96", 1.5] do
        reg = Fx.registration() |> Map.put(:max_event_lateness_hours, bad)
        cap = Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)], registration: reg)
        assert {:error, {:ledger_contract, :invalid_registration}} = Fx.post_tx(cap)
      end

      reg = Fx.registration() |> Map.delete(:max_event_lateness_hours)
      cap = Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)], registration: reg)
      assert {:error, {:ledger_contract, :invalid_registration}} = Fx.post_tx(cap)
    end

    test "f unparseable and out of range client times are invalid_posting", %{schema: schema} do
      for {bad, n} <-
            Enum.with_index([
              "infinity",
              "-infinity",
              "2026-01-01T00:00:00",
              "1999-12-31T23:59:59Z",
              "2101-01-01T00:00:00Z",
              "garbage",
              12
            ]) do
        cmd = %{device_id: "dev-f", client_seq: n, client_event_time: bad}
        invalid(Fx.post_tx(receipt(schema, cmd)), :client_event_time_invalid)
      end

      assert Fx.count(schema, "ledger_entry") == 0
    end

    test "g text limits are refused by code and by the database CHECKs", %{schema: schema} do
      long = String.duplicate("x", 129)
      ctl = "a" <> <<1>> <> "b"

      invalid(
        Fx.post_tx(receipt(schema, %{}, posting: %{document_id: long})),
        :text_field
      )

      invalid(
        Fx.post_tx(receipt(schema, %{}, posting: %{reason_code: ctl})),
        :text_field
      )

      assert Fx.count(schema, "ledger_entry") == 0

      Fx.post!(receipt(schema, %{}))
      assert_check_violation(schema, "document_id", long, "ledger_entry_document_id_check")
      assert_check_violation(schema, "reason_code", ctl, "ledger_entry_reason_code_check")
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # Runs `fun` in a transaction, reads the counter and the entry count before rolling back.
  defp observed_refusal(schema, fun) do
    {:error, {result, seq, entries}} =
      Repo.transaction(fn ->
        result = fun.()
        seq = in_tx_count(schema, "ledger_counter", "last_seq")
        entries = in_tx_count(schema, "ledger_entry", "count(*)")
        Repo.rollback({result, seq, entries})
      end)

    {result, seq, entries}
  end

  defp in_tx_count(schema, table, expr) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT #{expr} FROM "#{schema}".#{table}|)
    n
  end

  defp assert_check_violation(schema, column, value, constraint) do
    id = Ecto.UUID.generate()
    columns = ~w(id ledger_id posting_seq cause sign_rule actor_id subject_id correlation_id
                 event_time posting_time client_op_id origin_key payload_hash entry_digest
                 chain_hash registration_hash leg_count)
    hash = String.duplicate("a", 64)

    values = [
      Ecto.UUID.dump!(id),
      "raw_ledger",
      1,
      "receipt",
      "positive",
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      "corr",
      DateTime.utc_now(),
      DateTime.utc_now(),
      "raw-op",
      "raw-origin",
      hash,
      hash,
      hash,
      hash,
      1
    ]

    placeholders = Enum.map_join(1..(length(columns) + 1), ", ", &"$#{&1}")
    Fx.ensure_storage!(schema, "raw_ledger")

    sql =
      ~s|INSERT INTO "#{schema}".ledger_entry (#{Enum.join(columns, ", ")}, #{column}) VALUES (#{placeholders})|

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          # the insert guard wants posting_seq == the ledger's counter: give a spare ledger a
          # counter at 1 first, so the column CHECK is the first rule the row meets
          Repo.query!(
            ~s|INSERT INTO "#{schema}".ledger_counter (ledger_id, last_seq, last_chain_hash) VALUES ('raw_ledger', 0, '')|
          )

          Repo.query!(
            ~s|UPDATE "#{schema}".ledger_counter SET last_seq = 1 WHERE ledger_id = 'raw_ledger'|
          )

          Repo.query!(sql, values ++ [value])
        end)
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == constraint
  end

  defp assert_digest_matches(schema, seq) do
    cols = Enum.map_join(Digest.header_fields(), ", ", &Atom.to_string/1)

    %{rows: [row], columns: names} =
      Repo.query!(
        ~s|SELECT #{cols}, entry_digest FROM "#{schema}".ledger_entry WHERE posting_seq = $1|,
        [seq]
      )

    stored = Enum.zip(names, row) |> Map.new()

    header =
      Map.new(Digest.header_fields(), fn field ->
        value = Map.fetch!(stored, Atom.to_string(field))

        {field,
         if(field in @uuid_cols and is_binary(value), do: Ecto.UUID.load!(value), else: value)}
      end)

    leg_cols = Enum.map_join(Digest.leg_fields(), ", ", &Atom.to_string/1)

    %{rows: leg_rows, columns: leg_names} =
      Repo.query!(
        ~s|SELECT #{leg_cols} FROM "#{schema}".ledger_leg WHERE posting_seq = $1 ORDER BY leg_no|,
        [seq]
      )

    legs =
      for r <- leg_rows do
        Enum.zip(leg_names, r) |> Map.new(fn {n, v} -> {String.to_atom(n), v} end)
      end

    assert Digest.entry_digest(header, legs) == stored["entry_digest"]

    # a different offline value gives a different digest: the columns are covered
    assert Digest.entry_digest(%{header | client_seq: 8}, legs) != stored["entry_digest"]
  end
end
