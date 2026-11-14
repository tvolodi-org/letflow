defmodule Letflow.ProblemReports.InboxTest do
  @moduledoc "T-1949 I1-I6: transitions, decision storage, safe summaries and text-free audit."
  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  alias Letflow.{ProblemReports, Repo}
  alias Letflow.ProblemReports.{Inbox, Report}
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp report!(p, a) do
    auth = Fixture.auth_context(a, ["TENANT_ADMIN"])

    {:ok, result} =
      ProblemReports.submit(auth, a.schema_name, %{
        "consent" => true,
        "text" => "The commissioning screen loses the supplied purchase date",
        "context" => %{}
      })

    Repo.get!(Report, result.id, prefix: p.schema_name)
  end

  test "I1 all 25 transition cells" do
    actions = ~w(answer develop reject ask fixed)

    for from <- ~w(received in_work),
        {action, expected} <- Enum.zip(actions, ~w(answered in_work not_done in_work fixed)) do
      assert Inbox.transition(from, action) == {:ok, expected}
    end

    for from <- ~w(answered fixed not_done), action <- actions do
      assert Inbox.transition(from, action) == {:error, :report_closed}
    end

    assert Inbox.transition("received", "route_to_ai") == {:error, {:invalid, "action"}}
  end

  test "I2 I5 each decision persists its actor, time and text-free platform audit", %{p: p, a: a} do
    actor = Ecto.UUID.generate()

    for action <- ~w(answer develop reject ask fixed) do
      report = report!(p, a)

      assert {:ok, detail} =
               Inbox.decide(
                 report.id,
                 %{"action" => action, "text" => "Please check the date input"},
                 actor
               )

      assert {:ok, expected} = Inbox.transition("received", action)
      assert detail["status"] == expected
      stored = Repo.get!(Report, report.id, prefix: p.schema_name)
      assert stored.decided_by_user_id == actor
      assert %DateTime{} = stored.decided_at
      assert stored.last_action == action

      if action == "develop" do
        assert stored.dev_summary == "Please check the date input"
        assert stored.reply_text == nil
      else
        assert stored.reply_text == "Please check the date input"
        assert stored.dev_summary == nil
      end
    end

    entries =
      Repo.all(from(e in Letflow.Audit.Entry, where: e.action == "problem_report.decided"),
        prefix: p.schema_name
      )

    assert length(entries) == 5

    for e <- entries do
      assert Enum.sort(Map.keys(e.after_state)) ==
               ~w(action from_status number text_length to_status)

      refute inspect(e.after_state) =~ "date input"
      assert e.actor_id == actor
    end

    assert Repo.all(from(e in Letflow.Audit.Entry, where: e.action == "problem_report.decided"),
             prefix: a.schema_name
           ) == []
  end

  test "I3 all closed decisions are refused without changing the row", %{p: p, a: a} do
    for closing <- ~w(answer reject fixed) do
      report = report!(p, a)
      actor = Ecto.UUID.generate()
      assert {:ok, _} = Inbox.decide(report.id, %{"action" => closing, "text" => "Done"}, actor)
      before = Repo.get!(Report, report.id, prefix: p.schema_name)

      for action <- ~w(answer develop reject ask fixed) do
        assert {:error, :report_closed} =
                 Inbox.decide(report.id, %{"action" => action, "text" => "New"}, actor)

        assert Repo.get!(Report, report.id, prefix: p.schema_name) == before
      end
    end
  end

  test "I4 required, typed, capped and masked decision text", %{p: p, a: a} do
    report = report!(p, a)

    for action <- ~w(answer develop reject ask),
        text <- [
          nil,
          " ",
          1,
          %{},
          String.duplicate("x", if(action == "develop", do: 2001, else: 4001))
        ] do
      assert Inbox.check_text(action, text, report) == {:error, {:invalid, "text"}}
    end

    assert {:error, {:invalid, "text"}} =
             Inbox.check_text("answer", String.duplicate("e\u0301", 2001), report)

    assert {:ok, nil} = Inbox.check_text("fixed", nil, report)
    assert {:error, {:invalid, "text"}} = Inbox.check_text("fixed", 3, report)
    assert {:ok, _} = Inbox.check_text("answer", String.duplicate("x", 4000), report)
    assert {:ok, _} = Inbox.check_text("develop", String.duplicate("x", 2000), report)

    assert {:ok, detail} =
             Inbox.decide(
               report.id,
               %{"action" => "answer", "text" => "Contact me at test@example.com"},
               Ecto.UUID.generate()
             )

    assert detail["reply_text"] == "Contact me at [email]"
    report = report!(p, a)

    assert {:ok, %{"reply_text" => nil}} =
             Inbox.decide(report.id, %{"action" => "fixed"}, Ecto.UUID.generate())
  end

  test "I6 copied customer words and names are refused; owner's words alone are stored", %{
    p: p,
    a: a
  } do
    report = %{
      report!(p, a)
      | reporter_name: "Alice Example",
        reporter_tenant_name: "Sample Company"
    }

    for text <- [
          "The commissioning screen loses the supplied purchase date",
          "THE   COMMISSIONING SCREEN LOSES THE SUPPLIED PURCHASE DATE",
          "Alice Example needs help",
          "Sample Company cannot save"
        ] do
      assert {:error, :summary_copies_report} = Inbox.check_text("develop", text, report)
    end

    assert {:error, :summary_copies_report} =
             Inbox.check_text("develop", "prefix short report suffix", %{
               report
               | text: "short report"
             })

    assert {:ok, _} =
             Inbox.check_text("develop", "Investigate date persistence in commissioning", report)

    assert {:error, :summary_copies_report} =
             Inbox.decide(
               report.id,
               %{"action" => "develop", "text" => report.text},
               Ecto.UUID.generate()
             )

    assert Repo.get!(Report, report.id, prefix: p.schema_name).status == "received"

    assert {:ok,
            %{
              "reply_text" => nil,
              "dev_summary" => "Investigate date persistence in commissioning"
            }} =
             Inbox.decide(
               report.id,
               %{
                 "action" => "develop",
                 "text" => "Investigate date persistence in commissioning"
               },
               Ecto.UUID.generate()
             )
  end

  test "I5 failed audit rolls back the decision", %{p: p, a: a} do
    report = report!(p, a)
    Repo.query!(~s|DROP TABLE "#{p.schema_name}".audit_entries|)

    log =
      capture_log(fn ->
        assert {:error, :internal} =
                 Inbox.decide(
                   report.id,
                   %{"action" => "answer", "text" => "Done"},
                   Ecto.UUID.generate()
                 )
      end)

    assert log =~ "Postgrex.Error"
    refute log =~ report.text
    assert Repo.get!(Report, report.id, prefix: p.schema_name).status == "received"
  end
end
