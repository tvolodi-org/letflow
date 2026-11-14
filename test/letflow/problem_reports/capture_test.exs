defmodule Letflow.ProblemReports.CaptureTest do
  @moduledoc """
  T-1948 C1-C9: the cut-down and the text mask of a problem report. Pure, no DB.
  The 17 literal pairs of C9 are shared with the web follow-up task (`redact.test.ts`).
  """

  use ExUnit.Case, async: true

  alias Letflow.ProblemReports.Capture

  defp parse!(body), do: elem(Capture.parse(body), 1)

  test "C1 unknown top-level and nested keys are dropped" do
    %{context: ctx} =
      parse!(%{
        "text" => "hello",
        "tenant_id" => "t",
        "context" => %{
          "route" => "/tasks",
          "tenant_id" => "t",
          "user_id" => "u",
          "roles" => ["X"],
          "email" => "a@b.kz",
          "password" => "p",
          "screenshot" => "data:...",
          "browser" => %{"user_agent" => "UA", "cookie" => "c", "viewport" => "10x10"},
          "crash" => %{"name" => "E", "message" => "m", "stack" => "s"}
        }
      })

    assert Map.keys(ctx) |> Enum.sort() == ~w(browser crash route)
    assert Map.keys(ctx["browser"]) |> Enum.sort() == ~w(user_agent viewport)
    assert Map.keys(ctx["crash"]) |> Enum.sort() == ~w(message name)
  end

  test "C2 caps: last 20 actions, last 10 requests, long strings are cut" do
    actions = for i <- 1..21, do: %{"at" => "t#{i}", "kind" => "click", "name" => "b#{i}"}
    reqs = for i <- 1..11, do: %{"method" => "GET", "path" => "/p#{i}", "status" => 200}

    %{context: ctx} =
      parse!(%{
        "text" => "x",
        "context" => %{
          "actions" => actions,
          "requests" => reqs,
          "crash" => %{
            "name" => String.duplicate("n", 200),
            "message" => String.duplicate("m", 500)
          },
          "browser" => %{"user_agent" => String.duplicate("u", 400)}
        }
      })

    assert length(ctx["actions"]) == 20
    assert hd(ctx["actions"])["name"] == "b2"
    assert length(ctx["requests"]) == 10
    assert hd(ctx["requests"])["path"] == "/p2"
    assert String.length(ctx["crash"]["name"]) == 80
    assert String.length(ctx["crash"]["message"]) == 300
    assert String.length(ctx["browser"]["user_agent"]) == 300
  end

  test "C3 normalize_path: ids become :id, query and hash are dropped" do
    assert Capture.normalize_path("/api/v1/tasks/0b9f8e7a-1111-4222-8333-444455556666?x=1#h") ==
             "/api/v1/tasks/:id"

    assert Capture.normalize_path("/admin/assets/documents/12345") ==
             "/admin/assets/documents/:id"

    assert Capture.normalize_path("/a/" <> String.duplicate("z", 41)) == "/a/:id"
    assert Capture.normalize_path("/tasks") == "/tasks"
    assert Capture.normalize_path("/a/b12") == "/a/b12"

    %{context: ctx} =
      parse!(%{
        "text" => "x",
        "context" => %{
          "route" => "/t/999?secret=1",
          "actions" => [%{"kind" => "nav", "name" => "/t/999"}]
        }
      })

    assert ctx["route"] == "/t/:id"
    assert [%{"name" => "/t/:id"}] = ctx["actions"]
  end

  test "C4 a bad viewport, language, trace_id, method, status or error_code is dropped" do
    %{context: ctx} =
      parse!(%{
        "text" => "x",
        "context" => %{
          "browser" => %{"viewport" => "wide", "language" => "en_US!!", "user_agent" => "UA"},
          "ui_language" => "de",
          "requests" => [
            %{"method" => "TRACE", "path" => "/a"},
            %{
              "method" => "GET",
              "path" => "/b",
              "trace_id" => "bad id!",
              "status" => 900,
              "error_code" => "no spaces"
            }
          ]
        }
      })

    assert ctx["browser"] == %{"user_agent" => "UA"}
    refute Map.has_key?(ctx, "ui_language")
    assert ctx["requests"] == [%{"method" => "GET", "path" => "/b"}]
  end

  test "C5 a non-map context is invalid; a missing one is empty" do
    assert {:error, {:invalid, "context"}} = Capture.parse(%{"text" => "x", "context" => "nope"})
    assert {:ok, %{context: %{}}} = Capture.parse(%{"text" => "x"})
  end

  test "C6 text bounds" do
    assert {:error, {:invalid, "text"}} = Capture.parse(%{"text" => ""})
    assert {:error, {:invalid, "text"}} = Capture.parse(%{"text" => "   \n "})
    assert {:error, {:invalid, "text"}} = Capture.parse(%{})
    assert {:error, {:invalid, "text"}} = Capture.parse(%{"text" => 5})
    assert {:ok, %{text: t}} = Capture.parse(%{"text" => String.duplicate("a", 4000)})
    assert String.length(t) == 4000
    assert {:error, {:invalid, "text"}} = Capture.parse(%{"text" => String.duplicate("a", 4001)})
  end

  test "C7 the redact_map pass leaves no secret-named key value" do
    # Keys are not in the whitelist, so they never survive; the second pass is the floor.
    %{context: ctx} =
      parse!(%{
        "text" => "x",
        "context" => %{
          "route" => "/a",
          "api_token" => "zzz",
          "password" => "zzz",
          "crash" => %{"secret" => "zzz"}
        }
      })

    refute inspect(ctx) =~ "zzz"
  end

  test "C8 secrets and personal data are masked in text, crash message and action name" do
    secret = "Bearer abc.def password=hunter2 ivan@example.kz +7 701 123 45 67"

    %{text: text, context: ctx} =
      parse!(%{
        "text" => secret,
        "context" => %{
          "crash" => %{"name" => "Err", "message" => secret},
          "actions" => [%{"kind" => "click", "name" => secret}]
        }
      })

    for value <- [text, ctx["crash"]["message"], hd(ctx["actions"])["name"]] do
      assert value == "Bearer [REDACTED] password=[REDACTED] [email] [phone]"
    end
  end

  @pairs [
    {"Act dated 2026-11-14", "Act dated 2026-11-14"},
    {"14.11.2026 10:30", "14.11.2026 10:30"},
    {"on 2026-11-14 10:30 it failed", "on 2026-11-14 10:30 it failed"},
    {"Amount 1 250 000.00 KZT", "Amount 1 250 000.00 KZT"},
    {"inv 000123456", "inv 000123456"},
    {"see SR-42", "see SR-42"},
    {"12.11.2026 сумма 12 500 000,00", "12.11.2026 сумма 12 500 000,00"},
    {"call +7 701 123 45 67 please", "call [phone] please"},
    {"tel 87011234567", "tel [phone]"},
    {"+7 (701) 123-45-67", "[phone]"},
    {"UK +44 20 7946 0958.", "UK [phone]."},
    {"тел. 8 701 123 45 67, акт №000123456", "тел. [phone], акт №000123456"},
    {"Bearer abc.def-123 x", "Bearer [REDACTED] x"},
    {"token eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl end", "token [REDACTED] end"},
    {"key sk-abcdefghijklmnop1234", "key [REDACTED]"},
    {"password=hunter2 ok", "password=[REDACTED] ok"},
    {"mail ivan.petrov@example.kz now", "mail [email] now"}
  ]

  test "C9 the 17 literal mask pairs (shared with the web side)" do
    assert length(@pairs) == 17

    for {input, expected} <- @pairs do
      assert Capture.mask(input) == expected, "mask(#{inspect(input)})"
    end
  end

  test "C9 shape-checked request fields are not masked" do
    %{context: ctx} =
      parse!(%{
        "text" => "x",
        "context" => %{
          "requests" => [
            %{
              "at" => "2026-11-14T10:30:00Z",
              "method" => "POST",
              "path" => "/api/v1/tasks",
              "status" => 422,
              "trace_id" => "abc-123_DEF",
              "error_code" => "validation_failed"
            }
          ]
        }
      })

    assert [req] = ctx["requests"]
    assert req["at"] == "2026-11-14T10:30:00Z"
    assert req["error_code"] == "validation_failed"
    assert req["trace_id"] == "abc-123_DEF"
    assert req["path"] == "/api/v1/tasks"
  end
end
