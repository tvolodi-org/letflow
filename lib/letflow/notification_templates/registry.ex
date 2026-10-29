defmodule Letflow.NotificationTemplates.Registry do
  @moduledoc """
  The code registry of notification template keys (REQ-563, GH #3199). A tenant may store a
  template only for a key listed here; each key carries its placeholder allow-list and its
  platform default text.

  The allow-list names non-secret display values only. No placeholder stands for a secret, a
  token, a credential or a `sec://` reference (INV-4); a test pins that no name looks like one.
  The defaults are locale-independent constants: the locale selects a stored row, not a default.
  """

  @entries %{
    "task_assigned" => %{
      placeholders: ~w(task_name process_name assignee_name due_date tenant_name),
      subject: "Task assigned: {task_name}",
      body:
        "Hello {assignee_name}, the task {task_name} of the process {process_name} " <>
          "is assigned to you. Due: {due_date}. {tenant_name}"
    },
    "exam_assigned" => %{
      placeholders: ~w(exam_title candidate_name deadline tenant_name),
      subject: "Exam assigned: {exam_title}",
      body:
        "Hello {candidate_name}, the exam {exam_title} is assigned to you. " <>
          "Deadline: {deadline}. {tenant_name}"
    },
    "exam_reminder" => %{
      placeholders: ~w(exam_title candidate_name deadline tenant_name),
      subject: "Exam reminder: {exam_title}",
      body:
        "Hello {candidate_name}, a reminder that the exam {exam_title} is due. " <>
          "Deadline: {deadline}. {tenant_name}"
    },
    "exam_result" => %{
      placeholders: ~w(exam_title candidate_name result_status score_percent tenant_name),
      subject: "Exam result: {exam_title}",
      body:
        "Hello {candidate_name}, your result for the exam {exam_title}: {result_status}, " <>
          "score {score_percent}%. {tenant_name}"
    }
  }

  @doc "The registered template keys."
  @spec keys() :: [String.t()]
  def keys, do: @entries |> Map.keys() |> Enum.sort()

  @doc "The entry of a key, or `:error` when the key is not registered."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(key) when is_binary(key), do: Map.fetch(@entries, key)
  def fetch(_key), do: :error

  @doc "The placeholder allow-list of a registered key."
  @spec placeholders(String.t()) :: [String.t()]
  def placeholders(key) do
    case fetch(key) do
      {:ok, entry} -> entry.placeholders
      :error -> []
    end
  end

  @doc "The platform default `:subject` or `:body` text of a registered key."
  @spec default(String.t(), :subject | :body) :: String.t()
  def default(key, field) when field in [:subject, :body] do
    @entries |> Map.fetch!(key) |> Map.fetch!(field)
  end
end
