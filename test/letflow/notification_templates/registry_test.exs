defmodule Letflow.NotificationTemplates.RegistryTest do
  @moduledoc "REQ-563 / GH #3199: R1 the registry key set and allow-list, N1 no secret-looking name."

  use ExUnit.Case, async: true

  alias Letflow.NotificationTemplates
  alias Letflow.NotificationTemplates.Registry

  @deny ~w(password token secret key api credential session sec)

  test "R1 the four keys have the exact allow-lists" do
    assert Registry.keys() == ~w(exam_assigned exam_reminder exam_result task_assigned)

    for key <- ~w(exam_assigned exam_reminder),
        do:
          assert(Registry.placeholders(key) == ~w(exam_title candidate_name deadline tenant_name))

    assert Registry.placeholders("exam_result") ==
             ~w(exam_title candidate_name result_status score_percent tenant_name)

    assert Registry.placeholders("task_assigned") ==
             ~w(task_name process_name assignee_name due_date tenant_name)

    assert Registry.fetch("other") == :error
    assert Registry.placeholders("other") == []
  end

  test "N1 no placeholder of any key looks like a credential and none matches sec://" do
    for key <- Registry.keys(), name <- Registry.placeholders(key) do
      refute Enum.any?(@deny, &String.contains?(name, &1)), name
      refute name =~ "sec://"
    end
  end

  test "the defaults pass the same validation as a PUT" do
    for key <- Registry.keys() do
      assert {:ok, _} =
               NotificationTemplates.validate_subject(key, Registry.default(key, :subject))

      assert {:ok, _} = NotificationTemplates.validate_body(key, Registry.default(key, :body))
    end
  end
end
