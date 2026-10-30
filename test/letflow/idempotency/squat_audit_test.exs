defmodule Letflow.Idempotency.SquatAuditTest do
  @moduledoc """
  GH #2597 -- the read-only audit (`Letflow.Idempotency.SquatAudit`). Tests T1 (the certificate
  squat), T2 (certificate rules R1-R4 and the report-only reasons), T3 (every other family) and
  T6 (a)/(b)/(c)/(lock) (read-only proof). Spec: `test/specs/GH-2597.md`.

  Real Postgres through `TenantFixture.provisioned_tenant!/1`, rows written directly (a squat
  predates GH #2550 and no route can produce one now). `async: false`: the fixture switches the
  sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Idempotency
  alias Letflow.Idempotency.SquatAudit
  alias Letflow.Repo
  alias Letflow.SquatFixtures, as: F
  alias Letflow.TenantFixture

  @cert "certificate:issue:"

  defp tenant!(prefix \\ "gh2597-audit"),
    do: TenantFixture.provisioned_tenant!(slug_prefix: prefix)

  defp audit!(tenant_id) do
    assert {:ok, findings} = SquatAudit.audit_tenant(tenant_id)
    findings
  end

  defp find(findings, key), do: Enum.find(findings, &(&1.key == key))

  # An audited certificate key whose session belongs to `owner`; the squat event is written by
  # `opts[:actor_id]`.
  defp cert_key!(schema, owner, opts) do
    sid = Ecto.UUID.generate()
    F.put_session!(schema, sid, owner)
    key = @cert <> sid
    opts = Keyword.put_new(opts, :payload, cert_payload(sid))
    row = F.insert_squat!(schema, key, opts)
    {key, sid, row}
  end

  defp cert_payload(sid, entity_type \\ "certificate") do
    %{
      "entity_type" => entity_type,
      "record_id" => Ecto.UUID.generate(),
      "field_values" => %{"session_id" => sid}
    }
  end

  # ---------------------------------------------------------------------------
  # T2: certificate rules R1-R4, clear rows, and the report-only reasons
  # ---------------------------------------------------------------------------

  describe "T2 certificate rules" do
    test "R3 actor mismatch: flagged with stored/expected actor, type and timestamp" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      squatter = Ecto.UUID.generate()
      {key, sid, row} = cert_key!(s, owner, actor_id: squatter)

      assert [f] = audit!(tid)

      assert %{
               key: ^key,
               family: @cert,
               verdict: :flagged,
               reason: :actor_mismatch,
               stored_actor: ^squatter,
               expected_actor: ^owner,
               target_id: ^sid,
               event_type: "ENTITY_RECORD_CREATED",
               tenant_id: ^tid,
               schema: ^s,
               event_id: event_id,
               squat_entity_type: "certificate",
               squat_record_id: record_id
             } = f

      assert event_id == row.event_id
      assert {:ok, _} = Ecto.UUID.cast(record_id)
      assert row.event_id
      assert f.event_created_at == F.created_at()
      assert %DateTime{} = f.inserted_at
    end

    test "R1 wrong event type is flagged even when the actor is the session owner" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      {key, _sid, _} = cert_key!(s, owner, actor_id: owner, event_type: "ENTITY_RECORD_UPDATED")

      assert %{verdict: :flagged, reason: :wrong_event_type} = find(audit!(tid), key)
    end

    test "R2 wrong payload entity_type is flagged" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, owner)
      key = @cert <> sid
      F.insert_squat!(s, key, actor_id: owner, payload: cert_payload(sid, "widget"))

      assert %{verdict: :flagged, reason: :wrong_entity_type} = find(audit!(tid), key)
    end

    test "R4 same actor but a different session_id in field_values is flagged target_mismatch" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, owner)
      key = @cert <> sid
      F.insert_squat!(s, key, actor_id: owner, payload: cert_payload(Ecto.UUID.generate()))

      assert %{verdict: :flagged, reason: :target_mismatch, stored_actor: ^owner} =
               find(audit!(tid), key)
    end

    test "the legitimate shape (owner, right type, entity_type, session_id) is not listed" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, owner)
      key = @cert <> sid
      F.insert_squat!(s, key, actor_id: owner, payload: cert_payload(sid))

      assert {:ok, %{scanned: 1, findings: []}} = SquatAudit.scan_tenant(tid)
    end

    test "rule order: wrong event type wins over wrong actor and wrong entity_type" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, Ecto.UUID.generate())
      key = @cert <> sid

      F.insert_squat!(s, key,
        event_type: "INSTANCE_STARTED",
        payload: cert_payload(sid, "widget")
      )

      assert %{reason: :wrong_event_type} = find(audit!(tid), key)
    end

    test "a session that does not exist is report-only :session_not_found" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      sid = Ecto.UUID.generate()
      key = @cert <> sid
      F.insert_squat!(s, key, payload: cert_payload(sid))

      assert %{verdict: :report_only, reason: :session_not_found, target_id: ^sid} =
               find(audit!(tid), key)
    end

    test "a non-uuid suffix is report-only :target_not_uuid" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = @cert <> "not-a-uuid"
      F.insert_squat!(s, key, payload: cert_payload("not-a-uuid"))

      assert %{verdict: :report_only, reason: :target_not_uuid} = find(audit!(tid), key)
    end

    test "an idempotency row whose event exists nowhere is report-only :event_missing" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = @cert <> Ecto.UUID.generate()
      F.insert_key!(s, key)

      assert %{verdict: :report_only, reason: :event_missing, event_type: nil, stored_actor: nil} =
               find(audit!(tid), key)
    end

    test "an event in events_archive is classified, not :event_missing" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      squatter = Ecto.UUID.generate()
      {key, _sid, _} = cert_key!(s, owner, actor_id: squatter, archived: true)

      assert %{verdict: :flagged, reason: :actor_mismatch, stored_actor: ^squatter} =
               find(audit!(tid), key)
    end

    test "an unresolved ($ref) payload: R1 and R3 still apply, otherwise report-only" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      ref = %{"$ref" => "payload-store-id"}

      {k_ok, _, _} = cert_key!(s, owner, actor_id: owner, payload: ref)
      {k_r3, _, _} = cert_key!(s, owner, actor_id: Ecto.UUID.generate(), payload: ref)

      {k_r1, _, _} =
        cert_key!(s, owner, actor_id: owner, payload: ref, event_type: "ENTITY_RECORD_UPDATED")

      findings = audit!(tid)
      assert %{verdict: :report_only, reason: :payload_unresolved} = find(findings, k_ok)
      assert %{verdict: :flagged, reason: :actor_mismatch} = find(findings, k_r3)
      assert %{verdict: :flagged, reason: :wrong_event_type} = find(findings, k_r1)
    end
  end

  # ---------------------------------------------------------------------------
  # T3: every other family
  # ---------------------------------------------------------------------------

  # {family, flagged-reason for a user actor with an unrelated type, clear shape}
  @actor_families ~w(script_run: effect_applied: ordering_lag_exceeded: promotion_assertion_teardown_failed:)
  @timer_families ~w(timer_fired: escalation_timer_fired:)
  @client_type_families ~w(service_task_dispatch: service_task: script_task_dispatch:)
  @type_families %{
    "attachment_attached:" => "ATTACHMENT_ATTACHED",
    "attachment_removed:" => "ATTACHMENT_REMOVED",
    "definition_promoted:" => "DEFINITION_PROMOTED",
    "definition_version_rolled_back:" => "DEFINITION_VERSION_ROLLED_BACK"
  }
  @report_only_families ~w(entities-record-import: record_trigger: req345-seed- sys:)

  describe "T3 families" do
    test "the table below covers exactly every audited family (a new prefix needs a rule here)" do
      covered =
        @actor_families ++
          @timer_families ++
          @client_type_families ++
          Map.keys(@type_families) ++ @report_only_families ++ [@cert]

      assert Enum.sort(covered) == Enum.sort(SquatAudit.families())

      assert SquatAudit.families() ==
               Idempotency.server_prefixes() ++ Idempotency.reserved_prefixes()
    end

    test "client_types is exactly the five types a pre-#2550 client route could write" do
      assert Enum.sort(SquatAudit.client_types()) ==
               Enum.sort(~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED INSTANCE_STARTED
                            INSTANCE_CANCELLED INSTANCE_PINS_REBOUND))
    end

    for family <- @actor_families do
      test "#{family} actor rule: a user actor is flagged :actor_not_platform, the platform actor is clear" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        squat = unquote(family) <> "squat"
        legit = unquote(family) <> "legit"
        user = Ecto.UUID.generate()
        F.insert_squat!(s, squat, actor_id: user, event_type: "SOMETHING_ELSE")
        F.insert_squat!(s, legit, actor_id: F.platform_actor(), event_type: "SOMETHING_ELSE")

        findings = audit!(tid)

        assert %{
                 verdict: :flagged,
                 reason: :actor_not_platform,
                 stored_actor: ^user,
                 family: unquote(family)
               } =
                 find(findings, squat)

        assert find(findings, legit) == nil
      end
    end

    for family <- @timer_families do
      test "#{family} flagged for a user actor and for a client event type, clear for the platform" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        by_user = unquote(family) <> "u"
        by_type = unquote(family) <> "t"
        legit = unquote(family) <> "ok"
        F.insert_squat!(s, by_user, actor_id: Ecto.UUID.generate(), event_type: "TIMER_FIRED")
        F.insert_squat!(s, by_type, actor_id: F.platform_actor(), event_type: "INSTANCE_STARTED")
        F.insert_squat!(s, legit, actor_id: F.platform_actor(), event_type: "TIMER_FIRED")

        findings = audit!(tid)
        assert %{reason: :actor_not_platform} = find(findings, by_user)
        assert %{reason: :client_event_type} = find(findings, by_type)
        assert find(findings, legit) == nil
      end

      test "#{family} derived sub_process keys: actor rule only (INSTANCE_STARTED is legitimate)" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        squat = unquote(family) <> "b::sub_process_1::x"
        legit = unquote(family) <> "b::sub_process_2::x"
        missing = unquote(family) <> "b::sub_process_3::x"
        F.insert_squat!(s, squat, actor_id: Ecto.UUID.generate(), event_type: "INSTANCE_STARTED")
        F.insert_squat!(s, legit, actor_id: F.platform_actor(), event_type: "INSTANCE_STARTED")
        F.insert_key!(s, missing)

        findings = audit!(tid)
        assert %{verdict: :flagged, reason: :actor_not_platform} = find(findings, squat)
        assert find(findings, legit) == nil
        assert %{verdict: :report_only, reason: :event_missing} = find(findings, missing)
      end
    end

    test "derived keys of any other base are report-only :derived_key, never flagged" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:b::sub_process_1::x"
      F.insert_squat!(s, key, actor_id: Ecto.UUID.generate(), event_type: "INSTANCE_STARTED")

      assert %{verdict: :report_only, reason: :derived_key} = find(audit!(tid), key)
    end

    for family <- @client_type_families do
      test "#{family} type-only rule: a client event type is flagged, any actor on a server type is clear" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        squat = unquote(family) <> "squat"
        legit = unquote(family) <> "legit"
        F.insert_squat!(s, squat, actor_id: F.platform_actor(), event_type: "INSTANCE_CANCELLED")

        F.insert_squat!(s, legit,
          actor_id: Ecto.UUID.generate(),
          event_type: "SERVICE_TASK_COMPLETED"
        )

        findings = audit!(tid)
        assert %{verdict: :flagged, reason: :client_event_type} = find(findings, squat)
        assert find(findings, legit) == nil
      end
    end

    for {family, type} <- @type_families do
      test "#{family} type-only rule: any type but #{type} is flagged, #{type} is clear" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        squat = unquote(family) <> "squat"
        legit = unquote(family) <> "legit"

        F.insert_squat!(s, squat,
          actor_id: Ecto.UUID.generate(),
          event_type: "ENTITY_RECORD_CREATED"
        )

        F.insert_squat!(s, legit, actor_id: Ecto.UUID.generate(), event_type: unquote(type))

        findings = audit!(tid)
        assert %{verdict: :flagged, reason: :wrong_event_type} = find(findings, squat)
        assert find(findings, legit) == nil
      end
    end

    for {family, reason} <- [
          {"entities-record-import:", :no_rule},
          {"req345-seed-", :no_rule},
          {"sys:", :reserved_prefix_present}
        ] do
      test "#{family} is listed report-only (#{reason}) and never flagged" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        key = unquote(family) <> "x1"

        F.insert_squat!(s, key,
          actor_id: Ecto.UUID.generate(),
          event_type: "ENTITY_RECORD_CREATED"
        )

        assert %{verdict: :report_only, reason: unquote(reason), family: unquote(family)} =
                 find(audit!(tid), key)
      end
    end

    test "a missing event is report-only :event_missing for a flaggable non-certificate family" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:orphan"
      F.insert_key!(s, key)

      assert %{verdict: :report_only, reason: :event_missing} = find(audit!(tid), key)
    end

    test "prefix matching is exact: serviceXtask: (the _ LIKE wildcard) and caller keys are not scanned" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "serviceXtask:foo", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "client:rec:#{Ecto.UUID.generate()}:k", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "Script_run:upper", actor_id: Ecto.UUID.generate())

      F.insert_squat!(s, "service_task:real",
        actor_id: F.platform_actor(),
        event_type: "INSTANCE_STARTED"
      )

      assert {:ok, %{scanned: 1, findings: [%{key: "service_task:real"}]}} =
               SquatAudit.scan_tenant(tid)
    end

    test "more rows than one keyset batch (500) are all scanned" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      ev = F.insert_squat!(s, "script_run:seed", actor_id: F.platform_actor())

      rows =
        for n <- 1..520 do
          %{
            id: Ecto.UUID.bingenerate(),
            idempotency_key: "script_run:bulk-#{n}",
            event_id: Ecto.UUID.bingenerate(),
            event_created_at: F.created_at(),
            inserted_at: ~N[2026-01-01 00:00:00]
          }
        end

      {520, _} = Repo.insert_all("event_idempotency", rows, prefix: s)
      assert ev.event_id

      assert {:ok, %{scanned: 521, findings: findings}} = SquatAudit.scan_tenant(tid)
      assert length(findings) == 520
      assert Enum.all?(findings, &(&1.reason == :event_missing))
    end

    test "findings are ordered by inserted_at, then key" do
      %{tenant_id: tid, schema_name: s} = tenant!()

      for {k, at} <- [
            {"script_run:c", ~N[2026-01-02 00:00:00]},
            {"script_run:a", ~N[2026-01-02 00:00:00]},
            {"script_run:b", ~N[2026-01-01 00:00:00]}
          ] do
        F.insert_squat!(s, k)

        Repo.update_all(
          from(i in "event_idempotency", where: i.idempotency_key == ^k),
          [set: [inserted_at: at]],
          prefix: s
        )
      end

      assert audit!(tid) |> Enum.map(& &1.key) == ["script_run:b", "script_run:a", "script_run:c"]
    end
  end

  # ---------------------------------------------------------------------------
  # Tenant isolation, errors
  # ---------------------------------------------------------------------------

  describe "tenant resolution and isolation" do
    test "an unregistered or malformed tenant id is :unknown_tenant" do
      assert {:error, :unknown_tenant} = SquatAudit.audit_tenant(Ecto.UUID.generate())
      assert {:error, :unknown_tenant} = SquatAudit.audit_tenant("not-a-uuid")
      assert {:error, :unknown_tenant} = SquatAudit.audit_tenant(nil)
    end

    test "another tenant's rows are never listed" do
      %{tenant_id: a, schema_name: sa} = tenant!("gh2597-iso-a")
      %{tenant_id: b, schema_name: sb} = tenant!("gh2597-iso-b")
      F.insert_squat!(sa, "script_run:only-in-a")
      F.insert_squat!(sb, "script_run:only-in-b")

      assert [%{key: "script_run:only-in-a", tenant_id: ^a, schema: ^sa}] = audit!(a)
      assert [%{key: "script_run:only-in-b", tenant_id: ^b, schema: ^sb}] = audit!(b)
    end

    test "audit_all/0 lists each tenant under its registration and one tenant's failure does not stop the rest" do
      %{tenant_id: good, schema_name: sg} = tenant!("gh2597-all-good")
      %{tenant_id: bad, schema_name: sb} = tenant!("gh2597-all-bad")
      F.insert_squat!(sg, "script_run:g")
      Repo.query!(~s(DROP SCHEMA "#{sb}" CASCADE))

      results = SquatAudit.audit_all()

      assert {_, {:ok, [%{key: "script_run:g"}]}} =
               Enum.find(results, &(elem(&1, 0).tenant_id == good))

      assert {_, {:error, {:query_failed, %Postgrex.Error{}}}} =
               Enum.find(results, &(elem(&1, 0).tenant_id == bad))
    end
  end

  # ---------------------------------------------------------------------------
  # T6: the audit is read-only
  # ---------------------------------------------------------------------------

  describe "T6 read-only" do
    test "(a) source scan: no write call anywhere in the audit module or the Mix tasks/wrapper's Repo use" do
      assert_no_write_calls!("lib/letflow/idempotency/squat_audit.ex")

      # The wrapper and the audit Mix task reach the database only through the audit/remediation
      # modules: no Repo call of their own at all.
      for file <- [
            "lib/letflow/release/idempotency_squats.ex",
            "lib/mix/tasks/letflow.audit_idempotency_squats.ex",
            "lib/mix/tasks/letflow.remediate_idempotency_squat.ex"
          ] do
        assert repo_calls(file) == [], "#{file} must not call Repo directly"
      end
    end

    test "(a) the scan itself bites: it sees a write call in a synthetic module" do
      src = """
      defmodule Probe do
        def a(repo), do: repo.delete_all(:x)
        def b, do: Letflow.Repo.query!("DELETE FROM t")
        def c, do: Ecto.Multi.new()
        def d, do: Letflow.Audit.insert_entry(1, 2, 3)
        def e, do: Repo.query!("SELECT 1")
        def f, do: Repo.query!("SET LOCAL lock_timeout = '2s'")
        def g, do: Repo.query!("SET LOCAL lock_timeout = '2s'", [1])
        def h(sql), do: Repo.query!(sql)
        def i, do: Repo.query!(@lock_timeout_sql)
      end
      """

      assert Enum.sort(violations(Code.string_to_quoted!(src))) ==
               Enum.sort([
                 {:var_repo_write, :delete_all},
                 {:repo_query, "non-constant"},
                 {:multi, :new},
                 {:audit, :insert_entry},
                 {:repo_query, "non-constant"},
                 {:repo_query, "non-constant"},
                 {:repo_query, "non-constant"},
                 {:repo_query, "non-constant"}
               ])
    end

    test "(b) a write attempted inside the audit transaction is refused by Postgres (SQLSTATE 25006)" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      {key, _sid, _} = cert_key!(s, owner, actor_id: owner, payload: nil_free_payload())
      install_write_probe!(s)

      # The certificate rule reads entity_record_latest, which is now a view whose filter tries
      # an INSERT. Inside the audit's read-only transaction Postgres must refuse it.
      assert {:error,
              {:query_failed, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}}} =
               SquatAudit.audit_tenant(tid)

      assert probe_rows(s) == 0
      assert key
    end

    test "(b) classify_key/3 does NOT set read-only: the same probe write succeeds outside the audit" do
      %{schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      {key, _sid, _} = cert_key!(s, owner, actor_id: owner, payload: nil_free_payload())
      install_write_probe!(s)

      assert {:ok, %{key: ^key}} = SquatAudit.classify_key(Repo, s, key)
      assert probe_rows(s) >= 1
      assert {:error, :no_such_key} = SquatAudit.classify_key(Repo, s, "script_run:nope")
    end

    test "(c) row counts of events, event_idempotency and audit_entries are unchanged by audit_all/0" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, @cert <> Ecto.UUID.generate())
      before = F.counts(s)

      assert length(audit!(tid)) == 2
      _ = SquatAudit.audit_all()

      assert F.counts(s) == before
    end

    test "the audit leaves no read-only setting behind: a write right after the audit works" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())
      assert length(audit!(tid)) == 1

      assert %{} = F.insert_squat!(s, "script_run:y", actor_id: Ecto.UUID.generate())
      assert F.key_rows(s, "script_run:y") == 1
    end

    test "a lock held on event_idempotency gives {:error, :lock_conflict} within the 2s lock_timeout" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())

      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(~s(LOCK TABLE "#{s}".event_idempotency IN ACCESS EXCLUSIVE MODE))
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 5_000
      result = SquatAudit.audit_tenant(tid)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert result == {:error, :lock_conflict}
      assert {:ok, [_]} = SquatAudit.audit_tenant(tid)
    end
  end

  # -- helpers for T6 ---------------------------------------------------------

  defp nil_free_payload, do: %{"entity_type" => "certificate", "field_values" => %{}}

  # Replaces entity_record_latest with a view whose filter performs an INSERT; selecting from it
  # in a read-only transaction therefore raises 25006, in a read-write one it records a row.
  defp install_write_probe!(s) do
    for sql <- [
          ~s|ALTER TABLE "#{s}".entity_record_latest RENAME TO entity_record_latest_real|,
          ~s|CREATE TABLE "#{s}".squat_probe (n int)|,
          ~s|CREATE FUNCTION "#{s}".probe_write() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN INSERT INTO "#{s}".squat_probe VALUES (1); RETURN true; END $$|,
          ~s|CREATE VIEW "#{s}".entity_record_latest AS SELECT * FROM "#{s}".entity_record_latest_real WHERE "#{s}".probe_write()|
        ] do
      Repo.query!(sql)
    end
  end

  defp probe_rows(s),
    do: Repo.query!(~s|SELECT count(*) FROM "#{s}".squat_probe|).rows |> hd() |> hd()

  @write_funs ~w(insert insert! update update! delete delete! insert_all update_all delete_all
                 insert_or_update insert_or_update! upsert)a
  # The only SQL `Repo.query/query!` may carry in squat_audit.ex: these two inline literals.
  @allowed_query_sql ["SET LOCAL transaction_read_only = on", "SET LOCAL lock_timeout = '2s'"]

  defp repo_calls(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> collect(fn
      {{:., _, [{:__aliases__, _, mods}, fun]}, _, _} ->
        if List.last(mods) == :Repo, do: [fun], else: []

      _ ->
        []
    end)
  end

  defp assert_no_write_calls!(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()
    assert violations(ast) == [], "#{file}: #{inspect(violations(ast))}"

    # Both allowed statements are present, as inline literals.
    queried =
      collect(ast, fn
        {{:., _, [{:__aliases__, _, mods}, fun]}, _, [sql | _]}
        when fun in [:query, :query!] and is_binary(sql) ->
          if List.last(mods) == :Repo, do: [sql], else: []

        _ ->
          []
      end)

    assert Enum.sort(queried) == Enum.sort(@allowed_query_sql)
  end

  # Walks the AST (docs and comments are not code, so a moduledoc quoting a write name cannot
  # trip it) and reports every write-capable call. `Repo.query/query!` is allowed only with
  # exactly one of the two constant SET LOCAL statements as an inline string literal.
  defp violations(ast) do
    ast
    |> strip_docs()
    |> collect(fn
      {{:., _, [{:__aliases__, _, mods}, fun]}, _, args} ->
        last = List.last(mods)

        cond do
          last == :Repo and fun in @write_funs -> [{:repo_write, fun}]
          last == :Repo and fun in [:query, :query!] -> query_violation(args)
          :Multi in mods -> [{:multi, fun}]
          mods == [:Audit] or Enum.take(mods, -2) == [:Letflow, :Audit] -> [{:audit, fun}]
          true -> []
        end

      {{:., _, [{var, _, ctx}, fun]}, _, _} when is_atom(var) and is_atom(ctx) ->
        if var == :repo and fun in @write_funs, do: [{:var_repo_write, fun}], else: []

      {:fragment, _, [sql | _]} when is_binary(sql) ->
        if Regex.match?(~r/\b(insert|update|delete|truncate|alter|drop|create)\b/i, sql),
          do: [{:fragment_write, sql}],
          else: []

      _ ->
        []
    end)
  end

  defp query_violation([sql]) when sql in @allowed_query_sql, do: []
  defp query_violation(_), do: [{:repo_query, "non-constant"}]

  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{doc, _, _}]} when doc in [:doc, :moduledoc] -> nil
      other -> other
    end)
  end

  defp collect(ast, fun) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc -> {node, fun.(node) ++ acc} end)

    Enum.reverse(acc)
  end
end
